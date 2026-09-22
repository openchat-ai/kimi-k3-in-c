/* k3_run.c - run the REAL Kimi K3, all 93 layers, from the released checkpoint.
 *
 * WHAT THIS IS
 *   The full engine: safetensors index over 96 shards, resident trunk bound by name,
 *   routed experts streamed from disk through an LRU cache and multiplied straight out
 *   of MXFP4. Greedy decode. Token ids in, token ids out.
 *
 * MEMORY. The banner this program prints before allocating is a PLAN, not a measurement.
 *   It reports requested budgets rather than actual reservations, and in practice it
 *   OVERSTATES: across the 12-rung ladder in docs/data/ the planned total exceeded
 *   measured peak RSS by 0.13-1.84 GB, because both budgets round down to whole slots and
 *   that rounding outweighs the safetensors index it omits. Quote the "PEAK RSS" line
 *   instead, which comes from
 *   getrusage after the run. Fully resident, the weights are 108.81 GB of bf16 trunk plus
 *   4.70 GB of embed and lm_head, so 113.49 GB; streamed, the resident set is whatever
 *   budget is given, down to about 8.2 GB. The 1.45 TB of routed experts is never
 *   resident at any budget.
 *
 * THIS ENGINE IS I/O BOUND at small budgets and roughly balanced at large ones. The
 *   measured I/O share runs 40.9%-60.6% across the 12-rung ladder (docs/data/), dropping
 *   below 50% at 96 GB and above. The "I/O share" line printed at the end of every run
 *   reports it for that run. Going faster still means moving fewer bytes before it means
 *   computing less, which is why docs/TUNING.md is mostly about allocation.
 *
 * DECODE STRATEGY
 *   Incremental decode (prefill once, then one token at a time carrying the KDA
 *   recurrent state and an MLA KV cache) is the DEFAULT and the path every README
 *   demo and long-generation run takes. --no-incremental switches to re-running the
 *   whole prefix every step. That is O(T^2), but it is the path the full-model oracle
 *   validates in tests/unit/k3_model.c. GATE 3 of the tiny-model oracle requires
 *   incremental to produce the SAME tokens as full recompute, so the equivalence is
 *   tested rather than assumed. Context is limited by the MLA KV cache
 *   (~2.37 MB/position), not by array sizes; the engine computes the requirement up
 *   front and refuses the run if it will not fit.
 *
 * COMMAND LINE
 *   usage() below is the single source of truth for options and defaults; `k3 --help`
 *   prints it. It is not duplicated here, because a second copy is a second thing to
 *   keep correct and the copy is the one that goes stale.
 */
#define _POSIX_C_SOURCE 200809L
/* _POSIX_C_SOURCE alone hides the BSD rusage fields, ru_maxrss among them, from
 * <sys/resource.h> on Darwin. peak_rss_bytes() below needs it. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/statvfs.h>
#include <sys/resource.h>

#include "k3.h"
#include "k3_bind.h"
#include "k3_cache.h"
#include "k3_l2cache.h"
#include "k3_io.h"
#include "k3_trunk.h"
#include "k3_tok.h"   /* text in/out; the --ids path never touches it */
#include "k3_cfg.h"   /* read the checkpoint's own config rather than assuming it */
#include "k3_chip.h"  /* simulated MXFP4 GEMV chip: expert pool + bill */

static double now_s(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* Bridge from K3Cache's phase2_hold(void*, int) to the trunk reader's gate. ctx is the
 * K3Trunk* (set as cache.phase2_ctx). The trunk reader cooperates by pausing at its
 * chunk boundaries, so the expert burst and the trunk stream stop sharing the drive. */
static void ran_expert_hold(void *ctx, int hold)
{
    k3_trunk_expert_hold((K3Trunk *)ctx, hold);
}

static void human(double b, char *o, size_t n)
{
    const char *u[] = {"B", "KB", "MB", "GB", "TB"};
    int i = 0; while (b >= 1000.0 && i < 4) { b /= 1000.0; i++; }
    snprintf(o, n, "%.2f %s", b, u[i]);
}

/* The released constants, kept ONLY as a fallback for runs against a shard directory
 * that has no config.json (partial fixtures, hand-assembled trunks). Every value here
 * matches the released config.json, but a hardcoded table cannot notice a checkpoint
 * revision -- so k3_cfg_load_file() is preferred whenever a config is present, and this
 * path announces itself loudly rather than passing for the real thing. */
static void real_cfg_hardcoded(K3Cfg *c, int *fa)
{
    memset(c, 0, sizeof *c);
    c->hidden = 7168;  c->n_layers = 93;   c->vocab = 163840; c->rms_eps = 1e-5f;
    c->kda_heads = 96; c->kda_head_dim = 128; c->conv_k = 4;  c->gate_lb = -5.0f;
    c->n_heads = 96;   c->q_lora = 1536;   c->kv_lora = 512;
    c->qk_nope = 128;  c->qk_rope = 64;    c->v_head = 128;   c->mla_out_gate = 1;
    c->n_experts = 896; c->topk = 16;      c->n_shared = 2;
    c->latent = 3584;  c->moe_inter = 3072; c->routed_scale = 1.0f;
    c->moe_renorm = 1; c->latent_norm = 1;
    c->first_dense = 1; c->dense_inter = 33792;
    c->attn_res_block = 12;
    c->situ_b1 = 4.0f; c->situ_b2 = 25.0f;
    int n = 0;
    for (int i = 4; i <= 93; i += 4) fa[n++] = i;     /* config lists are ONE-based */
    fa[n++] = 93;
    c->n_full_attn = n; c->full_attn = fa;
}

/* Prefer the checkpoint's own config; fall back only when there is none.
 * cfg_path may be NULL, in which case <shard_dir>/config.json is tried.
 * Returns 1 on success, 0 if a config was found but could not be trusted -- and in
 * that case the caller MUST abort rather than fall back: a config that was found but
 * could not be parsed is evidence that the checkpoint is not what the fallback table
 * describes, which is exactly when the fallback is most dangerous. */
static int real_cfg(K3Cfg *c, int *fa, int fa_max,
                    const char *shard_dir, const char *cfg_path)
{
    char guess[4096];
    if (!cfg_path) {
        snprintf(guess, sizeof guess, "%s/config.json", shard_dir);
        FILE *probe = fopen(guess, "rb");
        if (probe) { fclose(probe); cfg_path = guess; }
    }
    if (cfg_path) return k3_cfg_load_file(c, fa, fa_max, cfg_path);

    real_cfg_hardcoded(c, fa);
    printf("config: NO config.json found under %s\n"
           "        falling back to the built-in Kimi K3 constants (93 layers, 24 MLA).\n"
           "        These match the released checkpoint but are NOT read from it; pass\n"
           "        --config PATH to validate against the real file.\n", shard_dir);
    return 1;
}

static int argmax_(const float *v, int n)
{ int b = 0; for (int i = 1; i < n; i++) if (v[i] > v[b]) b = i; return b; }

static void json_string(FILE *f, const char *s)
{
    if (!s) { fputs("null", f); return; }
    fputc('"', f);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"': fputs("\\\"", f); break;
        case '\\': fputs("\\\\", f); break;
        case '\b': fputs("\\b", f); break;
        case '\f': fputs("\\f", f); break;
        case '\n': fputs("\\n", f); break;
        case '\r': fputs("\\r", f); break;
        case '\t': fputs("\\t", f); break;
        default:
            if (*p < 0x20) fprintf(f, "\\u%04x", (unsigned)*p);
            else fputc(*p, f);
        }
    }
    fputc('"', f);
}

/* ------------------------------------------------------- conversation state ----
 * Everything the engine carries between tokens, on disk. The point is turn two of a
 * conversation: without this, resuming re-reads the whole prompt through all 93 layers,
 * which on a streamed trunk costs minutes; with it, a resumed session pays only for the
 * tokens actually new.
 *
 * Three things are carried, and only three: the KDA recurrent matrices plus ShortConv
 * history (fixed size, independent of context), the MLA KV cache, and the shared rope
 * rows. The AttnRes block buffer is NOT carried because forward() clears it on entry and
 * rebuilds it from the layer outputs every pass; saving it would be saving scratch.
 *
 * The KV cache is stored position-major inside each MLA layer's slice, so only the
 * OCCUPIED positions are written and a resumed run may size its cache differently. The
 * header carries a config fingerprint: restoring state built by a different architecture
 * would produce fluent, wrong output with nothing to indicate it, which is the one
 * failure mode this engine refuses to have. */
#define K3_STATE_MAGIC "K3ST"
#define K3_STATE_VER   1

typedef struct {
    char    magic[4];
    int32_t version;
    int32_t fp[12];        /* config fingerprint */
    int32_t n_bound, n_mla, cached, nseq;
    int64_t kper;          /* KDA+conv floats per layer */
    int64_t kvpp, ropepp;  /* KV / rope floats per position, per MLA layer */
} K3StateHdr;

static void k3_state_fp(const K3Cfg *c, int32_t *fp)
{
    fp[0] = c->hidden;      fp[1] = c->n_layers;  fp[2]  = c->vocab;
    fp[3] = c->kda_heads;   fp[4] = c->kda_head_dim; fp[5] = c->conv_k;
    fp[6] = c->n_heads;     fp[7] = c->qk_nope;   fp[8]  = c->qk_rope;
    fp[9] = c->v_head;      fp[10] = c->n_experts; fp[11] = c->topk;
}

#define K3_SPEC_MAX 8
/* Longest-suffix n-gram drafting for --spec: if the last n ids (n=3, then 2) already
 * appeared earlier in the sequence, propose the ids that followed them there. Costs
 * nothing when it misses: no draft means the step runs exactly as without --spec. The
 * drafts are PROPOSALS only; batched greedy verification accepts precisely the prefix
 * the model itself would have emitted, so the output stream is identical to serial
 * decode by construction, and the A/B gate checks it. */
/* Reads only the header, so the caller can size buffers before committing to a load. */
static int k3_state_peek(const char *path, K3StateHdr *hd)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return -1; }
    const size_t got = fread(hd, 1, sizeof *hd, f);
    fclose(f);
    if (got != sizeof *hd || memcmp(hd->magic, K3_STATE_MAGIC, 4) != 0) {
        fprintf(stderr, "%s is not a k3 state file\n", path);
        return -1;
    }
    if (hd->version != K3_STATE_VER) {
        fprintf(stderr, "%s is state version %d, this build writes %d\n",
                path, hd->version, K3_STATE_VER);
        return -1;
    }
    return 0;
}

static int k3_state_load(const char *path, const K3Cfg *c, const K3StateHdr *hd,
                         int *seq, float *ks, float *kvc, float *ropec,
                         int n_bound, int n_mla, int kv_cap)
{
    int32_t fp[12];
    k3_state_fp(c, fp);
    if (memcmp(fp, hd->fp, sizeof fp) != 0) {
        fprintf(stderr, "REFUSING: %s was written by a different model architecture.\n"
                        "  Restoring it would produce fluent, wrong output.\n", path);
        return -1;
    }
    if (hd->n_bound != n_bound || hd->n_mla != n_mla) {
        fprintf(stderr, "REFUSING: %s holds %d bound layers and %d MLA layers, "
                        "this run has %d and %d\n",
                path, hd->n_bound, hd->n_mla, n_bound, n_mla);
        return -1;
    }
    if (hd->cached > kv_cap) {
        fprintf(stderr, "REFUSING: %s holds %d positions, this run's KV cache is %d.\n"
                        "  Raise --gen or shorten the prompt.\n", path, hd->cached, kv_cap);
        return -1;
    }
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return -1; }
    if (fseek(f, (long)sizeof *hd, SEEK_SET) != 0) { fclose(f); return -1; }

    int rc = 0;
    if (fread(seq, sizeof(int), (size_t)hd->nseq, f) != (size_t)hd->nseq) rc = -1;
    if (!rc && fread(ks, sizeof(float), (size_t)hd->kper * n_bound, f)
               != (size_t)hd->kper * (size_t)n_bound) rc = -1;
    /* Position-major inside each layer slice, so a differently-sized destination cache
     * is written slice by slice rather than as one block. */
    for (int mi = 0; !rc && mi < n_mla; mi++) {
        float *dst = kvc + (size_t)mi * kv_cap * hd->kvpp;
        const size_t n = (size_t)hd->cached * hd->kvpp;
        if (fread(dst, sizeof(float), n, f) != n) rc = -1;
    }
    for (int mi = 0; !rc && mi < n_mla; mi++) {
        float *dst = ropec + (size_t)mi * kv_cap * hd->ropepp;
        const size_t n = (size_t)hd->cached * hd->ropepp;
        if (fread(dst, sizeof(float), n, f) != n) rc = -1;
    }
    fclose(f);
    if (rc) fprintf(stderr, "%s is truncated\n", path);
    return rc;
}

