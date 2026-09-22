/* k3_trunk.c - see k3_trunk.h for why the trunk is streamed rather than quantised. */
#define _GNU_SOURCE            /* O_DIRECT */
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64

#include "k3_portable_io.h"   /* first: sets _DARWIN_C_SOURCE before any libc header */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <pthread.h>

#include "json.h"
#include "k3_st.h"
#include "k3_bind.h"
#include "k3_io.h"
#include "k3_trunk.h"

static int k3_alloc_direct(void **out, size_t bytes);   /* defined below */

/* Read granularity for the async reader, also the quantum between expert-gate checks.
 * A multiple of K3_TRUNK_ALIGN (4096) so every partial chunk stays O_DIRECT-safe.
 * Measured on this machine (SINKER NVMe via WSL): single-stream O_DIRECT throughput
 * rises with chunk size -- 8 MiB: ~850 MB/s, 32 MiB: ~1.1 GB/s -- and the trunk read
 * must fit the per-layer window left by the expert burst, so the larger chunk is a
 * pure win. The gate still parks between chunks; a bigger chunk just means the
 * pread loop spends less time on per-chunk setup per byte. */
#define TRUNK_READ_CHUNK (32u << 20)

typedef struct {
    pthread_t thread;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    K3Trunk *tr;
    int stop;
    int busy;
    int done;
    int layer;
    int slot;
    int result;
    /* Pending prefetch: set while busy==1 so the hint survives the current read. The
     * reader's completion broadcast wakes the binder, whose next prefetch call issues
     * the newest requested layer once busy clears -- a gate-parked reader otherwise
     * makes every later hint vanish and the following binds fall back to synchronous
     * reads on the main thread, stalling it for the whole expert burst. */
    int pending;    /* layer to read next, -1 none */
    /* NVMe gate: while gate==1 the async reader waits between chunks, so the expert
     * cache's phase-2 scattered burst gets the device to itself. Without it, the trunk
     * reader's sequential stream and the experts' scattered reads run beside each other
     * and share one drive: 995 MB/s + 639 MB/s ≈ 1.6 GB/s is the drive's ceiling, so
     * each stream runs at half its single-stream speed and the decode step pays both. */
    int gate;
} K3TrunkIO;

static void *trunk_io_main(void *arg);

/* WHERE THE TIME IN A BIND ACTUALLY GOES.
 *
 * k3_trunk_report divides bytes_read by load_seconds, but load_seconds brackets ONLY the
 * pread loop. It therefore reports a DEVICE rate, and everything else the bind does --
 * widening bf16 tensors to fp32, resolving names, kernel page bookkeeping -- is invisible
 * to it while still being paid on every layer of every token. That residual is large
 * enough to change conclusions drawn from the device rate alone.
 *
 * These three counters close the gap by measurement rather than estimate: wall clock
 * around the whole of k3_trunk_bind, of which the widen loop is tracked separately, so
 * bind_wall - load_seconds - widen_wall is the remaining unattributed time. */
double k3_trunk_bind_wall = 0.0;    /* total wall inside k3_trunk_bind   */
double k3_trunk_widen_wall = 0.0;   /* of which, inside k3_bind_layer_mem */
long   k3_trunk_binds = 0;