static int k3_state_save(const char *path, const K3Cfg *c, const int *seq, int nseq,
                         const float *ks, const float *kvc, const float *ropec,
                         int n_bound, int n_mla, int kv_cap, int cached,
                         int64_t kper, int64_t kvpp, int64_t ropepp)
{
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }
    K3StateHdr hd;
    memset(&hd, 0, sizeof hd);
    memcpy(hd.magic, K3_STATE_MAGIC, 4);
    hd.version = K3_STATE_VER;
    k3_state_fp(c, hd.fp);
    hd.n_bound = n_bound; hd.n_mla = n_mla; hd.cached = cached; hd.nseq = nseq;
    hd.kper = kper; hd.kvpp = kvpp; hd.ropepp = ropepp;

    int rc = 0;
    if (fwrite(&hd, sizeof hd, 1, f) != 1) rc = -1;
    if (!rc && fwrite(seq, sizeof(int), (size_t)nseq, f) != (size_t)nseq) rc = -1;
    if (!rc && fwrite(ks, sizeof(float), (size_t)kper * n_bound, f)
               != (size_t)kper * (size_t)n_bound) rc = -1;
    for (int mi = 0; !rc && mi < n_mla; mi++) {
        const float *src = kvc + (size_t)mi * kv_cap * kvpp;
        const size_t n = (size_t)cached * kvpp;
        if (fwrite(src, sizeof(float), n, f) != n) rc = -1;
    }
    for (int mi = 0; !rc && mi < n_mla; mi++) {
        const float *src = ropec + (size_t)mi * kv_cap * ropepp;
        const size_t n = (size_t)cached * ropepp;
        if (fwrite(src, sizeof(float), n, f) != n) rc = -1;
    }
    if (fclose(f) != 0) rc = -1;
    if (rc) fprintf(stderr, "failed writing %s\n", path);
    return rc;
}

static int spec_draft(const int *seq, int T, int cap, int *out)
{
    /* Evidence-gated: a draft only fires when the suffix n-gram's occurrences AGREE on
     * what follows. Measured on the released checkpoint, an eager most-recent-match
     * drafter went 0.91x on code: partial acceptances pay a replay sweep, so weak
     * drafts are worse than no drafts. Rules: match length 4 (then 3); if the n-gram
     * occurred more than once, every occurrence must propose the same next id, and the
     * draft stops at the first position where historical continuations diverge. */
    if (cap > K3_SPEC_MAX) cap = K3_SPEC_MAX;
    for (int n = 4; n >= 3; n--) {
        if (T < n + 1) continue;
        int m1 = -1, m2 = -1;                            /* two most recent matches */
        for (int j = T - n - 1; j >= 0; j--) {
            int hit = 1;
            for (int i = 0; i < n; i++)
                if (seq[j + i] != seq[T - n + i]) { hit = 0; break; }
            if (!hit) continue;
            if (m1 < 0) m1 = j;
            else { m2 = j; break; }
        }
        if (m1 < 0) continue;
        int nd = 0;
        for (int i = 0; nd < cap && m1 + n + i < T; i++) {
            const int cand = seq[m1 + n + i];
            if (m2 >= 0) {
                /* stop where the two histories' continuations disagree. The old
                 * condition `m2 + n + i >= m1` was WRONG: with m2 < m1 and n >= 3 it
                 * is true on the first i for any two matches (e.g. a pure cycle
                 * [a,b]*4 at T=8, m1=2, m2=0: 0+4+0=4 >= 2), so a draft NEVER fired
                 * even when every historical occurrence agreed on the next token --
                 * the n-gram drafter silently did nothing and spec fell back to
                 * serial decode. Compare the CONTENT of the two continuations. */
                if (m2 + n + i >= T || seq[m2 + n + i] != cand) break;
            }
            out[nd++] = cand;
        }
        if (nd > 0) return nd;
    }
    return 0;
}

#ifndef K3_VERSION
#define K3_VERSION "1.0.0"
#endif

static void usage(FILE *f)
{
    fprintf(f,
"k3 " K3_VERSION ", Kimi K3 inference engine\n"
"\n"
"usage: k3 <model_dir> [options]\n"
"\n"
"prompt (exactly one):\n"
"  --prompt TEXT         tokenize TEXT and run it\n"
"  --prompt-file PATH    read the prompt from a file; use this for non-ASCII, since\n"
"                        argv is re-encoded by the shell\n"
"  --ids 1,2,3           raw token ids; the reproducible channel used by the tests\n"
"\n"
"memory:\n"
"  --preset NAME         auto | laptop | desktop | workstation | server | max\n"
"                        auto sizes both budgets from this machine's free RAM,\n"
"                        trunk-first; also spelled --trunk-gb auto\n"
"  --list-presets        show each preset's split and expected speed\n"
"  --trunk DIR           packed trunk directory; enables streaming (see scripts/)\n"
"  --trunk-gb X          trunk ring / pinned-layer budget\n"
"  --trunk-ring N        number of ring slots to cycle layers through (default 2);\n"
"                        larger keeps recently read layers resident across tokens\n"
"  --cache-gb X          routed-expert cache budget\n"
"  --l2 PATH             expert-granularity disk cache file on a fast volume (sdd7),\n"
                        " holding hot experts so the slow checkpoint disk is not re-read;\n"
                        " a routed-expert RAS trace showed ~69 GB of distinct experts\n"
  "  --embed-dir DIR      alternate directory holding the embed+lm_head shard\n"
                        " (model-00094-of-000096). Put the 4.7 GB embed on sdd7 so the\n"
                        " slow checkpoint disk is not read for it, like --trunk/--l2\n"
"  --l2-gb X             size of that file in GB, rounded down to whole slots; default\n"
"                        auto (half the free space on the fast volume, up to the 192 GB\n"
"                        capacity knee measured on the expert trace)\n"
"  --l2-policy POL       L2 eviction policy: heat (default, evict lowest cumulative\n"
"                        count) or lru (evict least recently touched)\n"
"\n"
"generation:\n"
"  --gen N               tokens to generate (default 8)\n"
"  --stop-id N           halt after emitting token id N (repeatable, up to 8). The\n"
"                        stop id is kept in the sequence, so --save-state and a later\n"
"                        --load-state continue from what was actually produced.\n"
"                        Off by default: without it --gen N means exactly N tokens,\n"
"                        which the benchmarks and oracle gates rely on. Note the\n"
"                        released checkpoint declares TWO end ids that disagree:\n"
"                        config.json says 163586 (<|end_of_msg|>), tokenizer_config\n"
"                        .json says 163585 ([EOS]), and the model emits 163585.\n"
"                        Pass both to stop on either\n"
"  --incremental         carry KV cache and recurrent state between tokens (default)\n"
"  --no-incremental      full recompute of the whole prefix every step; the oracle path\n"
"  --save-state PATH     write the carried state after the run, so the next turn of a\n"
"                        conversation resumes instead of re-reading the whole prompt\n"
"  --load-state PATH     resume from a saved state; the prompt given now is treated as\n"
"                        the CONTINUATION of the saved sequence. Needs --incremental\n"
"  --draft-trunk DIR     hybrid decode: a second packed trunk (typically a quantized\n"
"                        derivation of the real one, see tools/qdq_trunk.py) DRAFTS\n"
"                        tokens which the exact model verifies in batched sweeps.\n"
"                        Output remains exactly the exact model's greedy decode; the\n"
"                        draft only proposes. Needs --incremental; implies --spec 4\n"
"  --draft-trunk-gb X    trunk budget for the draft model (default 6)\n"
"  --spec N              speculative decode: draft up to N tokens by n-gram lookup and\n"
                         " verify them in ONE batched sweep. Output is identical to\n"
                         " serial decode by construction; needs --incremental. An extra\n"
                         " verified position costs ~22%% of a serial token when the trunk\n"
                         " streams, so repetitive text decodes up to several times faster\n"
  "  --batch-gen           emit ALL --gen tokens in ONE forward pass instead of one forward\n"
                        " per token. Each layer binds exactly once for the whole generation;\n"
                        " later positions are fed the SAME input as the first (no true\n"
                        " prefix), so output is NOT strict autoregressive decode. Needs\n"
                        " --incremental\n"
"  --loop-serial N     EXPERIMENT: block-serial trunk I/O grouping. Layers run in the\n"
                         " standard order but are prefetched and released a block of\n"
                         " --loop-block layers at a time (N is kept for parity, ignored).\n"
                         " Output is identical to the standard path; scheduling-only\n"
"  --tok DIR             directory with tiktoken.model and tokenizer_config.json\n"
"\n"
"diagnostics:\n"
"  --config PATH         model config; defaults to <model_dir>/config.json\n"
"  --layers N            bind only the first N layers (partial shard sets)\n"
"  --dump-logits PATH    write float32 logits for the first step\n"
"  --dump-cache-trace D  write expert_hist.json and expert_trace.bin into D, for\n"
"                        offline analysis with tools/sim_cache.py\n"
"  --out FILE            JSON results (default k3_run.json)\n"
"  --version, --help\n"
"\n"
"Memory is a dial, not a floor: the same model runs in 8 GB and in 224 GB and produces\n"
"identical output. Give memory to the trunk before the expert cache, see\n"
"docs/TUNING.md for why, and scripts/k3-doctor.sh to size this machine.\n");
}

/* ------------------------------------------------------------------- presets ----
 * Named memory budgets, so a user does not have to discover the trunk/cache split
 * empirically.
 *
 * The split is not arbitrary and it is not symmetric. Per token the engine re-reads the
 * ENTIRE 108.81 GB trunk but only ~25.8 GB of routed experts, so a gigabyte given to the
 * trunk removes roughly 1.17 GB/token of guaranteed traffic (one pinned layer) while a
 * gigabyte given to the expert cache removes, below about 36 GB of arena, nothing
 * measurable, K3's router is trained for flat expert usage, which defeats an LRU.
 *
 * Measured consequence: at a fixed 128 GB budget, trunk-first runs 1.69x faster than
 * cache-first. So every preset fills the trunk before it feeds the cache.
 * docs/PERFORMANCE.md carries the data and the noise floor that bounds it. */
typedef struct { const char *name; double trunk_gb, cache_gb; const char *note; } K3Preset;

/* The trunk/cache figures are BUDGETS passed to the two allocators. The description
 * quotes measured peak RSS for the whole process, which is the number that decides
 * whether a machine can run the preset, it includes the safetensors index, the KV
 * cache and scratch, none of which appear in either budget. Measured on the reference
 * machine in docs/PERFORMANCE.md; expect a little variation elsewhere. */
static const K3Preset K3_PRESETS[] = {
    { "laptop",      3.0,   1.0,  "8.2 GB peak RSS. The floor. Runs, slowly." },
    { "desktop",    16.0,  10.0,  "31.9 GB peak RSS." },
    { "workstation", 60.0, 30.0,  "95.5 GB peak RSS; the expert cache starts to matter here." },
    { "server",     110.0, 13.0,  "~128 GB peak RSS; 90 of 93 trunk layers pinned. Fastest." },
    { "max",        110.0,109.0,  "~224 GB peak RSS; trunk pinned and a large expert cache." },
};
enum { K3_NPRESET = (int)(sizeof K3_PRESETS / sizeof K3_PRESETS[0]) };

static const K3Preset *k3_preset_find(const char *name)
{
    for (int i = 0; i < K3_NPRESET; i++)
        if (!strcmp(name, K3_PRESETS[i].name)) return &K3_PRESETS[i];
    return NULL;
}

static void k3_preset_list(FILE *f)
{
    fprintf(f, "presets (trunk / expert-cache, in GB):\n");
    for (int i = 0; i < K3_NPRESET; i++)
        fprintf(f, "  %-12s %6.1f / %-6.1f  %s\n", K3_PRESETS[i].name,
                K3_PRESETS[i].trunk_gb, K3_PRESETS[i].cache_gb, K3_PRESETS[i].note);
    fprintf(f, "  %-12s %6s / %-6s  %s\n", "auto", "fit", "fit",
            "sizes both from this machine's free RAM, trunk-first. Recommended.");
    fprintf(f, "\nAll presets stream the trunk, so they need --trunk <packed_dir>.\n"
               "Run scripts/k3-doctor.sh to see which one this machine fits.\n");
}

/* PEAK resident set, in bytes. ru_maxrss is kilobytes on Linux and BYTES on Darwin, so
 * the scale factor differs by platform; applying the Linux one on macOS would overstate
 * the peak by 1024x.
 *
 * This is the authoritative memory figure. The banner printed before allocation is a
 * PLAN and understates: it omits the safetensors index (~78 MB at full scale), reports
 * requested budgets rather than actual reservations, and cannot observe fragmentation.
 * Quote this value, not the plan. */
static double peak_rss_bytes(void)
{
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0.0;
#if defined(__APPLE__)
    return (double)ru.ru_maxrss;            /* already bytes */
#else
    return (double)ru.ru_maxrss * 1024.0;   /* kilobytes */
#endif
}

/* MemAvailable, which is what the kernel thinks can actually be handed out, not
 * MemFree. Returns 0 if it cannot be read. */
static double mem_available_bytes(void)
{
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return 0.0;
    char line[256];
    double kb = 0.0;
    while (fgets(line, sizeof line, f))
        if (!strncmp(line, "MemAvailable:", 13)) { kb = atof(line + 13); break; }
    fclose(f);
    return kb * 1024.0;
}

typedef struct {
    K3LayerBind *lay;
    K3ModelBind  mb;
    int          n_bound;
    K3Trunk     *trunk;      /* non-NULL when the trunk is streamed rather than resident */
    /* Incremental decode state. Only MLA layers need a KV cache, so the 24 of them are
     * numbered densely rather than indexing all 93 and wasting 74% of the allocation. */
    float       *kvc, *ropec;
    int         *mla_slot;   /* [n_layers] -> dense MLA index, or -1 */
    int          n_mla, kv_cap, cached;
    int          layers_completed;   /* how many layers finished before any failure */
    int          draft_mode;   /* 1 for the hybrid draft: cache-only expert routing */
    int          loop_serial;  /* >0: EXPERIMENT block-serial trunk I/O grouping */
    int          loop_block;  /* EXPERIMENT: layers per serial block (default 4) */
} Weights;

/* One full forward over T tokens, writing logits for the LAST position only. Every
 * step rebuilds state from scratch, matching the path the oracle validates.
 *
 * Returns 0 on success and -1 if the forward could not be completed. The caller MUST
 * check: on failure logits_last is left untouched, and argmaxing an untouched buffer
 * yields a token drawn from uninitialised memory, printed as though it were output. */
/* arg_all: when non-NULL, receives argmax(logits) for EVERY position 0..T-1, which is
 * what batched greedy verification consumes. logits_last still gets the final position's
 * full vector either way. The extra cost is one lm_head matmul per additional position,
 * pure RAM-resident compute; measured, an extra verified position costs ~22% of a serial
 * token at streamed-trunk budgets, which is the entire economics of --spec. */
static int forward(Weights *w, const K3Cfg *c, K3Cache *cache, const int *ids, int T,
                   float *logits_last, float *scratch, float *h, float *br, float *kstate,
                   int *arg_all)
{
    const int E = c->hidden;
    const int maxb = c->n_layers / c->attn_res_block + 2;
    const int P = c->kda_heads * c->kda_head_dim;
    const size_t kper = (size_t)P * c->kda_head_dim + (size_t)3 * P * (c->conv_k - 1);

    for (int t = 0; t < T; t++)
        k3_embed_row(h + (size_t)t * E, w->mb.embed, w->mb.wdt, ids[t], E);

    memset(br, 0, (size_t)T * maxb * E * sizeof(float));
    /* Incremental decode carries the KDA recurrent matrix and ShortConv history across
     * steps, so it must NOT be cleared here; the full-recompute path rebuilds from
     * scratch every step and must be. */
    if (!w->kvc) memset(kstate, 0, kper * (size_t)w->n_bound * sizeof(float));
    int nb = 0;
    if (getenv("K3_LOOP_DBG"))
        fprintf(stderr, "DBG fwd_inner loop_serial=%d T=%d\n", w->loop_serial, T);
    for (int L = 0; L < w->n_bound; L++) {
        const long drops_before = k3_expert_drops;
        /* Streaming: bring this layer in, and hint the next one so its read overlaps
         * this layer's arithmetic. The hint is safe: prefetch only claims a slot that
         * was explicitly released (this layer's own slot is not free yet, so its bytes
         * stay stable while compute reads them). */
        if (w->trunk) {
            if (k3_trunk_bind(w->trunk, c, L, &w->lay[L]) != 0) {
                fprintf(stderr, "trunk bind failed at layer %d\n", L);
                return -1;
            }
            if (w->loop_serial > 0) {
                /* Block-serial prefetch: at the START of a block issue hints for the
                 * WHOLE next block (L+1 .. L+blk-1) so its layers are read as a unit
                 * while this block computes, instead of one layer at a time. k3_trunk
                 * drops a hint whose target slot is busy, so no live layer is evicted. */
                const int blk = (w->loop_block > 0) ? w->loop_block : 4;
                if (L % blk == 0)
                    for (int j = 1; j < blk && L + j < w->n_bound; j++)
                        k3_trunk_prefetch(w->trunk, L + j);
            } else {
                k3_trunk_prefetch(w->trunk, L + 1);
            }
        }
        /* Point this layer's MoE at the cache before use. Doing it here rather than at
         * bind time keeps K3LayerBind independent of any particular cache. */
        if (w->lay[L].lay.moe) {
            w->lay[L].moe.src = &cache->src;
            w->lay[L].moe.layer = L;
            /* The draft routes only among resident experts, reading zero new expert bytes;
             * the exact model keeps true routing. This is what makes a draft step cheap. */
            w->lay[L].moe.cache_only = w->draft_mode;
        }
        if (w->kvc && w->mla_slot[L] >= 0) {
            const size_t kvper = (size_t)w->kv_cap * c->n_heads * (c->qk_nope + c->v_head);
            const size_t rpper = (size_t)w->kv_cap * c->qk_rope;
            const int mi = w->mla_slot[L];
            k3_decoder_layer_inc(h, br, &nb, &w->lay[L].lay, c, L, T,
                                 kstate + kper * (size_t)L, scratch,
                                 w->kvc + kvper * (size_t)mi,
                                 w->ropec + rpper * (size_t)mi,
                                 w->cached, w->kv_cap);
        } else {
            k3_decoder_layer_inc(h, br, &nb, &w->lay[L].lay, c, L, T,
                                 kstate + kper * (size_t)L, scratch,
                                 NULL, NULL, 0, 0);
        }
        /* L is done computing; its slot may now be recycled for the layer after next.
         * Prefetch already claimed a different free slot for L+1 before compute began,
         * so releasing here only widens the pool for L+2. */
        /* Group release, user's schedule: at the END of a block (L % blk == blk-1) the
         * block has served all T positions and can be dropped as a unit, freeing its
         * slots for the next block's prefetch blk layers early. k3_trunk_release
         * refuses to drop a layer the async reader is mid-load, and prefetch only
         * takes already-free slots, so the current block's live layers are never
         * evicted under the next block's read. */
        if (w->trunk) {
            const int blk = (w->loop_block > 0) ? w->loop_block : 4;
            if (w->loop_serial > 0 && blk > 1 && L % blk == blk - 1) {
                for (int i = blk - 1; i >= 0 && L - i >= 0; i--)
                    k3_trunk_release(w->trunk, L - i);
            } else if (w->loop_serial == 0) {
                k3_trunk_release(w->trunk, L);
            }
        }
        /* Refuse to hand back the output of a layer whose routed experts did not all
         * load: an incomplete MoE produces garbage the decoder then bakes into every
         * later layer. Fail fast here rather than surfacing it next token as a wrong
         * answer. */
        if (k3_expert_drops != drops_before) {
            fprintf(stderr, "routed expert load failed at layer %d; refusing partial "
                            "MoE output\n", L);
            return -1;
        }
        w->layers_completed = L + 1;
    }

    /* The model-level aggregator, beyond the two per layer. Exactly one pair exists in
     * the checkpoint; skipping it is silent. */
    if (w->mb.out_res_norm && w->mb.out_res_proj) {
        float *fold = scratch;
        float *src  = fold + E;
        for (int i = 0; i < E; i++) fold[i] = w->mb.out_res_norm[i] * w->mb.out_res_proj[i];
        for (int t = 0; t < T; t++) {
            for (int b = 0; b < nb; b++)
                memcpy(src + (size_t)b * E, br + ((size_t)t * maxb + b) * E,
                       (size_t)E * sizeof(float));
            memcpy(src + (size_t)nb * E, h + (size_t)t * E, (size_t)E * sizeof(float));
            k3_attn_res(h + (size_t)t * E, src, fold, nb + 1, E, c->rms_eps);
        }
    }

    float *nrm = scratch;
    if (arg_all) {
        for (int t = 0; t < T; t++) {
            k3_rmsnorm(nrm, h + (size_t)t * E, w->mb.norm, E, c->rms_eps);
            k3_mmw(logits_last, nrm, w->mb.lm_head, w->mb.wdt, E, c->vocab);
            arg_all[t] = argmax_(logits_last, c->vocab);
        }
        /* logits_last now holds the FINAL position's vector, same as the plain path. */
        return 0;
    }
    k3_rmsnorm(nrm, h + (size_t)(T - 1) * E, w->mb.norm, E, c->rms_eps);
    k3_mmw(logits_last, nrm, w->mb.lm_head, w->mb.wdt, E, c->vocab);
    return 0;
}