static double now_s(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static int dt_of(const char *s)
{
    if (!strcmp(s, "BF16")) return K3_DT_BF16;
    if (!strcmp(s, "F32"))  return K3_DT_F32;
    if (!strcmp(s, "U8"))   return K3_DT_U8;
    if (!strcmp(s, "F16"))  return K3_DT_F16;
    if (!strcmp(s, "I8R"))  return K3_DT_I8R;
    if (!strcmp(s, "MXFP8_E8M7")) return K3_DT_MXFP8_E8M7;
    if (!strcmp(s, "MXFP8_E8M7_128")) return K3_DT_MXFP8_E8M7_128;
    return K3_DT_UNKNOWN;
}

static char *slurp(const char *p, size_t *n)
{
    FILE *f = fopen(p, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    char *b = (char *)malloc((size_t)sz + 1);
    if (!b) { fclose(f); return NULL; }
    if (fread(b, 1, (size_t)sz, f) != (size_t)sz) { free(b); fclose(f); return NULL; }
    b[sz] = 0; fclose(f);
    if (n) *n = (size_t)sz;
    return b;
}

/* Resolver handed to k3_bind_layer_mem: linear over one layer's ~28 tensors, which is
 * nothing next to a 1.27 GB read. */
typedef struct { const K3TrunkLayer *L; } Finder;

static int find_in_layer(void *ctx, const char *name,
                         int64_t *off, int64_t *nbytes, int *dtype, int *e,
                         int64_t *rows, int64_t *cols)
{
    const K3TrunkLayer *L = ((Finder *)ctx)->L;
    for (int i = 0; i < L->nt; i++)
        if (!strcmp(L->t[i].name, name)) {
            *off = L->t[i].off; *nbytes = L->t[i].nbytes; *dtype = L->t[i].dtype;
            if (e)    *e    = L->t[i].e;
            if (rows) *rows = L->t[i].shape[0];
            if (cols) *cols = L->t[i].shape[1];
            return 0;
        }
    return -1;
}

int64_t k3_trunk_packed_bytes(const char *dir)
{
    char p[1024];
    snprintf(p, sizeof p, "%s/trunk.json", dir);
    size_t jn = 0;
    char *txt = slurp(p, &jn);
    if (!txt) {
        snprintf(p, sizeof p, "%s/trunk_layers.json", dir);
        jn = 0;
        txt = slurp(p, &jn);
    }
    if (!txt) return 0;
    char *arena = NULL;
    jval *root = json_parse(txt, &arena);
    if (!root) { free(txt); return 0; }
    jval *jl = json_get(root, "layers");
    if (!jl || jl->t != J_ARR) { free(txt); free(arena); return 0; }
    int64_t total = 0;
    for (int i = 0; i < jl->len; i++) {
        jval *v = json_get(jl->kids[i], "nbytes");
        if (v && v->t == J_NUM) total += (int64_t)v->num;
    }
    free(txt);
    free(arena);
    return total;
}

int k3_trunk_open(K3Trunk *tr, const char *dir, const K3Cfg *c, int64_t budget_bytes,
                  int ring_want)
{
    memset(tr, 0, sizeof *tr);
    /* memset leaves fd == 0, which is stdin. Every failure path below returns without
     * opening the file, and a caller that then calls k3_trunk_close would close the
     * process's stdin. -1 is the only safe "no file" value. */
    tr->fd = -1;

    char p[1024];
    snprintf(p, sizeof p, "%s/trunk.json", dir);
    size_t jn = 0;
    char *txt = slurp(p, &jn);
    if (!txt) {
        /* Sliced layout names its manifest trunk_layers.json; accept it too. */
        snprintf(p, sizeof p, "%s/trunk_layers.json", dir);
        jn = 0;
        txt = slurp(p, &jn);
    }
    if (!txt) { fprintf(stderr, "k3_trunk: cannot read %s\n", p); return -1; }
    /* The parser arena backs every K3TrunkTensor.name, so it must outlive the whole
     * K3Trunk. It is owned by the struct and freed in k3_trunk_close. */
    char *arena = NULL;
    jval *root = json_parse(txt, &arena);
    tr->json_arena = arena;
    if (!root) { fprintf(stderr, "k3_trunk: %s is not valid JSON\n", p); free(txt); return -1; }

    jval *jl = json_get(root, "layers");
    if (!jl || jl->t != J_ARR) { fprintf(stderr, "k3_trunk: no layers array\n"); goto bad; }
    tr->n_layers = jl->len;
    tr->lay = (K3TrunkLayer *)calloc((size_t)tr->n_layers, sizeof(K3TrunkLayer));
    if (!tr->lay) goto bad;

    for (int i = 0; i < jl->len; i++) {
        jval *e = jl->kids[i];
        jval *v;
        K3TrunkLayer *L = &tr->lay[i];
        if ((v = json_get(e, "file_off")) && v->t == J_NUM) L->file_off = (int64_t)v->num;
        if ((v = json_get(e, "nbytes"))   && v->t == J_NUM) L->nbytes   = (int64_t)v->num;
        jval *ts = json_get(e, "tensors");
        if (!ts || ts->t != J_OBJ) { fprintf(stderr, "k3_trunk: layer %d has no tensors\n", i); goto bad; }
        L->nt = ts->len;
        L->t = (K3TrunkTensor *)calloc((size_t)L->nt, sizeof(K3TrunkTensor));
        if (!L->t) goto bad;
        for (int k = 0; k < ts->len; k++) {
            K3TrunkTensor *t = &L->t[k];
            /* keys live in the parser arena, which is kept for the process lifetime */
            t->name = ts->keys[k];
            jval *o = ts->kids[k];
            if ((v = json_get(o, "off"))    && v->t == J_NUM) t->off    = (int64_t)v->num;
            if ((v = json_get(o, "nbytes")) && v->t == J_NUM) t->nbytes = (int64_t)v->num;
            if ((v = json_get(o, "dtype"))  && v->t == J_STR) t->dtype  = dt_of(v->str);
            if ((v = json_get(o, "e"))      && v->t == J_NUM) t->e      = (int)v->num;
            if ((v = json_get(o, "ngrp"))  && v->t == J_NUM) t->ngrp   = (int)v->num;
            if ((v = json_get(o, "shape")) && v->t == J_ARR && v->len >= 1)
                for (int s = 0; s < v->len && s < 2; s++)
                    if (v->kids[s]->t == J_NUM) t->shape[s] = (int64_t)v->kids[s]->num;
        }
    }
    free(txt);                      /* arena holds the strings; txt itself is done */

    snprintf(p, sizeof p, "%s/trunk.bin", dir);
    /* Sliced mode first: if the trunk directory holds per-layer slices (layer_%03d.bin)
     * rather than one packed trunk.bin, open one fd per layer at offset 0. This is how
     * the board-frozen layout stores the trunk, and it lets the engine read it without
     * rebuilding the 56 GB packed file. Detection: try trunk.bin; only fall through to
     * slices when it is absent. */
    tr->direct = 1;
    tr->fd = open(p, O_RDONLY | O_DIRECT);
    if (tr->fd >= 0 && k3_set_direct(tr->fd) != 0)
        tr->direct = 0;   /* Darwin refused F_NOCACHE: reads stay buffered but correct */
    if (tr->fd < 0) {
        tr->direct = 0;
        tr->fd = open(p, O_RDONLY);
    }
    if (tr->fd < 0) {
        /* Packed trunk.bin absent: per-layer slices. layer_fd[L] is opened lazily in
         * load_run so a partial slice set only costs the layers actually bound. */
        tr->layer_fd = (int *)malloc((size_t)tr->n_layers * sizeof(int));
        if (!tr->layer_fd) goto bad;
        for (int i = 0; i < tr->n_layers; i++) tr->layer_fd[i] = -1;
        tr->slice_dir = strdup(dir);
        if (!tr->slice_dir) goto bad;
        printf("k3_trunk: trunk.bin absent - using per-layer slices (layer_%%03d.bin)\n");
    } else {
        tr->layer_fd = NULL;
        tr->slice_dir = NULL;
    }
    {
        jval *a = json_get(root, "align");
        const int64_t want = (a && a->t == J_NUM) ? (int64_t)a->num : 0;
        if (tr->direct && want != K3_TRUNK_ALIGN) {
            /* A trunk packed before the alignment change cannot be read with O_DIRECT:
             * its run offsets are arbitrary. Say so rather than fail every read. */
            fprintf(stderr, "k3_trunk: trunk.json reports align %lld, expected %d; "
                            "falling back to buffered reads (repack to enable O_DIRECT)\n",
                    (long long)want, K3_TRUNK_ALIGN);
            close(tr->fd);
            tr->direct = 0;
            tr->fd = open(p, O_RDONLY);
            if (tr->fd < 0) return -1;
        }
    }

    /* The widen area must hold every MXFP8 matmul tensor of one layer as
     * [scale][codes], so size the slot-wide budget from the layer that needs most.
     * The base is the bf16 vector widen; the mxfp8 part is the sum over the layer's
     * quantised matmul tensors (a compile-time shape is not available here, so read the
     * actual per-layer nbytes from the parsed manifest). No layer binds more than once
     * against the same slot, so max over layers is exact. */
    const size_t base_widen = k3_bind_widen_bytes(c);
    int64_t mxmax = 0;
    for (int i = 0; i < tr->n_layers; i++) {
        int64_t mxs = 0;
        for (int k = 0; k < tr->lay[i].nt; k++)
            if (tr->lay[i].t[k].dtype == K3_DT_MXFP8_E8M7 ||
                tr->lay[i].t[k].dtype == K3_DT_MXFP8_E8M7_128)
                mxs += tr->lay[i].t[k].nbytes;
        if (mxs > mxmax) mxmax = mxs;
    }
    /* mxfp8 tensors are bound as [scale][codes] in the widen area, NOT pointed at the
     * run (slot lifetime is a hazard), so the slot's widen budget must carry a full
     * layer of codes. Add the worst layer, plus scale headers for its matmuls. */
    const size_t widen = base_widen + (size_t)mxmax + 4u * 8u;

    int64_t total = 0;
    for (int i = 0; i < tr->n_layers; i++) total += tr->lay[i].nbytes;

    /* Pin a PREFIX of layers, each in an exact-size allocation, then keep a small ring
     * of uniform slots for everything else. Uniform slots everywhere would size every
     * slot for layer 0 (2.34 GB, the dense MLP) and waste roughly half the budget. */
    tr->slot_of = (int32_t *)malloc((size_t)tr->n_layers * sizeof(int32_t));
    if (!tr->slot_of) return -1;
    for (int i = 0; i < tr->n_layers; i++) tr->slot_of[i] = -1;
    tr->reads_by_layer = (uint64_t *)calloc((size_t)tr->n_layers, sizeof(uint64_t));
    if (!tr->reads_by_layer) return -1;

    /* Two ring slots: the layer being computed on, plus one asynchronous read in flight.
     *
     * This is a REQUEST, not a guarantee. The second slot costs a full slot's worth of
     * memory, which at the floor is 2.37 GB, and the budget the caller asked for has to
     * come first: measured on the released checkpoint, taking the second slot
     * unconditionally moved the laptop preset from 8.78 GB to 11.12 GB peak RSS, a 27%
     * overshoot of a 3.0 GB trunk budget, and left the printed memory plan understating
     * the real figure. So it is granted only when it fits, and reported when it does not.
     * A single slot is exactly what this file did before the asynchronous reader existed,
     * so falling back is always safe; it costs speed, not correctness. */
    const int RING_WANT = ring_want > 0 ? ring_want : 2;
    int RING = RING_WANT;

    /* Size the ring from the layers that will actually STREAM through it.
     *
     * Pinning is a PREFIX: layers 0..npin-1 are held resident and never touch the ring,
     * so only npin..n_layers-1 ever occupy a slot. Sizing the slot from the maximum over
     * ALL layers therefore reserves room for layer 0 -- which at 2.34 GB is the largest
     * in the model, being the only dense one with a 33792-wide MLP, and which prefix
     * pinning pins FIRST whenever anything is pinned at all. That wasted about 1.17 GB
     * for nothing at every budget above the floor.
     *
     * Ring size and pin count are mutually dependent: a smaller ring frees budget, which
     * pins more layers, which can shrink the ring again. Iterate to a fixed point. It
     * converges in two or three passes and is monotone, so the loop is bounded. At the
     * floor, where npin is 0, this correctly changes nothing: every layer streams and the
     * ring must still hold the biggest of them. */
    int64_t ring_slot = 0, spent = 0;
    int npin = 0;
    /* Layer 0 is 2.34 GB, three to four times any other layer. If it streams, every
     * ring slot must be sized for it, so an 8 GB budget fits only two fat slots and the
     * ring cannot hold enough layers to reuse them across tokens. Pinning layer 0 (it is
     * read once anyway) shrinks the ring slot to the other layers' ~646 MB and buys the
     * multi-slot ring the user asks for. Do that whenever layer 0 plus at least one
     * compact slot fits the budget; otherwise keep the old behavior and the fat slot. */
    const int64_t l0_need = tr->lay[0].nbytes + (int64_t)widen;
    int64_t compact = 0;
    for (int i = 1; i < tr->n_layers; i++)
        if (tr->lay[i].nbytes > compact) compact = tr->lay[i].nbytes;
    if (compact == 0) compact = tr->lay[0].nbytes;
    compact = (compact + K3_TRUNK_ALIGN - 1) & ~(int64_t)(K3_TRUNK_ALIGN - 1);
    compact += (int64_t)widen;
    const int force_l0 = (l0_need + compact <= budget_bytes) ? 1 : 0;

    /* Ring size and pin count are mutually dependent: a smaller ring frees budget, which
     * pins more layers, which can shrink the ring again. The passes start npin high
     * enough that the ring slots are sized from the compact (post-layer-0) layers, then
     * iterate to a fixed point. */
    for (int pass = 0; pass < 4; pass++) {
        int64_t big = 0;
        const int lo = npin ? npin : (force_l0 ? 1 : 0);
        for (int i = lo; i < tr->n_layers; i++)
            if (tr->lay[i].nbytes > big) big = tr->lay[i].nbytes;
        if (big == 0) big = tr->lay[tr->n_layers - 1].nbytes;   /* all pinned */
        int64_t rs = (big + K3_TRUNK_ALIGN - 1) & ~(int64_t)(K3_TRUNK_ALIGN - 1);
        rs += (int64_t)widen;
        rs = (rs + 4095) & ~(int64_t)4095;

        RING = RING_WANT;
        while (RING > 1 && (int64_t)RING * rs + (force_l0 ? l0_need : 0) > budget_bytes) RING--;

        int64_t sp = (int64_t)RING * rs + (force_l0 ? l0_need : 0);
        int np = force_l0 ? 1 : 0;
        while (np < tr->n_layers) {
            const int64_t need = tr->lay[np].nbytes + (int64_t)widen;
            if (sp + need > budget_bytes) break;
            sp += need;
            np++;
        }
        if (np >= tr->n_layers) np = tr->n_layers;
        if (rs == ring_slot && np == npin) { ring_slot = rs; spent = sp; break; }
        ring_slot = rs; npin = np; spent = sp;
    }

    tr->npin = npin;
    tr->nslot = RING;
    tr->slot_bytes = ring_slot;

    tr->pin = (unsigned char **)calloc((size_t)(npin ? npin : 1), sizeof(unsigned char *));
    if (!tr->pin) return -1;
    for (int i = 0; i < npin; i++) {
        const size_t need = (size_t)((tr->lay[i].nbytes + K3_TRUNK_ALIGN - 1)
                                     & ~(int64_t)(K3_TRUNK_ALIGN - 1)) + widen;
        if (k3_alloc_direct((void **)&tr->pin[i], need) != 0) {
            fprintf(stderr, "k3_trunk: cannot allocate %.2f GB for pinned layer %d\n",
                    (double)need / 1e9, i);
            return -1;
        }
    }
    if (k3_alloc_direct((void **)&tr->arena, (size_t)RING * (size_t)ring_slot) != 0) {
        fprintf(stderr, "k3_trunk: cannot allocate the %.2f GB streaming ring\n",
                (double)RING * ring_slot / 1e9);
        return -1;
    }
    tr->layer_of = (int *)malloc((size_t)RING * sizeof(int));
    for (int i = 0; i < RING; i++) tr->layer_of[i] = -1;
    tr->widen_bytes = (int64_t)widen;

    /* The reader is started ONLY when there are at least two slots, and this is a
     * correctness requirement rather than an optimisation.
     *
     * k3_trunk_prefetch claims tr->ring for the incoming layer. With one slot, tr->ring
     * is necessarily the slot k3_trunk_bind just returned to the caller, so the worker
     * preads layer L+1 straight over layer L's bytes while the caller is still computing
     * on them. Nothing detects it: the read succeeds, no bound pointer changes, and the
     * run completes and emits fluent, wrong tokens.
     *
     * Measured on the released checkpoint. With one slot and the reader running, the same
     * prompt that gives 17374 20829 10 427 414 1008 606 142957 instead produced
     * 32609 2329 146429 2539 11 152834 44449 7569, with no diagnostic of any kind.
     *
     * With io_state NULL, trunk_io_wait returns 0 and k3_trunk_prefetch returns
     * immediately, which is exactly the synchronous path this file had before the reader
     * existed. */
    if (RING >= 2) {
        K3TrunkIO *io = (K3TrunkIO *)calloc(1, sizeof *io);
        if (!io) return -1;
        io->tr = tr;
        io->pending = -1;   /* calloc leaves 0, which is a VALID layer; -1 is "none" */
        pthread_mutex_init(&io->mu, NULL);
        pthread_cond_init(&io->cv, NULL);
        tr->io_state = io;
        if (pthread_create(&io->thread, NULL, trunk_io_main, io) != 0) {
            fprintf(stderr, "k3_trunk: cannot start asynchronous reader\n");
            pthread_cond_destroy(&io->cv);
            pthread_mutex_destroy(&io->mu);
            free(io);
            tr->io_state = NULL;
            return -1;
        }
    } else {
        tr->io_state = NULL;
    }

    printf("trunk stream: %.2f GB packed, %d/%d layers PINNED (%.2f GB), "
           "ring %d x %.2f GB\n",
           (double)total / 1e9, npin, tr->n_layers,
           (double)(spent - (int64_t)RING * ring_slot) / 1e9,
           RING, (double)ring_slot / 1e9);
    printf("              reads use %s\n",
           tr->direct ? "O_DIRECT (page cache bypassed)" : "buffered I/O");
    if (RING < RING_WANT)
        printf("              ring held at %d slot: %d slots need %.2f GB and the "
               "trunk budget is %.2f GB,\n"
               "              so reads are NOT overlapped with compute. Raise --trunk-gb "
               "above %.2f GB to enable it.\n",
               RING, RING_WANT, (double)RING_WANT * ring_slot / 1e9,
               (double)budget_bytes / 1e9,
               (double)RING_WANT * ring_slot / 1e9);
    if (RING == 1)
        printf("              deterministic hit rate %.1f%% (a cyclic scan defeats LRU, so "
               "a pinned prefix is used instead)\n", 100.0 * npin / tr->n_layers);
    else
printf("              ring holds %d slots: layers repeat over ~%d tokens, so "
           "recent ones are reused instead of re-read\n", RING, RING);
    k3_bind_time_reset();
    return 0;
bad:
    free(txt);
    free(tr->layer_fd);
    free(tr->slice_dir);
    return -1;
}

void k3_trunk_close(K3Trunk *tr)
{
    K3TrunkIO *io = (K3TrunkIO *)tr->io_state;
    if (io) {
        pthread_mutex_lock(&io->mu);
        io->stop = 1;
        pthread_cond_signal(&io->cv);
        pthread_mutex_unlock(&io->mu);
        pthread_join(io->thread, NULL);
        pthread_cond_destroy(&io->cv);
        pthread_mutex_destroy(&io->mu);
        free(io);
    }
    if (tr->fd >= 0) close(tr->fd);
    if (tr->layer_fd) {
        for (int i = 0; i < tr->n_layers; i++)
            if (tr->layer_fd[i] >= 0) close(tr->layer_fd[i]);
        free(tr->layer_fd);
    }
    free(tr->slice_dir);
    if (tr->pin) { for (int i = 0; i < tr->npin; i++) free(tr->pin[i]); free(tr->pin); }
    free(tr->arena); free(tr->layer_of); free(tr->slot_of);
    free(tr->reads_by_layer);
    if (tr->lay) { for (int i = 0; i < tr->n_layers; i++) free(tr->lay[i].t); free(tr->lay); }
    free(tr->json_arena);   /* every K3TrunkTensor.name points into this */
    memset(tr, 0, sizeof *tr);
    tr->fd = -1;            /* see k3_trunk_open: 0 is stdin, not "closed" */
}

/* Read one layer's run into dst. */

/* Allocate an O_DIRECT target on a 2 MB boundary and ask for transparent hugepages.
 *
 * WHY THIS IS NOT COSMETIC. Every O_DIRECT read must pin its destination pages in the
 * kernel (get_user_pages) for the duration of the transfer. A 2.37 GB ring slot backed by
 * 4 KB pages is 578,000 pages pinned and released PER READ, and the trunk is read 93
 * times per token: about 53.8 million pin operations, at a few hundred nanoseconds each.
 * That is on the order of ten seconds per token spent in the kernel doing page
 * bookkeeping, none of which appears in the engine's own I/O timer -- which brackets only
 * the pread loop and therefore reports a device rate that looks like the disk is
 * saturated while a third of the token is unaccounted for.
 *
 * Backing the same buffer with 2 MB pages cuts the count by 512x. The allocation is
 * otherwise identical, so this is lossless and cannot change a single output bit.
 *
 * K3_NOHUGE=1 restores 4 KB alignment so the two can be A/B compared on ONE binary,
 * which is the only way to attribute a timing difference to this decision rather than to
 * the compiler or the weather. */
static int k3_alloc_direct(void **out, size_t bytes)
{
    const int huge = !getenv("K3_NOHUGE");
    const size_t align = huge ? (2u << 20) : 4096u;
    /* Round the LENGTH up too: madvise only covers whole pages, so a 2 MB-aligned start
     * with a ragged tail leaves the last stretch on 4 KB pages. */
    const size_t len = huge ? ((bytes + align - 1) & ~(align - 1)) : bytes;
    if (posix_memalign(out, align, len) != 0) return -1;
#if defined(MADV_HUGEPAGE)
    if (huge) madvise(*out, len, MADV_HUGEPAGE);   /* advisory: failure is not an error */
#endif
    return 0;
}

static int load_run(K3Trunk *tr, int L, unsigned char *dst)
{
    const K3TrunkLayer *lay = &tr->lay[L];
    const double t0 = now_s();
    int64_t got = 0;
    int fd = tr->fd;
    off_t off = (off_t)lay->file_off;
    K3TrunkIO *io = (K3TrunkIO *)tr->io_state;
    if (tr->layer_fd) {
        /* Sliced mode: one file per layer, read from offset 0. Open lazily now. */
        if (tr->layer_fd[L] < 0) {
            char p[1024];
            snprintf(p, sizeof p, "%s/layer_%03d.bin", tr->slice_dir, L);
            tr->layer_fd[L] = open(p, O_RDONLY | O_DIRECT);
            if (tr->layer_fd[L] < 0) tr->layer_fd[L] = open(p, O_RDONLY);
            if (tr->layer_fd[L] < 0) {
                fprintf(stderr, "k3_trunk: cannot open slice %s\n", p);
                return -1;
            }
        }
        fd = tr->layer_fd[L];
        off = 0;
    }
    while (got < lay->nbytes) {
        /* Gate check: while the expert cache's phase-2 burst owns the drive, hold off.
         * Read in ~8 MB chunks so this breaks out within a few IO ops instead of after
         * one whole 600 MB layer. Without this, trunk stream (~995 MB/s) and expert
         * scattered reads (~640 MB/s) run simultaneously and share the ~1.6 GB/s the
         * drive can actually do: each gets ~0.5x of its single-stream rate, and decode
         * expert reads take 40 s instead of 14 s. */
        if (io && !tr->kio) {
            pthread_mutex_lock(&io->mu);
            const double w0 = now_s();
            while (io->gate && !io->stop) pthread_cond_wait(&io->cv, &io->mu);
            tr->wait_seconds += now_s() - w0;
            const int stop = io->stop;
            pthread_mutex_unlock(&io->mu);
            if (stop) break;
        }
        const int64_t rem = lay->nbytes - got;
        size_t want = (size_t)(rem < (int64_t)TRUNK_READ_CHUNK ? rem : (int64_t)TRUNK_READ_CHUNK);
        ssize_t r;
        if (tr->kio) {
            /* Unified scheduler: submit the WHOLE remaining layer as ONE chunked
             * request in at most two huge preads; the worker completes once --
             * no submit/wait round-trip per 32 MB chunk. */
            K3IOReq *q = k3_io_submit(tr->kio, 0, fd, off + got, (size_t)rem,
                                      (size_t)((1u << 31) - 4096), dst + got);
            /* Largest single O_DIRECT pread the kernel accepts (2 GB - 4k). The
             * layer is read in at most two chunks; bench: 2010 MB/s vs 687 MB/s
             * for 256 MB chunks, vs ~60 MB/s for the old 32 MB chunks under the
             * engine. Fewer, bigger reads dominate. */
            if (!q) return -1;
            r = k3_io_wait(q);
            if (getenv("K3_IO_DBG"))
                fprintf(stderr, "DBG trunk load_run L=%d kio r=%ld got=%ld nbytes=%lld\n",
                        L, (long)r, (long)got, (long long)lay->nbytes);
            got += r;   /* worker read the whole span in chunks */
        } else {
            r = pread(fd, dst + got, want, off + got);
            got += r;
        }
        if (r <= 0) { fprintf(stderr, "k3_trunk: short read on layer %d\n", L); return -1; }
    }
    tr->load_seconds += now_s() - t0;
    tr->bytes_read += (uint64_t)got;
    tr->reads_by_layer[L]++;
    return 0;
}

static void *trunk_io_main(void *arg)
{
    K3TrunkIO *io = (K3TrunkIO *)arg;
    for (;;) {
        pthread_mutex_lock(&io->mu);
        /* Wait for a request and for the previous completion to be acknowledged:
         * io->done stays 1 until trunk_io_wait claims it (publishing the layer into
         * its slot); the slot must not be re-read while its bytes are live. The
         * binder claims the completion AND starts the next pending read, so io->layer
         * is only ever changed by trunk_io_wait -- never by this thread -- which
         * keeps the (busy||done) && io->layer == L match in the binder stable. */
        while ((!io->busy || io->done) && !io->stop)
            pthread_cond_wait(&io->cv, &io->mu);
        if (io->stop) {
            pthread_mutex_unlock(&io->mu);
            return NULL;
        }
        const int L = io->layer;
        const int slot = io->slot;
        K3Trunk *tr = io->tr;
        pthread_mutex_unlock(&io->mu);

        const int rc = load_run(tr, L, tr->arena + (size_t)slot * tr->slot_bytes);

        pthread_mutex_lock(&io->mu);
        io->result = rc;
        io->done = 1;
        io->busy = 0;
        pthread_cond_broadcast(&io->cv);
        pthread_mutex_unlock(&io->mu);
    }
}

/* L is done computing. Free its slot for reuse without any need to evict a live one.
 * The slot may be in any of three states: pinned-only (nothing to do), resident from a
 * bind, or owned by the async reader mid-read (its layer is L+1 or later, never L,
 * because compute(L) finished before this call, so L's bytes are stable). Only a
 * resident-not-in-flight slot is released here. */
void k3_trunk_release(K3Trunk *tr, int L)
{
    if (L < 0 || L >= tr->n_layers || L < tr->npin) return;
    K3TrunkIO *io = (K3TrunkIO *)tr->io_state;
    pthread_mutex_lock(&io->mu);
    if (io->busy && io->layer == L) {
        /* cannot happen (see above); leave it alone rather than race the reader */
        pthread_mutex_unlock(&io->mu);
        return;
    }
    if (tr->slot_of[L] >= 0) {
        const int s = tr->slot_of[L];
        if (tr->layer_of[s] == L) {
            tr->layer_of[s] = -1;
        }
        tr->slot_of[L] = -1;
    }
    pthread_mutex_unlock(&io->mu);
}

void k3_trunk_expert_hold(K3Trunk *tr, int hold)
{
    K3TrunkIO *io = (K3TrunkIO *)tr->io_state;
    if (!io) return;
    pthread_mutex_lock(&io->mu);
    io->gate = hold ? 1 : 0;
    if (!hold) pthread_cond_broadcast(&io->cv);
    pthread_mutex_unlock(&io->mu);
}

static int trunk_io_wait(K3Trunk *tr, int L)
{
    K3TrunkIO *io = (K3TrunkIO *)tr->io_state;
    if (!io) return 0;
    pthread_mutex_lock(&io->mu);
    /* Match the reader's current layer. The pending field (a hint received while the
     * reader was busy) is NOT matched here: the binder's own prefetch call re-issues
     * the newest request once the reader is free, so waiting on a not-yet-started
     * pending read would hang on the wrong completion. */
    if ((io->busy || io->done) && io->layer == L) {
        while (!io->done && !io->stop)
            pthread_cond_wait(&io->cv, &io->mu);
        const int rc = io->result;
        const int slot = io->slot;
        if (!io->stop && rc == 0) {
            tr->layer_of[slot] = L;
            tr->slot_of[L] = slot;
            tr->misses++;
        }
        io->done = 0;
        pthread_mutex_unlock(&io->mu);
        return rc == 0 ? 1 : -1;
    }
    pthread_mutex_unlock(&io->mu);
    return 0;
}

int k3_trunk_bind(K3Trunk *tr, const K3Cfg *c, int L, K3LayerBind *b)
{
    if (L < 0 || L >= tr->n_layers) return -1;
    const double t_bind0 = now_s();
    k3_trunk_binds++;
    unsigned char *base;

    if (L < tr->npin) {
        base = tr->pin[L];
        if (tr->slot_of[L] < 0) {            /* first touch: load once, keep forever */
            if (load_run(tr, L, base) != 0) return -1;
            tr->slot_of[L] = L;
            tr->misses++;
        } else {
            tr->hits++;
        }
    } else {
        int slot = -1;
        const int prefetched = trunk_io_wait(tr, L);
        if (prefetched < 0) return -1;
        if (prefetched > 0) {
            slot = tr->slot_of[L];
        } else {
            for (int i = 0; i < tr->nslot; i++)
                if (tr->layer_of[i] == L) { slot = i; break; }
            if (slot >= 0) {
                tr->hits++;
            } else {
                slot = tr->ring;
                tr->ring = (tr->ring + 1) % tr->nslot;
                if (tr->layer_of[slot] >= 0) tr->slot_of[tr->layer_of[slot]] = -1;
                /* Mark the slot EMPTY before reading into it, not after. */
                tr->layer_of[slot] = -1;
                if (load_run(tr, L, tr->arena + (size_t)slot * tr->slot_bytes) != 0) return -1;
                tr->layer_of[slot] = L;
                tr->misses++;
            }
        }
        base = tr->arena + (size_t)slot * tr->slot_bytes;
    }

    Finder f; f.L = &tr->lay[L];
    K3MemSrc src; src.find = find_in_layer; src.ctx = &f;
    unsigned char *widen = base + (((tr->lay[L].nbytes + K3_TRUNK_ALIGN - 1)
                                    & ~(int64_t)(K3_TRUNK_ALIGN - 1)));
    /* Pinned layers own exactly nbytes + widen; ring slots own slot_bytes. */
    const size_t cap = (size_t)tr->widen_bytes;
    const double tw = now_s();
    const int rc = k3_bind_layer_mem(c, L, b, base, &src, widen, cap, NULL);
    const double tnow = now_s();
    k3_trunk_widen_wall += tnow - tw;
    k3_trunk_bind_wall  += tnow - t_bind0;
    return rc;
}

void k3_trunk_prefetch(K3Trunk *tr, int L)
{
    if (L < 0 || L >= tr->n_layers || L < tr->npin) return;
    for (int i = 0; i < tr->nslot; i++) if (tr->layer_of[i] == L) return;

    K3TrunkIO *io = (K3TrunkIO *)tr->io_state;
    if (!io) return;
    pthread_mutex_lock(&io->mu);
    /* Reader busy (mid-read, possibly parked on the expert gate): do NOT drop the
     * request. Remember the newest layer wanted; the reader's completion broadcast
     * wakes the binder, and the next prefetch call (or this one, if it re-enters
     * after busy clears) issues it. Without this, a gate-parked reader makes every
     * later hint vanish and the following binds fall back to trunk_io_wait, which
     * then waits on the very same gate and stalls the main thread for the whole
     * expert burst. */
    if (io->busy) {
        if (io->pending < 0 || L > io->pending) io->pending = L;
        pthread_mutex_unlock(&io->mu);
        return;
    }
    if (tr->slot_of[L] >= 0) {
        pthread_mutex_unlock(&io->mu);
        return;
    }
    /* Use ONLY a slot that is already free. Evicting a slot whose layer is mid-compute
     * would corrupt the direct-referenced weights that layer is reading; the previous
     * rotating-head eviction was masked by copying bytes into the widen area on bind,
     * which is gone now. When every slot is busy the hint is simply dropped: reads then
     * revert to the synchronous path in a later bind, which is correct if slower. */
    int slot = -1;
    for (int i = 0; i < tr->nslot; i++)
        if (tr->layer_of[i] < 0 && i != io->slot) { slot = i; break; }
    if (slot < 0) {
        pthread_mutex_unlock(&io->mu);
        return;
    }
    tr->layer_of[slot] = -1;
    io->layer = L;
    io->slot = slot;
    io->done = 0;
    io->busy = 1;
    pthread_cond_signal(&io->cv);
    pthread_mutex_unlock(&io->mu);
}

void k3_trunk_report(const K3Trunk *tr, const char *label)
{
    const uint64_t n = tr->hits + tr->misses;
    printf("trunk [%s]\n", label ? label : "");
    printf("  pinned %d/%d layers, ring %d slots\n", tr->npin, tr->n_layers, tr->nslot);
    printf("  binds %llu, hits %llu (%.1f%%), reads %llu\n",
           (unsigned long long)n, (unsigned long long)tr->hits,
           n ? 100.0 * tr->hits / n : 0.0, (unsigned long long)tr->misses);
    /* DEVICE rate, excluding the expert-gate park: load_seconds brackets the pread
     * loop AND the condvar waits that yield the drive to the expert burst, so
     * bytes/load_seconds understates the device. wait_seconds is the parked share;
     * the rate below is bytes over (load - wait), the true pread rate. */
    {
        const double rd = tr->load_seconds - tr->wait_seconds;
        const double rate = rd > 0 ? (double)tr->bytes_read / 1e6 / rd : 0.0;
        printf("  read %.2f GB in %.2f s (%.0f MB/s pread)",
               (double)tr->bytes_read / 1e9, rd, rate);
        if (tr->wait_seconds > 0.0)
            printf(" + %.2f s parked on the expert gate", tr->wait_seconds);
        printf("\n");
    }
    if (tr->reads_by_layer) {
        printf("  per-layer loads [L]=count: ");
        for (int i = 0; i < tr->n_layers; i++)
            printf("%s%d=%llu", i ? " " : "", i,
                   (unsigned long long)tr->reads_by_layer[i]);
        printf("\n");
    }
    /* The rate above is a DEVICE rate: load_seconds brackets the pread loop alone (the
     * expert-gate park is split out above). The breakdown below is the wall clock
     * actually spent inside k3_trunk_bind, so the difference between them is per-bind
     * overhead rather than disk time.
     *
     * Reporting the widen step separately is what distinguishes a slow device from
     * excessive work per bind, two causes with the same symptom and different fixes. */
    {
        /* load_seconds is DEVICE time and, with more than one ring slot, some of it
         * happens on the reader thread while the main thread is computing. Subtracting it
         * from bind wall clock then goes negative by exactly the amount of overlap
         * achieved, which is how the previous form of this line reported the feature
         * working as "other -157.06" and a read share of 207%. Overlapped time is a
         * result, not unattributed overhead, so it is named rather than subtracted. The
         * gate park (wait_seconds) is voluntary yielding, not device work, so it is
         * excluded from the device-work ledger. */
        const double rd = tr->load_seconds - tr->wait_seconds;
        const double serial = rd + k3_trunk_widen_wall;
        const double overlapped = serial - k3_trunk_bind_wall;
        if (overlapped > 0.0) {
            printf("  bind wall %.2f s over %ld binds; read %.2f + widen %.2f = %.2f s of "
                   "device work,\n"
                   "                    of which %.2f s (%.0f%%) overlapped compute on the "
                   "reader thread\n",
                   k3_trunk_bind_wall, k3_trunk_binds, rd,
                   k3_trunk_widen_wall, serial, overlapped,
                   serial > 0.0 ? 100.0 * overlapped / serial : 0.0);
        } else {
            const double other = k3_trunk_bind_wall - serial;
            printf("  bind wall %.2f s over %ld binds  =  read %.2f + widen %.2f + other %.2f\n",
                   k3_trunk_bind_wall, k3_trunk_binds, rd,
                   k3_trunk_widen_wall, other);
            if (k3_trunk_bind_wall > 0.0)
                printf("                    shares:      read %.0f%%  widen %.0f%%  other %.0f%%\n",
                       100.0 * rd / k3_trunk_bind_wall,
                       100.0 * k3_trunk_widen_wall / k3_trunk_bind_wall,
                       100.0 * other / k3_trunk_bind_wall);
        }
        /* What the widen second-half actually did, timed inside k3_bind_layer_mem. The
         * three components add up to less than widen_wall: the gap is plan_layer (name
         * sprintf + shape checks), which runs before the find calls and is not timed. */
        {
            K3BindTime bt;
            k3_bind_time_get(&bt);
            const double tot = bt.find_us + bt.copy_us + bt.deq_us;
            printf("  widen breakdown: find %.0f ms (%ld)  copy %.0f ms (%ld)  "
                   "deq %.0f ms (%ld)  timed %.0f s of widen %.2f s\n",
                   bt.find_us / 1e3, bt.find_calls, bt.copy_us / 1e3, bt.copy_calls,
                   bt.deq_us / 1e3, bt.deq_calls, tot / 1e6, k3_trunk_widen_wall);
        }
    }
}