int main(int argc, char **argv)
{
    /* Informational flags are answered before anything else, because they must work
     * without a model directory, `k3 --help` on a machine with no checkpoint is the
     * first thing most people type. */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) { usage(stdout); return 0; }
        if (!strcmp(argv[i], "--version")) { printf("k3 %s\n", K3_VERSION); return 0; }
        if (!strcmp(argv[i], "--list-presets")) { k3_preset_list(stdout); return 0; }
    }
    if (argc < 2) { usage(stderr); return 2; }

    const char *dir = argv[1];
    if (dir[0] == '-') {
        fprintf(stderr, "the first argument must be the model directory, got '%s'\n\n", dir);
        usage(stderr);
        return 2;
    }
    const char *ids_s = NULL, *outp = "k3_run.json", *trunk_dir = NULL;
    /* Expert-cache diagnostics are opt-in. They are only meaningful for cache research,
     * and writing them unconditionally drops two undeclared files into whatever
     * directory the user happened to run from. */
    const char *trace_dir = NULL;
    const char *logits_path = NULL;
    const char *prompt_text = NULL, *prompt_file = NULL, *tok_dir = NULL;
    const char *cfg_path = NULL;
    int gen = 8, want_layers = -1;
    double cache_gb = 8.0, trunk_gb = 12.0;
    int trunk_ring = 2;
    int budget_auto = 0, budget_explicit = 0;
    int spec_n = 0;
    int batch_gen = 0;       /* once-BATCH-decode: emit --gen tokens from ONE forward */
    int loop_serial = 0;     /* EXPERIMENT: block-serial trunk I/O grouping; 0 = OFF */
    int loop_block = 4;      /* EXPERIMENT: layers per serial block */
    int stop_id[8]; int n_stop = 0, hit_stop = 0, stopped_at = -1;
    int tf_check = 0;
    const char *draft_dir = NULL;
    double draft_gb = 6.0;
    const char *load_state = NULL, *save_state = NULL;
    const char *preset_name = NULL;
    int incremental = 0;
    int incremental_default = 1;
    const char *l2_path = NULL;      /* fast-volume second-level expert cache file */
    const char *embed_dir = NULL;    /* alternate dir for the embed+lm_head shard (sdd7) */
    double l2_gb = 200.0;
    int l2_gb_explicit = 0;
    int l2_policy = 0;               /* 0 = heat (default), 1 = lru */
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--ids") && i + 1 < argc) ids_s = argv[++i];
        else if (!strcmp(argv[i], "--prompt") && i + 1 < argc) prompt_text = argv[++i];
        else if (!strcmp(argv[i], "--prompt-file") && i + 1 < argc) prompt_file = argv[++i];
        else if (!strcmp(argv[i], "--tok") && i + 1 < argc) tok_dir = argv[++i];
        else if (!strcmp(argv[i], "--config") && i + 1 < argc) cfg_path = argv[++i];
        else if (!strcmp(argv[i], "--gen") && i + 1 < argc) gen = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--cache-gb") && i + 1 < argc) cache_gb = atof(argv[++i]);
        else if (!strcmp(argv[i], "--layers") && i + 1 < argc) want_layers = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) outp = argv[++i];
        else if (!strcmp(argv[i], "--trunk") && i + 1 < argc) trunk_dir = argv[++i];
        else if (!strcmp(argv[i], "--spec") && i + 1 < argc) spec_n = atoi(argv[++i]);
        
        else if (!strcmp(argv[i], "--batch-gen")) batch_gen = 1;
        else if (!strcmp(argv[i], "--loop-serial") && i + 1 < argc) loop_serial = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--loop-block") && i + 1 < argc) loop_block = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--stop-id") && i + 1 < argc) {
            if (n_stop >= (int)(sizeof stop_id / sizeof stop_id[0])) {
                fprintf(stderr, "--stop-id given more than %d times\n",
                        (int)(sizeof stop_id / sizeof stop_id[0]));
                return 2;
            }
            char *end;
            const long v = strtol(argv[++i], &end, 10);
            if (*argv[i] == '\0' || *end != '\0' || v < 0) {
                fprintf(stderr, "--stop-id %s: expected a non-negative token id\n", argv[i]);
                return 2;
            }
            stop_id[n_stop++] = (int)v;
        }
        else if (!strcmp(argv[i], "--tf-check")) tf_check = 1;
        else if (!strcmp(argv[i], "--load-state") && i + 1 < argc) load_state = argv[++i];
        else if (!strcmp(argv[i], "--save-state") && i + 1 < argc) save_state = argv[++i];
        else if (!strcmp(argv[i], "--draft-trunk") && i + 1 < argc) draft_dir = argv[++i];
        else if (!strcmp(argv[i], "--draft-trunk-gb") && i + 1 < argc) draft_gb = atof(argv[++i]);
        else if (!strcmp(argv[i], "--trunk-gb") && i + 1 < argc) {
            const char *v = argv[++i];
            budget_explicit = 1;
            if (!strcmp(v, "auto")) budget_auto = 1;
            else { trunk_gb = atof(v); budget_auto = 0; }
        }
        else if (!strcmp(argv[i], "--trunk-ring") && i + 1 < argc) trunk_ring = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--incremental")) incremental_default = 1;
        else if (!strcmp(argv[i], "--no-incremental")) incremental_default = 0;
        else if (!strcmp(argv[i], "--l2") && i + 1 < argc) l2_path = argv[++i];
        else if (!strcmp(argv[i], "--embed-dir") && i + 1 < argc) embed_dir = argv[++i];
        else if (!strcmp(argv[i], "--l2-gb") && i + 1 < argc) { l2_gb = atof(argv[++i]); l2_gb_explicit = 1; }
        else if (!strcmp(argv[i], "--l2-policy") && i + 1 < argc) {
            const char *v = argv[++i];
            if (!strcmp(v, "lru")) l2_policy = 1;
            else if (!strcmp(v, "heat")) l2_policy = 0;
            else {
                fprintf(stderr, "unknown --l2-policy '%s' (use 'heat' or 'lru')\n\n", v);
                return 2;
            }
        }
        else if (!strcmp(argv[i], "--dump-logits") && i + 1 < argc) logits_path = argv[++i];
        else if (!strcmp(argv[i], "--dump-cache-trace") && i + 1 < argc) trace_dir = argv[++i];
        else if (!strcmp(argv[i], "--preset") && i + 1 < argc && !strcmp(argv[i + 1], "auto")) {
            /* Not in the table: the table is fixed budgets, auto is computed from this
             * machine's MemAvailable at startup, below, once parsing is complete. */
            i++;
            budget_auto = 1;
            budget_explicit = 1;
            preset_name = "auto";
        }
        else if (!strcmp(argv[i], "--preset") && i + 1 < argc) {
            const K3Preset *p = k3_preset_find(argv[++i]);
            if (!p) {
                fprintf(stderr, "unknown preset '%s'\n\n", argv[i]);
                k3_preset_list(stderr);
                return 2;
            }
            /* A preset sets the budget; an explicit --trunk-gb/--cache-gb after it still
             * wins, because the flags are applied in argv order. */
            budget_explicit = 1;
            trunk_gb = p->trunk_gb;
            cache_gb = p->cache_gb;
            preset_name = p->name;
        }
        else if (!strcmp(argv[i], "--list-presets")) { k3_preset_list(stdout); return 0; }
        else if (!strcmp(argv[i], "--version")) {
            printf("k3 %s\n", K3_VERSION);
            return 0;
        }
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) { usage(stdout); return 0; }
        else { fprintf(stderr, "unknown option %s\n\n", argv[i]); usage(stderr); return 2; }
    }
    {
        int nsrc = (ids_s != NULL) + (prompt_text != NULL) + (prompt_file != NULL);
        if (nsrc == 0) {
            fprintf(stderr, "one of --ids, --prompt or --prompt-file is required\n");
            return 2;
        }
        if (nsrc > 1) {
            /* Refuse rather than pick: silently preferring one source would make a
             * mistyped invocation run the WRONG prompt for tens of minutes. */
            fprintf(stderr, "--ids, --prompt and --prompt-file are mutually exclusive\n");
            return 2;
        }
    }

    /* Auto is the DEFAULT: a machine's RAM decides how much trunk it can pin, nobody
     * should have to know --trunk-gb exists. Only an explicit --trunk-gb / --preset
     * opts out; that path keeps the old fixed-budget behaviour. */
    if (!budget_explicit && !budget_auto)
        budget_auto = 1;

    /* L2 expert cache is ON by default. Without it every decode step re-streams the
     * routed experts from the slow checkpoint volume (measured ~87% of wall time on the
     * reference machine). Explicit --l2 / --l2-gb / --l2-policy still mean what they
     * meant; the engine just opens the cache on the fast volume and, unless --l2-gb
     * says otherwise, sizes it from the free space there up to the capacity knee
     * measured on the expert trace (docs/data/expert-cache-capacity.txt: full benefit
     * at 192 GB, flat above it). */
    if (!l2_path) {
        l2_path = "/mnt/nvme/experts.l2";
        if (!l2_gb_explicit) {
            struct statvfs sv;
            char svdir[512];
            snprintf(svdir, sizeof svdir, "%s", l2_path);
            char *slash = strrchr(svdir, '/');
            if (slash) *slash = '\0';
            if (slash != svdir && statvfs(svdir, &sv) == 0) {
                const double free_gb = (double)sv.f_bavail * (double)sv.f_frsize / 1e9;
                const double want = free_gb * 0.5;
                l2_gb = want > 192.0 ? 192.0 : want;
                fprintf(stderr, "L2 auto: %.0f GB free on %s -> L2 at %.0f GB\n",
                        free_gb, svdir, l2_gb);
            }
        }
    }

    /* Incremental decode is ON by default: it is the path the README demos and every
     * long-generation use run, and the only one whose per-token cost does not grow
     * with the context. Full recompute stays available (--no-incremental) as the
     * oracle path the tiny-model gates validate. */
    incremental = incremental_default;

    /* ---- auto budget ----
     * RAM-first: per token the engine re-reads the ENTIRE streamed trunk but only
     * ~25.8 GB of experts, and steady-state expert caching yields nothing until the
     * arena is tens of GB. Measured: a gigabyte pinned in the trunk is worth roughly
     * 70x a gigabyte of expert cache at the margin. So auto gives the trunk everything
     * this machine has, minus a safety margin, and the cache gets real memory only
     * after the whole 110 GB trunk would be resident. */
    if (budget_auto) {
        const double avail = mem_available_bytes();
        if (avail <= 0.0) {
            if (budget_explicit) {
                fprintf(stderr, "auto needs /proc/meminfo; pass explicit "
                                "--trunk-gb/--cache-gb on this platform\n");
                return 2;
            }
            /* Default auto on a platform without /proc/meminfo: fall back to the
             * old fixed budgets rather than refusing to run. */
            fprintf(stderr, "auto could not read /proc/meminfo; falling back to "
                            "trunk %.1f GB / cache %.1f GB\n", trunk_gb, cache_gb);
        }
        if (avail > 0.0) {
        /* Fixed costs outside both budgets: embeddings + lm_head 4.70 GB, safetensors
         * index, recurrent state 0.63 GB, KV cache and scratch. Reserve them plus a
         * 2 GB + 2% margin so auto never invites the OOM killer. */
        const double reserve = 2.0 + 0.02 * (avail / 1e9) + 4.70 + 1.70;
        double usable = avail / 1e9 - reserve;
        const double slot_min = 2.5;   /* one ring slot + headroom; refuse below */
        const double cache_min = 0.5;  /* topk+1 expert slots is ~0.3 GB */
        if (usable < slot_min + cache_min) {
            fprintf(stderr, "auto: only %.1f GB usable after the %.1f GB reserve; "
                            "below the %.1f GB floor. Pass explicit budgets.\n",
                    usable, reserve, slot_min + cache_min);
            return 2;
        }
        /* Full residency is "packed trunk + widen headroom", measured against the ACTUAL
         * packed trunk (trunk.json layers) instead of a stale hardcoded 111.0 GB: a
         * repacked/quantised trunk changes the figure and auto must track it. */
        const double trunk_size = trunk_dir ? k3_trunk_packed_bytes(trunk_dir) / 1e9 : 0.0;
        const double trunk_full = trunk_size > 0.0 ? trunk_size + 3.0
                                                   : 111.0;   /* widen+ring headroom;
                                                                no trunk: legacy figure */
        if (usable - cache_min >= trunk_full) {
            /* Full residency: per-token trunk reads disappear entirely. This is the
             * configuration auto exists for. */
            trunk_gb = trunk_full;
            cache_gb = usable - trunk_full;
        } else {
            /* Sub-residency: the whole trunk cannot fit this machine. The tuned optimum,
             * measured on the reference 28 GB box, is trunk 12 GB / cache 8 GB:
             *   - trunk 12 pins layers 0..5 (a prefix bound first every token), shrinking
             *     per-token trunk re-read from the full 56.6 GB down to ~50.6 GB while
             *     keeping the NVMe streaming fast; more than ~16 GB pins the small
             *     0.65 GB layers almost one per GB and buys little.
             *   - expert cache past ~10 GB is nearly useless on K3's flat router (LRU
             *     and even LFU/heat both measure ~0% hit below a 32 GB arena on the
             *     captured traces), so 8 GB is a comfortable floor, not a starvation.
             * Scale the split down proportionally if the box is even smaller; the
             * fixed reserve already keeps the process clear of the OOM killer without
             * the old 55%-of-RAM pin ceiling (which starved the cache to 0.5 GB). */
            const double tuned = 20.0;      /* trunk 12 + cache 8 */
            const double k = usable >= tuned ? 1.0 : usable / tuned;
            trunk_gb = 12.0 * k;
            cache_gb = 8.0 * k;
            if (trunk_gb < slot_min) trunk_gb = slot_min;
            if (cache_gb < cache_min) cache_gb = cache_min;
        }
        printf("auto budget: %.1f GB available, %.1f GB reserved -> trunk %.1f GB / "
               "expert cache %.1f GB\n", avail / 1e9, reserve, trunk_gb, cache_gb);
        }
    }

    /* fa is sized for the released 24 MLA layers with generous headroom; k3_cfg_load
     * refuses a config that would overrun it rather than truncating the layer map. */
    K3Cfg c; static int fa[128];
    if (!real_cfg(&c, fa, 128, dir, cfg_path)) {
        fprintf(stderr, "ABORTED: the model config could not be read with confidence.\n");
        return 2;
    }
    if (want_layers > 0 && want_layers < c.n_layers) {
        printf("NOTE: binding only the first %d of %d layers. Output is NOT the full "
               "model; it is a partial stack for testing the machinery.\n\n",
               want_layers, c.n_layers);
    }

    /* Simulated MXFP4 GEMV chip (k3_chip.h). Reads K3_NO_CHIP / CHIP_NWORKERS /
     * CHIP_TFLOPS / CHIP_GBPS, warms the MXFP4 decode tables, serialises the
     * k3_matmul_mxfp4 kernel and spawns the expert pool. No-op when disabled. */
    k3_chip_init();

    /* ---- prompt ----
     * Three entry points, one representation. --ids is the reproducible channel every
     * fixture and the oracle use, and stays the default for validation work. --prompt /
     * --prompt-file tokenize here in C, which is what makes the engine text-in/text-out
     * without a Python step. The tokenizer is loaded ONLY when actually needed, so the
     * id path keeps working on a box that has no tokenizer files at all. */
    /* Heap, not stack. This was `int prompt[4096]` and it was the reason the engine
     * refused prompts longer than 4096 ids -- a stack-array size, not a model or memory
     * limit. */
    int *prompt = (int *)malloc((size_t)K3_MAX_PROMPT * sizeof(int));
    if (!prompt) { fprintf(stderr, "OOM allocating prompt buffer\n"); return 2; }
    int np = 0;
    Tok tok; int have_tok = 0;

    if (prompt_text || prompt_file) {
        if (!tok_dir) {
            fprintf(stderr, "--prompt/--prompt-file need --tok DIR (the directory with "
                            "tiktoken.model and tokenizer_config.json)\n");
            return 2;
        }
        k3_tok_load(&tok, tok_dir);
        have_tok = 1;

        char *ptext = NULL; long plen = 0;
        if (prompt_file) {
            ptext = tk_read_file(prompt_file, &plen);   /* exits if unreadable */
        } else {
            plen  = (long)strlen(prompt_text);
            ptext = (char *)malloc((size_t)plen + 1);
            if (!ptext) { fprintf(stderr, "OOM on prompt\n"); return 2; }
            memcpy(ptext, prompt_text, (size_t)plen + 1);
        }
        np = tok_encode(&tok, ptext, (int)plen, prompt, K3_MAX_PROMPT);
        free(ptext);
        printf("  tokenized: %ld bytes -> %d ids\n", plen, np);
    } else {
        for (const char *p = ids_s; *p && np < K3_MAX_PROMPT; ) {
            prompt[np++] = (int)strtol(p, (char **)&p, 10);
            while (*p == ',' || *p == ' ') p++;
        }
    }
    if (np == 0) { fprintf(stderr, "no prompt ids parsed\n"); return 2; }
    for (int i = 0; i < np; i++)
        if (prompt[i] < 0 || prompt[i] >= c.vocab) {
            fprintf(stderr, "token id %d is outside the vocabulary of %d\n", prompt[i], c.vocab);
            return 2;
        }

    /* Validate the request before allocating anything.
     *
     * Refuse rather than clamp: a caller who asks for more tokens than this build
     * supports should be told, not quietly handed fewer. The decode loop's own guard
     * (T >= Tmax) is a backstop, not a bounds check. */
    if (gen < 0 || gen > K3_MAX_GEN) {
        fprintf(stderr, "--gen %d is out of range: this build generates at most %d "
                        "tokens (outtok[%d])\n", gen, K3_MAX_GEN, K3_MAX_GEN);
        return 2;
    }
    for (int s = 0; s < n_stop; s++) {
        if (stop_id[s] >= c.vocab) {
            fprintf(stderr, "--stop-id %d is outside the vocabulary of %d; with no way "
                            "to distinguish 'never emitted' from an out-of-range sentinel, "
                            "stopping on it would be a silent bug\n", stop_id[s], c.vocab);
            return 2;
        }
    }
    if (np > K3_MAX_PROMPT) {
        fprintf(stderr, "prompt of %d ids exceeds the %d-id ceiling (seq[%d])\n",
                np, K3_MAX_PROMPT, K3_MAX_PROMPT + K3_MAX_GEN);
        return 2;
    }
    if (np + gen + 1 > K3_MAX_PROMPT + K3_MAX_GEN) {
        fprintf(stderr, "prompt %d + gen %d + 1 exceeds the %d-position ceiling\n",
                np, gen, K3_MAX_PROMPT + K3_MAX_GEN);
        return 2;
    }
    /* THE REAL CONTEXT LIMIT is the MLA KV cache, not any array size. Check it against
     * what the kernel says is actually available and refuse with both numbers, rather
     * than letting a long prompt get 40 minutes into a run and then be OOM-killed. Only
     * incremental decode allocates the KV cache; full recompute carries no cache. */
    if (incremental) {
        const double kv_need = (double)(np + gen + 1) * K3_KV_BYTES_PER_POS;
        const double avail   = mem_available_bytes();
        char kb[32], ab[32];
        human(kv_need, kb, sizeof kb);
        human(avail, ab, sizeof ab);
        printf("  KV cache : %s for %d positions (%.2f MB/position)\n",
               kb, np + gen + 1, K3_KV_BYTES_PER_POS / 1e6);
        if (avail > 0.0 && kv_need > avail * 0.9) {
            fprintf(stderr,
                "\nREFUSING: the KV cache for %d positions needs %s but only %s is\n"
                "available. This is a MEMORY limit, not an engine ceiling: MLA caches\n"
                "expanded k and v in fp32 across 24 layers, so context costs ~2.37 MB per\n"
                "position regardless of budget. Shorten the request, or use full\n"
                "recompute (drop --incremental), which carries no KV cache at all.\n",
                np + gen + 1, kb, ab);
            return 2;
        }
    }

    char b1[32];
    printf("Kimi K3, pure C, released checkpoint\n");
    /* The directory, not a shard count: the index has not been built yet at this point.
     * The count is printed by the "indexed N tensors from M shards" line below, once
     * k3_st_open has actually counted them. */
    printf("  model    : %s\n", dir);
    printf("  prompt   : %d tokens, generating %d\n", np, gen);
    /* Echo the preset so a captured log is self-describing: a timing figure is
     * meaningless without the budget that produced it. */
    if (preset_name)
        printf("  preset   : %s (trunk %.1f GB / expert cache %.1f GB)\n",
               preset_name, trunk_gb, cache_gb);
    printf("\n");

    K3St st;
    double t0 = now_s();
    if (k3_st_open_dir(&st, dir, embed_dir) != 0) return 1;
    printf("indexed %d tensors from %d shards in %.2f s\n", st.nt, st.nshard, now_s() - t0);

    /* Unified media-tier I/O scheduler, one per process. Tier 0 = fast NVMe
     * (trunk stream + expert L2 hit), 4 workers; tier 1 = slow checkpoint
     * (expert miss), 1 worker. All disk reads queue through it so the slow tier
     * can never stall the fast one (the old per-burst gate parked the trunk 382 s
     * to let 153 s of slow-disk misses through). */
    static K3IO g_io;
    static int  g_io_once = 0;
    if (!g_io_once) {
        const int nw[2] = { 4, 1 };
        k3_io_init(&g_io, 2, nw);
        g_io_once = 1;
    }
    st.kio = getenv("K3_NOKIO") ? NULL : &g_io;
    st.tier = (int *)calloc((size_t)st.nshard, sizeof(int));
    if (!st.tier) return 1;
    /* embed/lm_head shard lives on sdd7 (NVMe tier 0); routed experts stay on the
     * slow checkpoint (tier 1). The embed shard is the one redirect to embed_dir. */
    for (int s = 0; s < st.nshard; s++) st.tier[s] = 1;   /* slow checkpoint default */
    if (embed_dir) {
        for (int s = 0; s < st.nshard; s++) {
            if (strstr(st.path[s], "model-00094")) st.tier[s] = 0;  /* NVMe */
        }
    }

    /* ---- how much will this take? Report BEFORE allocating, so a box that cannot
     * hold it fails with a number rather than an OOM kill. ---- */
    const int NL = (want_layers > 0 && want_layers < c.n_layers) ? want_layers : c.n_layers;
    int64_t total = 0; int missing = 0;
    for (int L = 0; L < NL; L++) {
        const int64_t n = k3_bind_layer_bytes(&st, &c, L);
        if (n < 0) { missing++; continue; }
        total += n;
    }
    if (missing) {
        fprintf(stderr, "\n%d of %d layers are missing tensors in this shard set. "
                        "A partial download cannot run the model.\n", missing, NL);
        return 1;
    }
    human((double)total, b1, sizeof b1);
    /* Report the mode actually in effect. The trunk is either resident or streamed and
     * the two have very different memory profiles, so the banner must reflect the real
     * choice rather than a default. */
    if (trunk_dir)
        printf("trunk on disk : %s total (STREAMED from %s, not held in RAM)\n",
               b1, trunk_dir);
    else
        printf("resident trunk: %s in RAM (large matrices kept in the checkpoint's bf16,\n"
               "  fp32 only for the norms and biases that kernels read elementwise)\n", b1);

    /* Add up EVERYTHING before allocating anything. Being OOM-killed halfway through
     * binding wastes the whole load and reports nothing useful; a refusal with the two
     * numbers side by side says exactly what box this needs. */
    {
        const int64_t E64 = c.hidden;
        const double w_trunk = trunk_dir ? trunk_gb * 1e9 : (double)total;
        const double w_model = 2.0 * (double)c.vocab * E64 * 2    /* embed + lm_head, bf16 */
                             + 3.0 * E64 * 4;                     /* norms, aggregator */
        const double w_cache = cache_gb * 1e9;
        const int Tm = np + gen + 1;
        const int mb = c.n_layers / c.attn_res_block + 2;
        const int Pp = c.kda_heads * c.kda_head_dim;
        const double w_state = (double)((size_t)Pp * c.kda_head_dim
                              + (size_t)3 * Pp * (c.conv_k - 1)) * NL * 4;
        const double w_buf = ((double)Tm * E64 + (double)Tm * mb * E64
                              + (double)k3_layer_scratch(&c, Tm) + (double)c.vocab) * 4;
        /* The KV cache MUST be in this total: it is the only term that grows with
         * context, so a guard that omits it is blind to the one thing it exists to
         * catch. k3_mla_cached stores expanded per-head k and v plus the shared rope
         * slot, in fp32, across all 24 MLA layers -- 2.37 MB per position, so a
         * 4096-token prompt alone is 9.7 GB. */
        int n_mla = 0;
        for (int L = 0; L < c.n_layers; L++) if (k3_is_mla(&c, L)) n_mla++;
        const double w_kv = incremental
            ? (double)Tm * n_mla
              * ((double)c.n_heads * (c.qk_nope + c.v_head) + c.qk_rope) * 4
            : 0.0;
        const double need_b = w_trunk + w_model + w_cache + w_state + w_buf + w_kv;
        const double have = mem_available_bytes();

        char b2[32], b3[32], b4[32], b5[32], b6[32], b7[32];
        human(w_kv, b7, sizeof b7);
        human(w_trunk, b1, sizeof b1); human(w_model, b2, sizeof b2);
        human(w_cache, b3, sizeof b3); human(w_state, b4, sizeof b4);
        human(w_buf, b5, sizeof b5);   human(need_b, b6, sizeof b6);
        printf("\nmemory plan\n");
        printf("  trunk %-10s %s\n  embed + lm_head  %s\n  expert cache     %s\n"
               "  recurrent state  %s\n  buffers          %s\n  KV cache         %s\n"
               "  TOTAL            %s\n",
               trunk_dir ? "(STREAMED)" : "(resident)", b1, b2, b3, b4, b5, b7, b6);
        if (have > 0.0) {
            human(have, b1, sizeof b1);
            printf("  available        %s\n", b1);
            if (need_b > have * 0.95) {
                human(need_b - have, b2, sizeof b2);
                fprintf(stderr,
                        "\nREFUSING TO START: this needs %s and the machine has %s "
                        "available, a shortfall of %s.\n"
                        "Options: a larger box, a smaller --cache-gb, or fewer --layers.\n",
                        b6, b1, b2);
                return 1;
            }
        }
        printf("\n");
    }

    Weights w; memset(&w, 0, sizeof w);
    w.loop_serial = loop_serial;
    w.loop_block = loop_block;
    w.lay = (K3LayerBind *)calloc((size_t)NL, sizeof(K3LayerBind));
    if (!w.lay) return 1;

    static K3Trunk trunk;
    t0 = now_s();
    if (trunk_dir) {
        /* STREAMED. Nothing is bound up front: each layer is read from the packed trunk
         * on fast local storage as the forward pass reaches it. RAM stops being a floor
         * and becomes a dial, and unlike quantisation it costs no accuracy, which
         * matters because the K3 report (4.1.4) keeps exactly these tensors in higher
         * precision on purpose. */
        if (k3_trunk_open(&trunk, trunk_dir, &c, (int64_t)(trunk_gb * 1e9), trunk_ring) != 0) return 1;
        if (trunk.n_layers < NL) {
            fprintf(stderr, "packed trunk has %d layers, need %d\n", trunk.n_layers, NL);
            return 1;
        }
        /* Unified media-tier I/O: tier 0 = fast NVMe (trunk + expert L2 hit), 4
         * workers; tier 1 = slow checkpoint (expert miss, embed), 1 worker. All disk
         * reads queue through this scheduler, so the slow tier can never stall the
         * fast one (the old per-burst gate parked the trunk 382 s to let 153 s of
         * slow-disk misses through). */
        trunk.kio = getenv("K3_NOKIO") ? NULL : &g_io;
        w.trunk = &trunk;
        w.n_bound = NL;
        printf("trunk streaming enabled from %s in %.1f s\n", trunk_dir, now_s() - t0);
    } else {
        for (int L = 0; L < NL; L++) {
            if (k3_bind_layer(&st, &c, L, &w.lay[L]) != 0) {
                fprintf(stderr, "bind failed at layer %d\n", L); return 1;
            }
            w.n_bound = L + 1;
            if ((L + 1) % 10 == 0 || L + 1 == NL) {
                printf("  bound %d/%d layers, %.1f s elapsed\n", L + 1, NL, now_s() - t0);
                fflush(stdout);
            }
        }
        const double t_bind = now_s() - t0;
        printf("trunk loaded in %.1f s (%.0f MB/s from disk)\n",
               t_bind, (double)total / 1e6 / t_bind);
    }

    t0 = now_s();
    if (k3_bind_model(&st, &c, 1, &w.mb) != 0) return 1;
    human((double)w.mb.nbytes, b1, sizeof b1);
    printf("embedding, final norm and lm_head: %s in %.1f s\n\n", b1, now_s() - t0);

    K3Cache cache;
    if (k3_cache_init(&cache, &st, &c, (int64_t)(cache_gb * 1e9)) != 0) return 1;
    /* The unified k3_io scheduler replaces the old 0/1 expert gate: trunk stream and
     * expert reads now share the fast drive by separate media tiers, so the trunk
     * reader is never parked for a slow-disk burst (was 382 s of parking for 153 s
     * of misses). phase2_hold is left NULL on purpose. */
    cache.phase2_hold = NULL;
    cache.phase2_ctx = (void *)&trunk;

    /* Optional second-level disk cache on a fast volume. The RAM slot_bytes holds
     * nbytes + 2*ALIGN for the widened O_DIRECT read, so the clean expert payload is
     * slot_bytes - 2*ALIGN, the number of bytes we store per L2 slot. */
    K3L2 l2;
    int have_l2 = 0;
    if (l2_path) {
        const int64_t l2_slot = cache.slot_bytes - 2 * K3_ST_ALIGN;
        if (k3_l2_init(&l2, l2_path, (int64_t)(l2_gb * 1e9),
                       c.n_layers, c.n_experts, l2_slot) == 0) {
            l2.kio = getenv("K3_NOKIO") ? NULL : &g_io;
            cache.l2 = (struct K3L2 *)&l2;
            l2.policy = l2_policy;
            have_l2 = 1;
            printf("expert L2 cache enabled: %d slots x %.2f MB = %.2f GB on %s\n",
                   l2.nslot, (double)l2.slot_bytes / 1e6,
                   (double)l2.nslot * l2.slot_bytes / 1e9, l2_path);
            printf("expert L2 eviction policy: %s\n",
                   l2_policy == 1 ? "lru" : "heat");
        } else {
            fprintf(stderr, "warning: failed to open L2 cache %s; using slow disk only\n",
                    l2_path);
        }
    }
    {   /* The plan is a forecast. This is the outcome. */
        char rb[32];
        human(peak_rss_bytes(), rb, sizeof rb);
        printf("peak RSS after loading weights: %s  (the plan above is a forecast, "
               "this is measured)\n", rb);
    }
    printf("expert cache: %d slots x %.2f MB = %.2f GB (%.2f%% of the 1.45 TB expert pool)\n\n",
           cache.nslot, (double)cache.slot_bytes / 1e6,
           (double)cache.nslot * cache.slot_bytes / 1e9,
           100.0 * cache.nslot / (double)(92 * c.n_experts));

    /* ---- buffers ----
     * A resumed session must hold the saved history as well as the new tokens, so the
     * KV cache and every per-position buffer are sized for both. The header is read
     * here, before anything is allocated; the payload is restored after. */
    K3StateHdr shd;
    int prior = 0;
    if (load_state) {
        if (!incremental) {
            fprintf(stderr, "--load-state needs --incremental\n");
            return 2;
        }
        if (k3_state_peek(load_state, &shd) != 0) return 1;
        prior = shd.nseq;
        printf("resuming from %s: %d prior positions, %d new\n\n", load_state, prior, np);
    }
    const int Tmax = prior + np + gen + 1;
    const int E = c.hidden;
    const int maxb = c.n_layers / c.attn_res_block + 2;
    const int P = c.kda_heads * c.kda_head_dim;
    const size_t kper = (size_t)P * c.kda_head_dim + (size_t)3 * P * (c.conv_k - 1);

    /* The model-level aggregator lays out fold[E] followed by (nb+1) source rows of E
     * inside scratch, and nb reaches n_layers/attn_res_block = 8 at full depth. So
     * scratch must hold at least (maxb + 2) * hidden floats. k3_layer_scratch includes
     * exactly that term, but an off-by-one here would overwrite whatever follows
     * without any symptom until the logits came out subtly wrong, so it is checked
     * rather than assumed. */
    {
        const size_t need_scratch = (size_t)(maxb + 2) * E;
        const size_t have_scratch = k3_layer_scratch(&c, Tmax);
        if (have_scratch < need_scratch) {
            fprintf(stderr, "scratch is %zu floats, the attn-res aggregator needs %zu\n",
                    have_scratch, need_scratch);
            return 1;
        }
    }

    float *h  = (float *)malloc((size_t)Tmax * E * sizeof(float));
    float *br = (float *)malloc((size_t)Tmax * maxb * E * sizeof(float));
    float *ks = (float *)malloc(kper * (size_t)NL * sizeof(float));
    size_t sc_need = k3_layer_scratch(&c, Tmax);
    {   /* the cached MLA path sizes its score buffer by cache capacity, not by T */
        const size_t ic = k3_mla_scratch_cached(&c, Tmax, Tmax, 1);
        if (ic > sc_need) sc_need = ic;
    }
    float *sc = (float *)malloc(sc_need * sizeof(float));
    float *lg = (float *)malloc((size_t)c.vocab * sizeof(float));
    if (!h || !br || !ks || !sc || !lg) { fprintf(stderr, "buffer allocation failed\n"); return 1; }
    human((double)(kper * NL) * 4, b1, sizeof b1);
    printf("recurrent state for %d layers: %s\n\n", NL, b1);

    /* ---- generate ----
     * Heap and sized from the ACTUAL request, not from the ceiling. These were
     * `int seq[K3_MAX_PROMPT + K3_MAX_GEN]` and `int outtok[K3_MAX_GEN]` on the stack,
     * which is why the ceiling had to stay small enough to be a stack array. */
    int *seq = (int *)malloc((size_t)(prior + np + gen + 8) * sizeof(int));
    int *outtok = (int *)malloc((size_t)(gen + 8) * sizeof(int));
    if (!seq || !outtok) { fprintf(stderr, "OOM allocating sequence buffers\n"); return 1; }
    /* On a resume the saved history occupies the front of the sequence and the prompt
     * given now is its continuation; the restore below fills seq[0..prior). */
    memcpy(seq + prior, prompt, (size_t)np * sizeof(int));
    int T = prior + np;
    int nout = 0;

    /* ---- optional incremental decode ----
     * Full recompute re-runs the whole prefix every step, so expert traffic grows with
     * context: measured 99.7 -> 126.0 GB across just three tokens. Incremental prefills
     * once and then feeds ONE token per step, carrying the KDA recurrent state (which
     * k3_kda_layer already updates in place) and an MLA KV cache. Validated by GATE 3
     * of the tiny-model oracle, which requires the SAME tokens as full recompute. */
    if (incremental) {
        w.mla_slot = (int *)malloc((size_t)NL * sizeof(int));
        if (!w.mla_slot) return 1;
        w.n_mla = 0;
        for (int L = 0; L < NL; L++)
            w.mla_slot[L] = k3_is_mla(&c, L) ? w.n_mla++ : -1;
        w.kv_cap = Tmax;
        const size_t kvper = (size_t)w.kv_cap * c.n_heads * (c.qk_nope + c.v_head);
        const size_t rpper = (size_t)w.kv_cap * c.qk_rope;
        const double kvb = (double)(kvper + rpper) * w.n_mla * sizeof(float);
        human(kvb, b1, sizeof b1);
        printf("incremental decode: KV cache %s for %d MLA layers at %d positions\n\n",
               b1, w.n_mla, w.kv_cap);
        w.kvc   = (float *)calloc(kvper * (size_t)w.n_mla, sizeof(float));
        w.ropec = (float *)calloc(rpper * (size_t)w.n_mla, sizeof(float));
        if (!w.kvc || !w.ropec) { fprintf(stderr, "KV cache allocation failed\n"); return 1; }
        memset(ks, 0, kper * (size_t)NL * sizeof(float));
        w.cached = 0;

        if (load_state) {
            const double tl = now_s();
            if (k3_state_load(load_state, &c, &shd, seq, ks, w.kvc, w.ropec,
                              w.n_bound, w.n_mla, w.kv_cap) != 0)
                return 1;
            w.cached = shd.cached;
            printf("restored %d positions in %.2f s: decode continues without "
                   "re-reading the prior context\n\n", w.cached, now_s() - tl);
        }
    }

    /* --spec needs a snapshot of the carried KDA/ShortConv state to roll back a
     * partially-rejected draft batch: the recurrent state is updated in place and is
     * not positional, so the only sound recovery is restore-and-replay the accepted
     * prefix. The snapshot is one memcpy; the replay is one short batched sweep. */
    const size_t kperP  = (size_t)c.kda_heads * c.kda_head_dim;
    const size_t kper_f = kperP * c.kda_head_dim + 3 * kperP * (c.conv_k - 1);
    float *spec_snap = NULL;
    if (spec_n > 0) {
        if (!incremental) {
            fprintf(stderr, "--spec needs --incremental; ignoring --spec\n");
            spec_n = 0;
        } else {
            if (spec_n > K3_SPEC_MAX) spec_n = K3_SPEC_MAX;
            spec_snap = (float *)malloc(kper_f * (size_t)w.n_bound * sizeof(float));
            if (!spec_snap) { fprintf(stderr, "OOM for the --spec snapshot\n"); return 1; }
            printf("speculative decode: up to %d drafted tokens per sweep, n-gram lookup, "
                   "verified batched\n\n", spec_n);
        }
    }
    /* ---- hybrid decode: a second, typically quantized, trunk drafts ----
     * The draft model shares everything that is identical between the two models: the
     * embedding, the lm_head, the layer map, and the routed experts (the qdq derivation
     * touches only 2D trunk tensors). It differs ONLY in trunk weights, so it needs its
     * own trunk stream, its own layer bindings, and its own recurrent/KV state. Output
     * exactness is structural: drafts feed the SAME batched greedy verification as
     * --spec, so what gets emitted is precisely what the exact model would have chosen.
     * Measured teacher-forced agreement of an int8-derived draft on the released
     * checkpoint is 94.2 percent against a 96.2 percent measurement ceiling, which is
     * what makes the draft worth consulting at all. */
    static K3Trunk trunk_d;
    Weights dw; memset(&dw, 0, sizeof dw);
    float *dks = NULL, *dsnap = NULL;
    long hyb_rounds = 0, hyb_drafted = 0, hyb_accepted = 0;
    long sp_rounds = 0, sp_accepted = 0;   /* --spec observed accepted run -> A */
    if (draft_dir) {
        if (!incremental || !trunk_dir) {
            fprintf(stderr, "--draft-trunk needs --incremental and --trunk; ignoring\n");
            draft_dir = NULL;
        } else {
            if (spec_n <= 0) spec_n = 4;
            if (spec_n > K3_SPEC_MAX) spec_n = K3_SPEC_MAX;
            if (!spec_snap) {
                spec_snap = (float *)malloc(kper_f * (size_t)w.n_bound * sizeof(float));
                if (!spec_snap) { fprintf(stderr, "OOM for the --spec snapshot\n"); return 1; }
            }
            if (k3_trunk_open(&trunk_d, draft_dir, &c, (int64_t)(draft_gb * 1e9), 2) != 0)
                return 1;
            dw.lay = (K3LayerBind *)calloc((size_t)NL, sizeof(K3LayerBind));
            dks   = (float *)calloc(kper_f * (size_t)w.n_bound, sizeof(float));
            dsnap = (float *)malloc(kper_f * (size_t)w.n_bound * sizeof(float));
            const size_t kvperd = (size_t)w.kv_cap * c.n_heads * (c.qk_nope + c.v_head);
            const size_t rpperd = (size_t)w.kv_cap * c.qk_rope;
            dw.kvc   = (float *)calloc(kvperd * (size_t)w.n_mla, sizeof(float));
            dw.ropec = (float *)calloc(rpperd * (size_t)w.n_mla, sizeof(float));
            if (!dw.lay || !dks || !dsnap || !dw.kvc || !dw.ropec) {
                fprintf(stderr, "OOM for the draft model state\n"); return 1;
            }
            dw.mb = w.mb;              /* embed + lm_head are the same tensors */
            dw.trunk = &trunk_d;
            dw.n_bound = w.n_bound;
            dw.mla_slot = w.mla_slot;  /* read-only map, safely shared */
            dw.n_mla = w.n_mla;
            dw.kv_cap = w.kv_cap;
            dw.cached = 0;
            dw.draft_mode = 1;   /* cache-only routing: draft tokens read no new experts */
            printf("hybrid decode: draft trunk %s (%.1f GB budget) proposes up to %d "
                   "tokens per sweep;\n               the exact model verifies every one "
                   "before it is emitted\n\n", draft_dir, draft_gb, spec_n);
        }
    }

    /* --tf-check: teacher-forced agreement over the whole --ids sequence in ONE sweep.
     * Prediction i is the argmax after positions 0..i; it is compared to the id the
     * sequence actually continues with. This is the acceptance rate a draft model
     * would see under batched greedy verification, measured directly, and it is the
     * one number a quantized-draft design stands on. Free-running comparisons cannot
     * measure it: a single early divergence changes every later context. */
    if (tf_check) {
        if (np < 2) { fprintf(stderr, "--tf-check needs at least 2 ids\n"); return 2; }
        int *arg = (int *)malloc((size_t)np * sizeof(int));
        if (!arg) { fprintf(stderr, "OOM for --tf-check\n"); return 1; }
        const double t0c = now_s();
        if (forward(&w, &c, &cache, seq, np, lg, sc, h, br, ks, arg) != 0) {
            fprintf(stderr, "forward failed in --tf-check\n");
            return 1;
        }
        int match = 0;
        for (int i = 0; i + 1 < np; i++) match += (arg[i] == seq[i + 1]);
        printf("teacher-forced agreement: %d/%d positions (%.1f%%) in %.1f s\n",
               match, np - 1, 100.0 * match / (np - 1), now_s() - t0c);
        printf("  per-position (p=predicted a=actual): ");
        for (int i = 0; i + 1 < np; i++)
            if (arg[i] != seq[i + 1])
                printf("[%d p=%d a=%d] ", i, arg[i], seq[i + 1]);
        printf("\n");
        FILE *tf = fopen(outp, "w");
        if (tf) {
            fprintf(tf, "{\"tf_positions\":%d,\"tf_matches\":%d,\"tf_agreement\":%.4f}\n",
                    np - 1, match, (double)match / (np - 1));
            fclose(tf);
        }
        free(arg);
        return 0;
    }

    printf("%-6s %-10s %-12s %-10s %-10s %s\n",
           "STEP", "TOKEN", "SECONDS", "CACHE HIT", "READ GB", "TOK/S");
    printf("--------------------------------------------------------------------\n");
    double t_total = 0.0;
    /* Per-step cache statistics are reset each iteration so the columns below describe
     * that step alone. The end-of-run summary needs whole-run totals, so accumulate the
     * expert side here; the trunk side is already cumulative. Comparing a cumulative
     * figure against a single step would misstate the I/O share. */
    double expert_s_total = 0.0, expert_gb_total = 0.0;
    uint64_t expert_reqs_total = 0, expert_evict_total = 0;
    int *emit = (int *)malloc((size_t)(batch_gen ? gen : K3_SPEC_MAX + 1) * sizeof(int));
    if (!emit) { fprintf(stderr, "OOM for emit buffer\n"); return 1; }
    k3_expert_drops = 0;
    /* The (g == 0) disjunct is what makes --gen 0 useful: the loop body still runs once
     * to prefill and carry state, so --gen 0 --save-state warms a system prompt instead
     * of doing nothing at all. For every other g, --gen N means exactly N tokens, which
     * the benchmarks and oracle gates rely on. */
    for (int g = 0; nout < gen || (incremental && g == 0); g++) {
        k3_cache_reset_stats(&cache);
        const double ts = now_s();
        int frc = -1;   /* "not run" already means failed: a forward that never happened must abort */
        int emitn = 0;
        if (incremental && batch_gen && g == 0) {
            /* --batch-gen: ONE forward for the whole generation. All --gen positions
             * are fed together so every trunk layer binds exactly once for the whole
             * batch; the runtime price is nT0+gen positions in one sweep. The gen new
             * inputs are copies of the last real token, so the later positions do NOT
             * see a true autoregressive prefix: strictly-valid output is sacrificed
             * at the wall that per-token trunk re-reads would otherwise cost. */
            const int base = w.cached;
            const int nT0 = T - base;
            if ((long)T + gen > Tmax) {
                fprintf(stderr, "--batch-gen: %d generated positions exceed the KV cache (%d)\n",
                        gen, Tmax);
                free(emit);
                return 1;
            }
            int *argall = (int *)malloc((size_t)(nT0 + gen) * sizeof(int));
            if (!argall) { fprintf(stderr, "OOM for --batch-gen\n"); free(emit); return 1; }
            for (int k = 0; k < gen; k++)
                seq[T + k] = seq[T - 1];          /* pad: repeat last real input */
            frc = forward(&w, &c, &cache, seq + base, nT0 + gen,
                          lg, sc, h, br, ks, argall);
            if (frc == 0) {
                w.cached = base + nT0 + gen;
                for (int k = 0; k < gen; k++)
                    if (nout < gen) { emit[emitn++] = argall[nT0 - 1 + k]; }
            }
            free(argall);
        } else if (incremental && g == 0) {
            /* Step 0 feeds everything not yet consumed: the whole prompt on a fresh
             * run, and on a resume the carried pending token PLUS the new prompt.
             * T - base covers both exactly; feeding np here instead dropped the last
             * new token from a resumed batch, and the first generated token then came
             * from a context one token short: fluent, plausible, and wrong. */
            const int base = w.cached;
            const int nT0 = T - base;
            if (getenv("K3_FWD_DBG"))
                fprintf(stderr, "DBG fwd prefill g=%d T=%d base=%d nT0=%d cached=%d\n",
                        g, T, base, nT0, w.cached);
            frc = forward(&w, &c, &cache, seq + base, nT0, lg, sc, h, br, ks, NULL);
            if (frc == 0) {
                w.cached = base + nT0;
                /* loop-serial mode: prefill only, no token yet -- the block-serial
                 * generation emits ALL gen tokens in ONE later forward. */
                if (!(w.loop_serial > 0 && !w.draft_mode)) emit[emitn++] = argmax_(lg, c.vocab);
            }
            /* The draft model must absorb the same context, or its first proposals
             * come from a shorter one; one draft sweep, paid once. Saved state does
             * not include the draft's, so a resumed run replays the WHOLE sequence
             * through the draft once; correctness never depends on this, only
             * acceptance does. */
            if (dw.trunk && frc == 0) {
                const int db = load_state ? 0 : base;
                if (forward(&dw, &c, &cache, seq + db, base + nT0 - db, lg, sc, h, br,
                            dks, NULL) == 0)
                    dw.cached = base + nT0;
                else frc = -1;
            }
        } else if (incremental) {
            const int base = w.cached;
            int d[K3_SPEC_MAX], nd = 0;
            if (getenv("K3_FWD_DBG"))
                fprintf(stderr, "DBG fwd gen g=%d T=%d base=%d cached=%d loop=%d\n",
                        g, T, base, w.cached, w.loop_serial);
            if (spec_snap && T + spec_n + 1 < Tmax && base + spec_n + 1 <= w.kv_cap) {
                if (dw.trunk) {
                    /* The draft model proposes: k sequential one-token steps through
                     * the draft trunk, chaining its own argmax. Its state is
                     * snapshotted first so a partial acceptance can rewind it the
                     * same way the exact side rewinds. */
                    memcpy(dsnap, dks, kper_f * (size_t)w.n_bound * sizeof(float));
                    int prev = seq[base];
                    while (nd < spec_n) {
                        if (forward(&dw, &c, &cache, &prev, 1, lg, sc, h, br,
                                    dks, NULL) != 0) break;
                        dw.cached += 1;
                        prev = argmax_(lg, c.vocab);
                        d[nd++] = prev;
                    }
                    hyb_rounds  += 1;
                    hyb_drafted += nd;
                } else {
                    nd = spec_draft(seq, T, spec_n, d);
                }
            }
            if (nd > 0) {
                /* One sweep verifies the pending token plus nd drafts. arg[i] is the
                 * model's own next token after batch position i; the accepted prefix is
                 * exactly what serial decode would have emitted, and arg[m] after it is
                 * clean because its context contains only accepted tokens. */
                int arg[K3_SPEC_MAX + 1];
                for (int i = 0; i < nd; i++) seq[T + i] = d[i];
                /* Snapshot the exact kernel state now: a partial acceptance rejects the
                 * tail of the batch, and the KDA update is in-place and non-positional,
                 * so the only sound recovery is restore-and-replay the accepted prefix. */
                memcpy(spec_snap, ks, kper_f * (size_t)w.n_bound * sizeof(float));
                frc = forward(&w, &c, &cache, seq + base, nd + 1, lg, sc, h, br, ks, arg);
                if (frc == 0) {
                    int m = 0;
                    while (m < nd && arg[m] == d[m]) m++;
                    sp_rounds  += 1;      /* observed accepted run, any --spec draft */
                    sp_accepted += m;
                    if (m == nd) {
                        /* every fed position had true context; state is exact */
                        w.cached = base + nd + 1;
                    } else {
                        /* the recurrent state absorbed rejected tokens: restore, then
                         * replay only the accepted prefix. The replay also rewrites the
                         * KV rows those positions touched, so nothing stale survives. */
                        memcpy(ks, spec_snap, kper_f * (size_t)w.n_bound * sizeof(float));
                        w.cached = base;
                        frc = forward(&w, &c, &cache, seq + base, m + 1, lg, sc, h, br,
                                      ks, NULL);
                        if (frc == 0) w.cached = base + m + 1;
                    }
                    /* Resync the draft model to the ACCEPTED sequence. On full
                     * acceptance its state already contains every fed token except
                     * the last draft, so one step closes the gap; on partial
                     * acceptance it rewinds to its snapshot and replays only the
                     * accepted prefix, mirroring the exact side. */
                    if (dw.trunk && frc == 0) {
                        hyb_accepted += m;
                        if (m == nd) {
                            int last = d[nd - 1];
                            if (forward(&dw, &c, &cache, &last, 1, lg, sc, h, br,
                                        dks, NULL) == 0) dw.cached += 1;
                            else frc = -1;
                        } else {
                            memcpy(dks, dsnap, kper_f * (size_t)w.n_bound * sizeof(float));
                            dw.cached = base;
                            if (forward(&dw, &c, &cache, seq + base, m + 1, lg, sc,
                                        h, br, dks, NULL) == 0) dw.cached = base + m + 1;
                            else frc = -1;
                        }
                    }
                    if (frc == 0) {
                        for (int i = 0; i < m; i++) emit[emitn++] = d[i];
                        emit[emitn++] = arg[m];
                    }
                }
            } else if (w.loop_serial > 0 && !dw.trunk) {
                /* Block-serial generation: ONE forward feeds every remaining gen
                 * position so forward() runs its layer-outer schedule with T > 1 --
                 * each trunk layer is bound once for the whole batch (slow-layer
                 * reads = layers x rounds, independent of gen). Positions are seeded
                 * with the last real token; the block-serial chain inside forward()
                 * mixes each position from the previous position's block output, so
                 * the later positions see a real continuation of the earlier ones.
                 * arg_all returns every position's argmax. */
                const int remaining = gen;   /* feed ALL gen positions: block-serial needs T>1 */
                if (getenv("K3_FWD_DBG"))
                    fprintf(stderr, "DBG fwd loop g=%d T=%d base=%d remaining=%d\n",
                            g, T, base, remaining);
                if (remaining > 1 && (long)T + remaining <= Tmax &&
                    base + remaining <= w.kv_cap) {
                    for (int k = 0; k < remaining; k++)
                        seq[T + k] = seq[T - 1];
                    int *argall = (int *)malloc((size_t)remaining * sizeof(int));
                    if (!argall) { fprintf(stderr, "OOM for loop-serial\n"); free(emit); return 1; }
                    frc = forward(&w, &c, &cache, seq + base, remaining, lg, sc, h, br,
                                  ks, argall);
                    if (frc == 0) {
                        w.cached = base + remaining;
                        for (int k = 0; k < remaining; k++)
                            if (nout < gen) { emit[emitn++] = argall[k]; }
                    }
                    free(argall);
                } else {
                    frc = forward(&w, &c, &cache, seq + base, 1, lg, sc, h, br, ks, NULL);
                    if (frc == 0) { w.cached = base + 1; emit[emitn++] = argmax_(lg, c.vocab); }
                }
            } else {
                /* STANDARD incremental decode: one new position, advancing cached.
                 * (91e6689 regressed this to forward(seq, T) which re-ran the whole
                 * prefix WITHOUT advancing w.cached, so the next step's KV writes
                 * collided with already-cached positions and k3_mla_cached aborted
                 * with a position past cap. base == w.cached here.) */
                frc = forward(&w, &c, &cache, seq + base, 1, lg, sc, h, br, ks, NULL);
                if (frc == 0) { w.cached = base + 1; emit[emitn++] = argmax_(lg, c.vocab); }
                /* keep the draft in lockstep through non-drafted steps */
                if (dw.trunk && frc == 0) {
                    if (forward(&dw, &c, &cache, seq + base, 1, lg, sc, h, br,
                                dks, NULL) == 0) dw.cached = base + 1;
                    else frc = -1;
                }
            }
        }
        /* Abort the run rather than argmax a buffer the forward never wrote. In loop-serial
         * mode the prefill step (g==0) emits no token by design -- the block-serial
         * generation emits all of them in the next iteration -- so a clean prefill
         * (frc==0) with emitn==0 is fine there. */
        if (frc != 0 || (emitn == 0 && !(w.loop_serial > 0 && g == 0 && !w.draft_mode))) {
            fprintf(stderr, "forward pass failed at generation step %d; aborting.\n", g);
            free(emit);
            return 1;
        }
        const int nxt = emit[emitn - 1];
        /* Dump the FIRST step's logits as raw float32 bits.
         * Comparing generated tokens against a reference only compares argmax, which
         * hides near-ties: two engines can agree on every token while disagreeing
         * substantially on the logit vector behind it. tools/ref_forward.py produces the
         * same vector from the same shards in torch, and tools/cmp_logits.py compares
         * them elementwise. That is the only check here that can see a small systematic
         * error in the final norm, the lm_head, or the model-level AttnRes. */
        if (logits_path && g == 0) {
            FILE *lf = fopen(logits_path, "wb");
            if (lf) {
                fwrite(lg, sizeof(float), (size_t)c.vocab, lf);
                fclose(lf);
                printf("wrote %s (%d float32 logits)\n", logits_path, c.vocab);
            } else {
                fprintf(stderr, "cannot open %s for the logits dump\n", logits_path);
            }
        }
        const double dt = now_s() - ts;
        t_total += dt;
        const uint64_t req = cache.hits + cache.misses;
        printf("%-6d %-10d %-12.2f %-10.1f %-10.2f %.3f\n", g, nxt, dt,
               req ? 100.0 * cache.hits / req : 0.0,
               (double)cache.bytes_read / 1e9, 1.0 / dt);
        if (have_l2) {
            int resident = 0;
            for (int s = 0; s < l2.nslot; s++)
                if (l2.key_of[s] >= 0) resident++;
            const uint64_t lreq = l2.hits + l2.misses;
            const double l2_hit = lreq ? 100.0 * l2.hits / lreq : 0.0;
            printf("  L2   resident=%d/%d slots hit=%.1f%% read=%.2fGB write=%.2fGB\n",
                   resident, l2.nslot, l2_hit,
                   (double)l2.bytes_read / 1e9, (double)l2.bytes_written / 1e9);
        }
        fflush(stdout);
        /* Roll the per-step figures up before the next reset wipes them. */
        expert_s_total     += cache.load_seconds;
        expert_gb_total    += (double)cache.bytes_read / 1e9;
        expert_reqs_total  += cache.hits + cache.misses;
        expert_evict_total += cache.evictions;
        for (int i = 0; i < emitn && nout < gen && T < Tmax; i++) {
            seq[T++] = emit[i];
            outtok[nout++] = emit[i];
            for (int s = 0; s < n_stop; s++)
                if (emit[i] == stop_id[s]) { hit_stop = 1; stopped_at = emit[i]; break; }
            if (hit_stop) break;
        }
        if (hit_stop) {
            printf("stop id %d reached after %d of %d tokens\n", stopped_at, nout, gen);
            break;
        }
        if (T >= Tmax) break;
    }
    free(emit);
    if (save_state) {
        if (!incremental) {
            fprintf(stderr, "--save-state needs --incremental; nothing written\n");
        } else {
            const double tsv = now_s();
            const int64_t kvpp   = (int64_t)c.n_heads * (c.qk_nope + c.v_head);
            const int64_t ropepp = (int64_t)c.qk_rope;
            if (k3_state_save(save_state, &c, seq, T, ks, w.kvc, w.ropec,
                              w.n_bound, w.n_mla, w.kv_cap, w.cached,
                              (int64_t)kper, kvpp, ropepp) == 0) {
                const double bytes = (double)sizeof(K3StateHdr) + (double)T * sizeof(int)
                    + (double)kper * w.n_bound * sizeof(float)
                    + (double)w.cached * (kvpp + ropepp) * w.n_mla * sizeof(float);
                char sb[32]; human(bytes, sb, sizeof sb);
                printf("wrote %s (%s, %d positions) in %.2f s\n",
                       save_state, sb, w.cached, now_s() - tsv);
            }
        }
    }

    if (dw.trunk && hyb_rounds > 0) {
        printf("\nhybrid decode: %ld rounds, %ld drafted, %ld accepted (%.1f%%), "
               "mean accepted run %.2f\n",
               hyb_rounds, hyb_drafted, hyb_accepted,
               hyb_drafted ? 100.0 * hyb_accepted / hyb_drafted : 0.0,
               (double)hyb_accepted / hyb_rounds);
        k3_trunk_close(&trunk_d);
        free(dw.lay); free(dks); free(dsnap); free(dw.kvc); free(dw.ropec);
    }
    free(spec_snap);
    if (sp_rounds > 0)
        printf("--spec: %ld rounds, mean accepted run %.2f (A)\n",
               sp_rounds, (double)sp_accepted / sp_rounds);
    printf("--------------------------------------------------------------------\n");
    if (nout > 0)
        printf("%d tokens in %.1f s, %.2f s/token average\n",
               nout, t_total, t_total / nout);
    else
        printf("prefill only: %d positions cached, 0 tokens generated\n", w.cached);

    /* Decoded text, when a tokenizer is loaded. Printed as a distinct block rather than
     * streamed per token: a partially-decoded multi-byte sequence is not valid UTF-8, so
     * streaming would emit mojibake at every token boundary that splits a codepoint. */
    char *generated_text = NULL;
    if (have_tok && nout > 0) {
        generated_text = (char *)malloc((size_t)nout * 8 + 1);
        if (generated_text) {
            int m = tok_decode(&tok, outtok, nout, generated_text, nout * 8);
            generated_text[m] = 0;
            printf("\n--- generated text ---\n%s\n----------------------\n\n",
                   generated_text);
        }
    }
    const double peak_b = peak_rss_bytes();
    {
        char rb[32];
        human(peak_b, rb, sizeof rb);
        printf("PEAK RSS for the whole run: %s   <- quote this, not the plan\n", rb);
        printf("layers completed: %d/%d; routed expert drops: %ld\n\n",
               w.layers_completed, NL, k3_expert_drops);
    }
    /* Simulated-chip bill (k3_chip.h): the routed-expert load read as packed MXFP4, in
     * accelerator terms. Token count covers prefill plus every generated step. */
    k3_chip_set_tokens(np + nout);
    k3_chip_print_bill();
    k3_cache_report(&cache, "final step");
    if (have_l2) k3_l2_report(&l2, "final step");

    FILE *f = fopen(outp, "w");
    if (f) {
        fprintf(f, "{\"prompt_ids\":[");
        for (int i = 0; i < np; i++) fprintf(f, "%s%d", i ? "," : "", prompt[i]);
        fprintf(f, "],\"generated_ids\":[");
        for (int i = 0; i < nout; i++) fprintf(f, "%s%d", i ? "," : "", outtok[i]);
        fprintf(f, "],\"full_ids\":[");
        for (int i = 0; i < T; i++) fprintf(f, "%s%d", i ? "," : "", seq[i]);
        fprintf(f, "],\"layers\":%d,\"layers_requested\":%d,\"layers_completed\":%d,"
                "\"expert_drops\":%ld,\"peak_rss_bytes\":%.0f,\"wall_seconds\":%.4f,"
                "\"seconds_per_token\":%.4f,\"expert_bytes_read\":%.0f,"
                "\"trunk_bytes_read\":%llu,\"stopped_at\":%d,"
                "\"generated_text\":",
                NL, NL, w.layers_completed, k3_expert_drops, peak_b, t_total,
                nout ? t_total / nout : 0.0, expert_gb_total * 1e9,
                (unsigned long long)(w.trunk ? w.trunk->bytes_read : 0), stopped_at);
        json_string(f, generated_text);
        fputs("}\n", f);
        fclose(f);
        printf("\nwrote %s\n", outp);
    }
    if (trace_dir) {
        char p[4096];
        snprintf(p, sizeof p, "%s/expert_hist.json", trace_dir);
        k3_cache_dump_hist(&cache, p);
        snprintf(p, sizeof p, "%s/expert_trace.bin", trace_dir);
        k3_cache_dump_trace(&cache, p);
    }

    free(w.kvc); free(w.ropec); free(w.mla_slot);
    /* Report the compute-versus-I/O split rather than leaving it to be inferred.
     *
     * It cannot be inferred safely: a flat curve across a RAM sweep looks like evidence
     * of a compute-bound engine, but it is equally consistent with the trunk being
     * streamed in full at every point of the sweep, so that the bytes moved barely
     * change. Those two have opposite tuning implications, and only a direct measurement
     * separates them. */
    {
        const double trunk_s = w.trunk ? w.trunk->load_seconds : 0.0;
        /* Both terms MUST be whole-run totals over the same window. Mixing a cumulative
         * trunk time with a last-step expert time and dividing by the whole run
         * understates the expert share by roughly the token count. */
        const double io_s = trunk_s + expert_s_total;
        const double share = t_total > 0 ? 100.0 * io_s / t_total : 0.0;
        printf("I/O share of wall clock: %.1f%%  (trunk %.1f s + experts %.1f s of %.1f s)\n",
               share, trunk_s, expert_s_total, t_total);
        printf("  both figures are WHOLE-RUN totals over %d steps\n", nout);
        /* Above 100% is not a bug in the arithmetic: with more than one trunk ring slot
         * the reader thread does device work while the main thread computes, so the two
         * terms genuinely overlap and their sum can exceed wall clock. Say so, rather
         * than printing an impossible percentage with no explanation. */
        if (share > 100.0)
            printf("  over 100%% because trunk reads overlap compute on the reader thread;\n"
                   "  %.1f s of device time was hidden behind arithmetic\n", io_s - t_total);
        /* Report the DERIVED retention, not the raw hit count. `hits` counts an expert
         * the batch prefetch pulled off disk microseconds earlier, so it equals the
         * request count at every cache size and means nothing on its own. An expert that
         * had to be evicted is one that was not retained, so retained = requests -
         * evictions. The raw hit count is deliberately not printed beside this
         * percentage: "35328 of 35328 requests hit ... 2.09%% retained" reads as a
         * contradiction even though both numbers are correct. */
        const unsigned long long retained =
            (expert_reqs_total > expert_evict_total)
                ? (unsigned long long)(expert_reqs_total - expert_evict_total) : 0ULL;
        printf("  experts, whole run: %.2f GB read | %llu of %llu requests retained in RAM"
               " (%.2f%%) | %llu evictions\n"
               "    (retention = requests - evictions; the raw `hits` counter includes\n"
               "     experts the prefetcher had just read from disk, so it is not a\n"
               "     measure of avoided I/O)\n\n",
               expert_gb_total, retained,
               (unsigned long long)expert_reqs_total,
               expert_reqs_total ? 100.0 * (double)retained / (double)expert_reqs_total : 0.0,
               (unsigned long long)expert_evict_total);
    }
    if (w.trunk) { k3_trunk_report(w.trunk, "final"); k3_trunk_close(w.trunk); }
    k3_cache_free(&cache);
    if (have_l2) k3_l2_free(&l2);
    for (int L = 0; L < w.n_bound; L++) k3_bind_free(&w.lay[L]);
    free(w.lay);
    k3_bind_model_free(&w.mb);
    k3_st_close(&st);
    free(h); free(br); free(ks); free(sc); free(lg); free(generated_text);

    /* Join the simulated chip's pool now that no forward pass can touch it again. */
    k3_chip_destroy();

    /* A dropped expert means some token was computed with part of its routed sum
     * missing. The run still produced token ids and they still look plausible, which is
     * exactly why this has to be an error rather than a note: silent numerical
     * corruption that exits 0 is indistinguishable from a good run. */
    if (k3_expert_drops) {
        fprintf(stderr,
                "\nRUN INVALID: %ld routed expert load(s) failed and were dropped from\n"
                "the MoE sum. The token ids above are CORRUPT. Re-run; if this repeats,\n"
                "the shard set or the storage is at fault.\n", k3_expert_drops);
        return 4;
    }
    return 0;
}
