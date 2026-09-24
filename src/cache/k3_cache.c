/* k3_cache.c - see k3_cache.h. */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <sys/mman.h>
#ifdef _OPENMP
#include <omp.h>
#endif

#include "k3_portable_io.h"
#include "k3_cache.h"
#include "k3_l2cache.h"

static double now_s(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* Resolve a slot to the three (packed, scale) pairs the kernels want. */
static void fill_q(const K3Cache *c, int slot, K3ExpertQ *q)
{
    /* pad is where the expert really begins: an O_DIRECT read starts at the enclosing
     * 4096 boundary, which is at or before the expert's own offset. */
    const unsigned char *b = c->arena + (size_t)slot * c->slot_bytes + c->pad[slot];
    const K3ExpertRef *r = &c->ref[slot];
    q->p1 = b + r->m[0].p_off; q->s1 = b + r->m[0].s_off;
    q->p2 = b + r->m[1].p_off; q->s2 = b + r->m[1].s_off;
    q->p3 = b + r->m[2].p_off; q->s3 = b + r->m[2].s_off;
}

/* Least recently used unpinned slot. Linear, deliberately: a few hundred comparisons
 * against a 17.55 MB read is not where the time goes. */
/* key_of[] has THREE states, not two:
 *     >= 0            holds that key
 *     K3_SLOT_EMPTY   holds nothing, free to take
 *     K3_SLOT_INFLIGHT reserved by a batch prefetch whose read has not finished
 *
 * The third state exists because of a real bug. The batch prefetch marks a slot empty
 * before reading into it, so that a failed read cannot leave the slot claiming an expert
 * it does not hold. But the empty test below is a FAST PATH that returns immediately,
 * ahead of the pinned check and the LRU scan -- so the next expert in the same batch was
 * handed the SAME slot, several parallel reads wrote into one buffer, and the MoE
 * multiplied garbage. It cost one wrong token (65 instead of 2494) on the real model and
 * nothing at all in the fixtures, because no fixture exercises the streaming cache. */
static int pick_victim(K3Cache *c)
{
    int best = -1, best_zero = -1;
    uint64_t oldest = (uint64_t)-1, oldest_zero = (uint64_t)-1;
    uint32_t mincnt = (uint32_t)-1;
    /* Heat must not evict an expert the caller is still computing on. LRU gets this
     * for free (a just-get() expert has the freshest used_at, so it is never the LRU
     * victim), but a bare "lowest hist" scan ignores recency and can hand out the slot
     * that k3_ops is mid-matmul on: get() returns, hist becomes 1, and if that 1 is the
     * global minimum the next getmany evicts it before the matmul finishes reading the
     * arena -- wrong tokens with no diagnostic. So heat considers a slot evictable only
     * when it was NOT touched this clock generation: used_at must be older than the
     * newest K3_MAX_TOPK slots, i.e. not one of the experts this token is using. */
    const uint64_t recency_floor = (c->clock > (uint64_t)K3_MAX_TOPK) ? (c->clock - (uint64_t)K3_MAX_TOPK) : 0;
    for (int i = 0; i < c->nslot; i++) {
        if (c->key_of[i] == K3_SLOT_INFLIGHT) continue;   /* being read into RIGHT NOW */
        if (c->key_of[i] == K3_SLOT_EMPTY) return i;      /* free, take it */
        if (c->pinned[i]) continue;
        if (c->policy == 1) {
            /* heat: among experts NOT touched this token (used_at below the recency
             * floor), evict the least-requested. Zero-count slots are batch-prefetched
             * experts whose get() has not run yet; they are only evicted when nothing
             * counted and stale exists, and then by LRU (oldest first). */
            const int32_t key = c->key_of[i];
            const uint32_t cnt = key >= 0 ? c->hist[key] : 0;
            const uint64_t ua = c->used_at[i];
            if (ua > recency_floor) continue;             /* in use right now: protected */
            if (cnt == 0) {
                if (best_zero < 0 || ua < oldest_zero) {
                    oldest_zero = ua; best_zero = i;
                }
                continue;
            }
            if (cnt < mincnt || (cnt == mincnt && ua < oldest)) {
                mincnt = cnt; oldest = ua; best = i;
            }
        } else {
            if (c->used_at[i] < oldest) { oldest = c->used_at[i]; best = i; }
        }
    }
    if (best < 0) best = best_zero;   /* only fall back to a zero-count slot if no counted one exists */
    /* Fallback two: every slot is inside the recency window (cold start or a small
     * arena). The window is K3_MAX_TOPK wide, so on an 8-slot cache the first few
     * dozen serial requests all look "in use this token" and heat would otherwise
     * return -1, refusing to evict anything and failing admit() on a cache that is
     * genuinely full. Return -1 only when every non-pinned slot is INFLIGHT. When the
     * whole arena is within the window we simply fall back to plain LRU: the window
     * protected only the most recent experts, and the cold-start consumer has no
     * accumulation to protect against. */
    if (best < 0) {
        uint64_t v = (uint64_t)-1;
        for (int i = 0; i < c->nslot; i++) {
            if (c->pinned[i] || c->key_of[i] == K3_SLOT_INFLIGHT) continue;
            if (c->used_at[i] < v) { v = c->used_at[i]; best = i; }
        }
    }
    return best;
}

/* Bring (layer, expert) resident and return its slot, or -1. Caller must hold
 * c->mu whenever the reader thread exists (c->pref_started); the async reader and the
 * main thread both publish through here and the slot bookkeeping is shared state. */
static int admit_unlocked(K3Cache *c, int layer, int expert)
{
    const int32_t key = layer * c->n_experts + expert;
    int slot = c->slot_of[key];
    if (slot >= 0) {
        c->hits++;
        c->used_at[slot] = ++c->clock;
        return slot;
    }
    c->misses++;

    K3ExpertRef r;
    if (k3_expert_ref(c->st, layer, expert, &r) != 0) return -1;
    if (r.nbytes > c->slot_bytes) {
        fprintf(stderr, "k3_cache: L%d expert %d is %lld bytes, slot holds %lld\n",
                layer, expert, (long long)r.nbytes, (long long)c->slot_bytes);
        return -1;
    }

    slot = pick_victim(c);
    if (slot < 0) {
        fprintf(stderr, "k3_cache: every slot is pinned, cannot admit L%d expert %d\n",
                layer, expert);
        return -1;
    }
    if (c->key_of[slot] >= 0) { c->slot_of[c->key_of[slot]] = -1; c->evictions++; }

    const double t0 = now_s();
    int64_t pad = 0;
    const int64_t got = k3_expert_load_direct(c->st, &r,
                            c->arena + (size_t)slot * c->slot_bytes,
                            c->slot_bytes, &pad);
    c->load_seconds += now_s() - t0;
    if (got != r.nbytes) {
        fprintf(stderr, "k3_cache: short load of L%d expert %d (%lld of %lld)\n",
                layer, expert, (long long)got, (long long)r.nbytes);
        c->key_of[slot] = -1;
        return -1;
    }
    c->bytes_read += (uint64_t)got;

    c->ref[slot] = r;
    c->pad[slot] = (int32_t)pad;
    c->key_of[slot] = key;
    c->slot_of[key] = slot;
    c->used_at[slot] = ++c->clock;
    if (c->pin_layer && c->pin_layer[layer]) c->pinned[slot] = 1;
    return slot;
}

/* Self-locking admit for the two single-call users (dead code k3_cache_prefetch and
 * nothing else at depth 0). With no reader thread pref_started is 0 and no lock is
 * taken at all, so the baseline path is unchanged. */
static int admit(K3Cache *c, int layer, int expert)
{
    const int locked = c->pref_started;
    if (locked) pthread_mutex_lock(&c->mu);
    const int slot = admit_unlocked(c, layer, expert);
    if (locked) pthread_mutex_unlock(&c->mu);
    return slot;
}

/* Bring a whole top-k resident, with the reads issued CONCURRENTLY.
 *
 * The serial path admits one expert per call, so the drive sees a queue depth of one:
 * 17.55 MB, wait, repeat, 16 times per layer. NVMe needs depth to reach rated bandwidth,
 * so that pattern leaves most of the drive idle. This hands the whole set over at once.
 *
 * THREE PHASES, and the split is not cosmetic:
 *   1 SERIAL   resolve each miss and reserve it a slot. Slot allocation touches the LRU
 *              bookkeeping, which is shared mutable state and must not race.
 *   2 PARALLEL do the reads. Every read targets a distinct, already-assigned buffer and
 *              goes through pread, which takes its offset as an argument and so does not
 *              touch any shared file position. Nothing here is shared for writing.
 *   3 SERIAL   publish. A slot is registered to its key ONLY after its read succeeded.
 *
 * Phase 3 is where the danger was. Registering the key up front, then reading, would
 * leave a failed read with a slot that claims to hold an expert it does not -- and the
 * next request for that expert would count a HIT and multiply garbage. That exact bug
 * existed in the trunk ring and is why the order here is deliberate.
 */
static int cache_getmany_inner(K3Cache *c, int layer, const int *ids, int n, int from_reader)
{
    if (n <= 0) return 0;

    typedef struct { int slot; int expert; K3ExpertRef r; int64_t got, pad; } Work;
    /* One entry per expert in a batch prefetch, so it is bounded by top-k. */
    Work w[K3_MAX_TOPK];
    int nw = 0;
    const int cap = (int)(sizeof w / sizeof *w);

    /* ---- phase 1: reserve, serially ---- */
    /* The reader and the main thread both hop on the mutex here and in phase 3;
     * pick_victim and the slot bookkeeping are shared mutable state and must not race.
     * Phase 2 (the disk reads) runs UNLOCKED so the two threads overlap on the drive.
     * With no reader thread pref_started is 0 and no lock is taken: baseline is unchanged. */
    const int locked = c->pref_started;
    if (locked) pthread_mutex_lock(&c->mu);
    for (int i = 0; i < n && nw < cap; i++) {
        const int e = ids[i];
        if (e < 0 || e >= c->n_experts) continue;
        const int32_t key = layer * c->n_experts + e;
        if (c->slot_of[key] >= 0) continue;             /* already resident */

        int dup = 0;                                    /* the same id twice in one top-k */
        for (int j = 0; j < nw; j++) if (w[j].expert == e) { dup = 1; break; }
        if (dup) continue;

        K3ExpertRef r;
        if (k3_expert_ref(c->st, layer, e, &r) != 0) continue;
        if (r.nbytes > c->slot_bytes) continue;

        const int slot = pick_victim(c);
        if (slot < 0) break;
        if (c->key_of[slot] >= 0) { c->slot_of[c->key_of[slot]] = -1; c->evictions++; }
        /* INFLIGHT, not EMPTY. Marking it empty made pick_victim's fast path hand the
         * same slot to the next expert in this very batch. */
        c->key_of[slot] = K3_SLOT_INFLIGHT;
        c->used_at[slot] = ++c->clock;

        w[nw].slot = slot; w[nw].expert = e; w[nw].r = r; w[nw].got = -1; w[nw].pad = 0;
        nw++;
    }
    /* Survival of the prefetch: how much of this layer's PREVIOUS-token routing is
     * still resident when the main thread reaches the layer. The prefetcher's whole
     * point is that they should be; if they are sparse the lookahead is wasteful. */
    if (!from_reader && c->prefetch_depth > 0) {
        const int32_t *row = c->prev_idx + (size_t)layer * (K3_MAX_TOPK + 1);
        const int pn = row[0] < K3_MAX_TOPK ? row[0] : K3_MAX_TOPK;
        if (pn > 0) {
            int kept = 0;
            for (int i = 0; i < pn; i++)
                if (c->slot_of[(size_t)layer * c->n_experts + row[1 + i]] >= 0) kept++;
            c->prefetch_cands += (uint64_t)pn;
            c->prefetch_kept += (uint64_t)kept;
        }
    }
    if (nw == 0) { if (locked) pthread_mutex_unlock(&c->mu); return 0; }
    if (locked) pthread_mutex_unlock(&c->mu);

    /* Issue in DISK-OFFSET order. Experts are not stored id-ordered inside a shard, so
     * sorting by where the bytes actually live turns a scattered set of seeks into a
     * mostly forward sweep. Insertion sort: nw is at most the top-k. */
    for (int i = 1; i < nw; i++) {
        Work t = w[i]; int j = i - 1;
        while (j >= 0 && (w[j].r.shard > t.r.shard ||
                         (w[j].r.shard == t.r.shard && w[j].r.off > t.r.off))) {
            w[j + 1] = w[j]; j--;
        }
        w[j + 1] = t;
    }

    /* ---- phase 2: read, concurrently ---- */
    /* Gate only when this batch actually touches the SLOW checkpoint disk. A fully
     * L2-hit batch reads sdd7 -- the SAME NVMe the trunk streams from -- and sharing
     * the drive's 1.6 GB/s between the two sequential streams costs far less than
     * parking the trunk reader for the whole burst. Measured (93L gen8, cache-gb 8):
     * the trunk parked 1174 s on the gate while the expert phase-2 reads took only
     * 144 s -- an 8x over-yield that doubled wall time. Misses (sdd7 miss, slow
     * /model) are the case the gate exists for: there the expert read is slow and
     * concurrent trunk traffic genuinely slows it. slot_of[key] < 0 is the miss test
     * (key -> L2 slot, -1 when not resident, O(1) via direct indexing). */
    int gate_needed = 0;
    if (c->phase2_hold && c->l2) {
        for (int i = 0; i < nw && !gate_needed; i++) {
            const int32_t key = w[i].r.layer * c->l2->n_experts + w[i].r.expert;
            if (c->l2->slot_of[key] < 0) gate_needed = 1;
        }
    }
    if (c->phase2_hold && gate_needed) c->phase2_hold(c->phase2_ctx, 1);
    const double hs0 = c->l2 ? c->l2->hit_seconds : 0;
    const double ms0 = c->l2 ? c->l2->miss_seconds : 0;
    const double t0 = now_s();
    int omp_inr_nt = 0, inr_in = 0, inr_peak = 0;   /* region diagnostics */
#ifdef _OPENMP
#   pragma omp parallel for schedule(dynamic, 1) num_threads(16)
#endif
    for (int i = 0; i < nw; i++) {
        int64_t pad = 0;
        int64_t got;
#ifdef _OPENMP
        omp_inr_nt = omp_inr_nt ? omp_inr_nt : omp_get_num_threads();
        int p = __sync_add_and_fetch(&inr_in, 1);
        if (p > inr_peak) inr_peak = p;
#endif
        if (c->l2)
            got = k3_l2_load_direct(c->l2, c->st, &w[i].r,
                                    c->arena + (size_t)w[i].slot * c->slot_bytes,
                                    c->slot_bytes, &pad);
        else
            got = k3_expert_load_direct(
                c->st, &w[i].r, c->arena + (size_t)w[i].slot * c->slot_bytes,
                c->slot_bytes, &pad);
#ifdef _OPENMP
        __sync_sub_and_fetch(&inr_in, 1);
#endif
        w[i].got = got;
        w[i].pad = pad;
    }
    if (c->phase2_hold && gate_needed) c->phase2_hold(c->phase2_ctx, 0);
    const double t2 = now_s() - t0;
    c->phase2_seconds += t2;
    c->phase2_bytes += (uint64_t)nw * (uint64_t)c->slot_bytes;
    c->load_seconds += t2;
    if (c->l2 && t2 > 0) {
        /* Fold this batch's wall time into the L2 wall counters, split by the share of
         * thread-cumulative pread time that went to hits vs misses. */
        const double dt_h = c->l2->hit_seconds - hs0;
        const double dt_m = c->l2->miss_seconds - ms0;
        const double tot = dt_h + dt_m;
        if (tot > 0) {
            c->l2->hit_wall += t2 * (dt_h / tot);
            c->l2->miss_wall += t2 * (dt_m / tot);
        }
    }
    if (t2 > 0.05) {
        int nth = 0;
#ifdef _OPENMP
        nth = omp_get_num_threads();
#endif
        double p2pread = (c->l2 ? c->l2->hit_seconds : 0) - (c->l2 ? hs0 : 0);
        fprintf(stderr, "DBG getmany L%d nw=%d wall=%.3fs thr(out)%d thr(in)%d conc_peak=%d pread=%.3fs%s\n",
                layer, nw, t2, nth, omp_inr_nt, inr_peak, p2pread, from_reader ? " [reader]" : "");
    }

    /* ---- phase 3: publish only what actually arrived ---- */
    if (locked) pthread_mutex_lock(&c->mu);
    int ok = 0;
    for (int i = 0; i < nw; i++) {
        if (w[i].got != w[i].r.nbytes) {
            fprintf(stderr, "k3_cache: short prefetch of L%d expert %d (%lld of %lld); "
                            "leaving the slot empty so it cannot be served as a hit\n",
                    layer, w[i].expert, (long long)w[i].got, (long long)w[i].r.nbytes);
            c->key_of[w[i].slot] = K3_SLOT_EMPTY;       /* release the reservation */
            continue;
        }
        const int32_t key = layer * c->n_experts + w[i].expert;
        /* The reader can lose the race: while it was reading during phase 2 (unlocked)
         * the main thread admitted the very same key. Publishing a duplicate resident
         * copy would leave two slots with one slot_of pointer -- inconsistent. Release
         * the slot and count the wasted read. */
        if (from_reader && c->slot_of[key] >= 0) {
            c->prefetch_late++;
            c->key_of[w[i].slot] = K3_SLOT_EMPTY;
            c->bytes_read += (uint64_t)w[i].got;
            continue;
        }
        c->ref[w[i].slot] = w[i].r;
        c->pad[w[i].slot] = (int32_t)w[i].pad;
        c->key_of[w[i].slot] = key;
        c->slot_of[key] = w[i].slot;
        c->used_at[w[i].slot] = ++c->clock;
        if (c->pin_layer && c->pin_layer[layer]) c->pinned[w[i].slot] = 1;
        c->bytes_read += (uint64_t)w[i].got;
        c->prefetch_reads++;
        if (from_reader) c->prefetch_issued++;
        ok++;
    }
    if (locked) pthread_mutex_unlock(&c->mu);
    return ok;
}

/* Main-thread entry: the forward path routes here via src.getmany. */
static int cache_getmany(K3ExpertSrc *self, int layer, const int *ids, int n)
{
    return cache_getmany_inner((K3Cache *)self, layer, ids, n, 0);
}

/* src.on_route: record this layer's routing for the NEXT token, under the same mutex
 * as the reader consumes it. Recording happens ALWAYS (even at prefetch_depth 0) so
 * prefetch survival can be compared against the baseline; only the forward-path hint
 * and the reader are gated on the depth. */
static void cache_on_route(K3ExpertSrc *self, int layer, const int *idx, int n)
{
    K3Cache *c = (K3Cache *)self;
    if (n > K3_MAX_TOPK) n = K3_MAX_TOPK;
    if (n <= 0) return;
    int32_t *row = c->prev_idx + (size_t)layer * (K3_MAX_TOPK + 1);
    const int locked = c->pref_started;
    if (locked) pthread_mutex_lock(&c->mu);
    row[0] = n;
    memcpy(row + 1, idx, (size_t)n * sizeof(int32_t));
    for (int i = n; i < K3_MAX_TOPK; i++) row[1 + i] = -1;
    if (locked) pthread_mutex_unlock(&c->mu);
}

/* The async reader: newest-wins mailbox. pref_busy == 1 always means "a job waits" --
 * a hint arriving while the reader is mid-run rewrites the mailbox for the NEXT loop,
 * and the reader picks it up because busy is still set. Each consumed job runs the
 * same cache_getmany_inner as the main thread, from the L2, unlocked reads. */
static void *pref_io_main(void *arg)
{
    K3Cache *c = (K3Cache *)arg;
    pthread_mutex_lock(&c->mu);
    for (;;) {
        while (!c->pref_stop && !c->pref_busy)
            pthread_cond_wait(&c->cv, &c->mu);
        if (c->pref_stop) break;
        K3PrefJob j = c->pref_job;
        c->pref_busy = 0;
        pthread_mutex_unlock(&c->mu);

        if (j.n > 0)
            cache_getmany_inner(c, j.layer, j.idx, j.n, 1);

        pthread_mutex_lock(&c->mu);
    }
    pthread_mutex_unlock(&c->mu);
    return NULL;
}

/* Forward-path hint, called once per layer after the router runs. Submits the
 * previous token's routing of layer+prefetch_depth to the mailbox and starts the
 * reader lazily. O(1) plus one lock when depth is armed; a no-op at depth 0. */
void k3_cache_prefetch_ahead(K3Cache *c, int layer)
{
    const int target = layer + c->prefetch_depth;
    if (target < 0 || target >= c->n_layers) return;

    /* Lazy reader start, serialised by the mutex so only one pthread_create wins. */
    if (!c->pref_started) {
        pthread_mutex_lock(&c->mu);
        if (!c->pref_started) {
            c->pref_started = 1;
            if (pthread_create(&c->pref_thr, NULL, pref_io_main, c) != 0) {
                c->pref_started = 0;                    /* stay in the no-thread baseline */
                pthread_mutex_unlock(&c->mu);
                return;
            }
        }
        pthread_mutex_unlock(&c->mu);
    }

    const int32_t *row = c->prev_idx + (size_t)target * (K3_MAX_TOPK + 1);
    pthread_mutex_lock(&c->mu);
    K3PrefJob *j = &c->pref_job;
    int n = row[0] < K3_MAX_TOPK ? row[0] : K3_MAX_TOPK;
    if (c->prefetch_cap > 0 && c->prefetch_cap < n) n = c->prefetch_cap;
    if (n > 0) {
        j->layer = target;
        j->n = n;
        memcpy(j->idx, row + 1, (size_t)n * sizeof(int32_t));
    }
    if (n > 0 && !c->pref_busy) {   /* busy: mailbox content is already the newest */
        c->pref_busy = 1;
        pthread_cond_signal(&c->cv);
    }
    pthread_mutex_unlock(&c->mu);
}

/* Is this expert already resident, i.e. would get() serve it with no disk read? Used by
 * the draft model's cache-only routing to propose tokens without any expert I/O; if it
 * is resident, fill_q hands back the same bytes get() would. */
static int cache_resident(K3ExpertSrc *self, int layer, int expert, K3ExpertQ *out)
{
    K3Cache *c = (K3Cache *)self;
    if (layer < 0 || layer >= c->n_layers || expert < 0 || expert >= c->n_experts)
        return 0;
    const int locked = c->pref_started;
    if (locked) pthread_mutex_lock(&c->mu);
    const int32_t key = layer * c->n_experts + expert;
    const int slot = c->slot_of[key];
    int rc = 0;
    if (slot >= 0) {
        if (out) fill_q(c, slot, out);
        rc = 1;
    }
    if (locked) pthread_mutex_unlock(&c->mu);
    return rc;
}

static int cache_get(K3ExpertSrc *self, int layer, int expert, K3ExpertQ *out)
{
    K3Cache *c = (K3Cache *)self;          /* src is the first member, by contract */
    if (layer < 0 || layer >= c->n_layers || expert < 0 || expert >= c->n_experts) {
        fprintf(stderr, "k3_cache: out of range L%d expert %d\n", layer, expert);
        return -1;
    }
    const int locked = c->pref_started;
    if (locked) pthread_mutex_lock(&c->mu);
    c->hist[layer * c->n_experts + expert]++;

    /* Record the request before serving it. The trace must reflect what the MODEL
     * asked for, independent of what the cache happened to hold, or replaying it at a
     * different capacity would be meaningless. */
    if (c->ntrace + 2 > c->captrace) {
        int64_t nc = c->captrace ? c->captrace * 2 : (1 << 16);
        int32_t *nt = (int32_t *)realloc(c->trace, (size_t)nc * sizeof(int32_t));
        if (nt) { c->trace = nt; c->captrace = nc; }
    }
    if (c->ntrace + 2 <= c->captrace) {
        c->trace[c->ntrace++] = layer;
        c->trace[c->ntrace++] = expert;
    }

    const int slot = admit_unlocked(c, layer, expert);
    int rc;
    if (slot < 0) rc = -1;
    else { fill_q(c, slot, out); rc = 0; }
    if (locked) pthread_mutex_unlock(&c->mu);
    return rc;
}

int k3_cache_init(K3Cache *c, const K3St *st, const K3Cfg *cfg, int64_t budget_bytes)
{
    memset(c, 0, sizeof *c);
    /* L1 replacement policy. 1 = heat (default; lowest hist count evicted), 0 = LRU.
     * Heat is the default because LRU cannot survive a token that touches more keys
     * than the arena holds: per-token JRAM scanning, LRU evicts the just-used prefix
     * and the next token starts all-miss (measured TRUE hit 0.00% at 8 GB LRU vs
     * 3.46% at 8 GB heat). K3_L1_POLICY=lru (or the CLI --l1-policy, which sets that
     * env var) opts back to LRU. */
    c->policy = (getenv("K3_L1_POLICY") && !strcmp(getenv("K3_L1_POLICY"), "lru")) ? 0 : 1;
    c->src.get = cache_get;
    c->src.resident = cache_resident;
    /* K3_NOPREFETCH=1 disables the batch path at runtime. An A/B between two BUILDS
     * compares two binaries; an A/B on one binary compares one decision, which is the
     * only way to attribute a timing difference to the prefetch rather than to the
     * compiler, the layout, or the weather. */
    c->src.getmany = getenv("K3_NOPREFETCH") ? NULL : cache_getmany;
    if (!c->src.getmany)
        fprintf(stderr, "k3_cache: batch prefetch DISABLED by K3_NOPREFETCH\n");
    c->src.on_route = cache_on_route;
    c->src.ctx = c;
    c->st = st;
    c->n_layers = cfg->n_layers;
    c->n_experts = cfg->n_experts;

    /* Size a slot from the checkpoint rather than from arithmetic: find any expert and
     * ask how many bytes it actually occupies. */
    K3ExpertRef probe;
    int found = 0;
    for (int L = 0; L < cfg->n_layers && !found; L++) {
        if (k3_is_dense(cfg, L)) continue;
        if (k3_expert_ref(st, L, 0, &probe) == 0) found = 1;
    }
    if (!found) { fprintf(stderr, "k3_cache: no routed experts in this shard set\n"); return -1; }
    /* Room for an O_DIRECT read widened outward to 4096 boundaries at both ends. */
    /* Round the SLOT STRIDE up to the O_DIRECT alignment, not just the arena base.
     *
     * posix_memalign below aligns the arena, which aligns slot 0 and nothing else: slot
     * N starts at arena + N*slot_bytes, so every slot is aligned only if slot_bytes is
     * itself a multiple of K3_ST_ALIGN. On the real checkpoint an expert is 17,547,264
     * bytes, which is exactly 4284 * 4096, so this held BY COINCIDENCE and the engine
     * worked. With any other expert size -- another model, a repacked container, or the
     * few-KB experts in tests/fixtures/cache -- every O_DIRECT read into every slot
     * after the first returns 0 bytes and the cache silently serves nothing. The
     * fixture deliberately uses a non-conforming expert size so this is gated rather
     * than left to the real checkpoint's coincidence (tests/unit/test_cache.c). */
    c->slot_bytes = probe.nbytes + 2 * K3_ST_ALIGN;
    c->slot_bytes = (c->slot_bytes + K3_ST_ALIGN - 1) & ~(int64_t)(K3_ST_ALIGN - 1);

    c->nslot = (int)(budget_bytes / c->slot_bytes);
    if (c->nslot < cfg->topk + 1) {
        fprintf(stderr,
                "k3_cache: budget %.2f GB gives %d slots of %.2f MB, but top-%d needs at "
                "least %d. A cache smaller than one token's working set would evict an "
                "expert that is still being multiplied.\n",
                (double)budget_bytes / 1e9, c->nslot, (double)c->slot_bytes / 1e6,
                cfg->topk, cfg->topk + 1);
        return -1;
    }

    /* Page aligned so the arena can later be read into with O_DIRECT unchanged. */
    /* 2 MB aligned and hugepage-advised, for the same reason as the trunk arena: every
     * O_DIRECT expert read pins its destination pages, and a 17.55 MB slot on 4 KB pages
     * is 4,284 pins per read, 1,472 reads per token. See k3_trunk.c:k3_alloc_direct.
     * K3_NOHUGE=1 restores 4 KB so the two can be compared on one binary. */
    {
        const int huge = !getenv("K3_NOHUGE");
        const size_t al = huge ? (2u << 20) : 4096u;
        size_t want = (size_t)c->nslot * c->slot_bytes;
        if (huge) want = (want + al - 1) & ~(al - 1);
        if (posix_memalign((void **)&c->arena, al, want) != 0) {
            fprintf(stderr, "k3_cache: cannot allocate %.2f GB arena\n", (double)want / 1e9);
            return -1;
        }
#if defined(MADV_HUGEPAGE)
        if (huge) madvise(c->arena, want, MADV_HUGEPAGE);
#endif
    }
    if (0) {
        fprintf(stderr, "k3_cache: cannot allocate %.2f GB arena\n",
                (double)c->nslot * c->slot_bytes / 1e9);
        return -1;
    }

    const size_t nkey = (size_t)c->n_layers * c->n_experts;
    c->slot_of = (int32_t *)malloc(nkey * sizeof(int32_t));
    c->key_of  = (int32_t *)malloc((size_t)c->nslot * sizeof(int32_t));
    c->used_at = (uint64_t *)calloc((size_t)c->nslot, sizeof(uint64_t));
    c->pinned  = (unsigned char *)calloc((size_t)c->nslot, 1);
    c->pin_layer = (unsigned char *)calloc((size_t)c->n_layers, 1);
    c->ref     = (K3ExpertRef *)calloc((size_t)c->nslot, sizeof(K3ExpertRef));
    c->pad     = (int32_t *)calloc((size_t)c->nslot, sizeof(int32_t));
    c->hist    = (uint32_t *)calloc(nkey, sizeof(uint32_t));
    c->prev_idx = (int32_t *)malloc((size_t)cfg->n_layers * (K3_MAX_TOPK + 1) * sizeof(int32_t));
    c->prefetch_cap = 0;   /* reset to per-run CLI value; 0 = no per-layer limit */
    if (!c->slot_of || !c->key_of || !c->used_at || !c->pinned || !c->pin_layer ||
        !c->ref || !c->pad || !c->hist || !c->prev_idx) {
        k3_cache_free(c); return -1;
    }
    for (size_t i = 0; i < nkey; i++) c->slot_of[i] = -1;
    for (int i = 0; i < c->nslot; i++) c->key_of[i] = -1;
    for (int l = 0; l < cfg->n_layers; l++) {
        int32_t *row = c->prev_idx + (size_t)l * (K3_MAX_TOPK + 1);
        row[0] = 0;
        for (int i = 0; i < K3_MAX_TOPK; i++) row[1 + i] = -1;
    }
    c->pref_inited = 1;
    pthread_mutex_init(&c->mu, NULL);
    pthread_cond_init(&c->cv, NULL);
    return 0;
}

void k3_cache_free(K3Cache *c)
{
    if (c->pref_started) {
        pthread_mutex_lock(&c->mu);
        c->pref_stop = 1;
        pthread_cond_broadcast(&c->cv);
        pthread_mutex_unlock(&c->mu);
        pthread_join(c->pref_thr, NULL);
    }
    if (c->pref_inited) {
        pthread_mutex_destroy(&c->mu);
        pthread_cond_destroy(&c->cv);
    }
    k3_aligned_free(c->arena); free(c->slot_of); free(c->key_of);
    free(c->used_at); free(c->pinned); free(c->pin_layer);
    free(c->ref); free(c->pad); free(c->hist);
    free(c->prev_idx);
    free(c->trace);
    memset(c, 0, sizeof *c);
}

int k3_cache_dump_trace(const K3Cache *c, const char *path)
{
    if (!c->trace || c->ntrace == 0) return -1;
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    const size_t n = fwrite(c->trace, sizeof(int32_t), (size_t)c->ntrace, f);
    fclose(f);
    printf("wrote %s: %lld requests (%.1f KB)\n",
           path, (long long)(c->ntrace / 2), (double)c->ntrace * 4 / 1024.0);
    return n == (size_t)c->ntrace ? 0 : -1;
}

int k3_cache_pin(K3Cache *c, int layer, int expert, int pin)
{
    const int32_t key = layer * c->n_experts + expert;
    if (key < 0 || key >= c->n_layers * c->n_experts) return 0;
    const int slot = c->slot_of[key];
    if (slot < 0) return 0;
    c->pinned[slot] = pin ? 1 : 0;
    return 1;
}

int k3_cache_pin_layer(K3Cache *c, int layer, int pin)
{
    if (!c->pin_layer || layer < 0 || layer >= c->n_layers) return -1;
    c->pin_layer[layer] = pin ? 1 : 0;
    return 0;
}

int k3_cache_prefetch(K3Cache *c, int layer, int expert)
{
    return admit(c, layer, expert) >= 0 ? 0 : -1;
}

void k3_cache_reset_stats(K3Cache *c)
{
    c->hits = c->misses = c->evictions = c->bytes_read = 0;
    c->load_seconds = 0.0;
    c->phase2_seconds = 0.0;
    c->phase2_bytes = 0;
    /* prefetch_reads belongs to the same window as hits and misses.
     *
     * k3_cache_report derives the effective hit rate as (hits - prefetch_reads), so both
     * counters must cover the same interval. Resetting one without the other compares a
     * per-window numerator against a since-startup subtrahend, which drives the result
     * negative and clamps it to zero at every cache size. */
    c->prefetch_reads = 0;
    c->prefetch_issued = c->prefetch_late = c->prefetch_kept = c->prefetch_cands = 0;
}

void k3_cache_report(const K3Cache *c, const char *label)
{
    const uint64_t n = c->hits + c->misses;
    int resident = 0, pinned = 0;
    for (int i = 0; i < c->nslot; i++) { if (c->key_of[i] >= 0) resident++; if (c->pinned[i]) pinned++; }
    printf("cache [%s]\n", label ? label : "");
    printf("  slots        : %d of %.2f MB = %.2f GB arena (%d resident, %d pinned)\n",
           c->nslot, (double)c->slot_bytes / 1e6,
           (double)c->nslot * c->slot_bytes / 1e9, resident, pinned);
    printf("  requests     : %llu  hits %llu (%.2f%%)  misses %llu  evictions %llu\n",
           (unsigned long long)n, (unsigned long long)c->hits,
           n ? 100.0 * c->hits / n : 0.0,
           (unsigned long long)c->misses, (unsigned long long)c->evictions);
    /* The prefetch makes the raw hit rate above flattering: an expert the batch read
     * from disk moments earlier is resident by the time get() asks, so it counts as a
     * hit. Report what was actually served from RAM without touching the disk. */
    if (c->prefetch_reads) {
        const unsigned long long served = (c->hits > c->prefetch_reads)
                                        ? c->hits - c->prefetch_reads : 0;
        printf("  of those hits : %llu came from the batch prefetch, i.e. read from disk\n"
               "                  this token; TRUE resident hit rate %.2f%%\n",
               (unsigned long long)c->prefetch_reads, n ? 100.0 * served / n : 0.0);
    }
    printf("  read from disk: %.2f GB in %.2f s (%.0f MB/s while loading)\n",
           (double)c->bytes_read / 1e9, c->load_seconds,
           c->load_seconds > 0 ? (double)c->bytes_read / 1e6 / c->load_seconds : 0.0);
    printf("  phase2 i/o    : %.2f GB in %.2f s (%.0f MB/s)  [pure parallel disk read]\n",
           (double)c->phase2_bytes / 1e9, c->phase2_seconds,
           c->phase2_seconds > 0 ? (double)c->phase2_bytes / 1e6 / c->phase2_seconds : 0.0);
    if (c->prefetch_depth > 0 && c->prefetch_cands) {
        printf("  prefetch      : issued %llu  LATE %llu  survival %.1f%% (%llu/%llu prev-token routed experts still resident)\n",
               (unsigned long long)c->prefetch_issued,
               (unsigned long long)c->prefetch_late,
               100.0 * c->prefetch_kept / c->prefetch_cands,
               (unsigned long long)c->prefetch_kept,
               (unsigned long long)c->prefetch_cands);
    }
}

int k3_cache_dump_hist(const K3Cache *c, const char *path)
{
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fprintf(f, "{\"n_layers\":%d,\"n_experts\":%d,\"counts\":{",
            c->n_layers, c->n_experts);
    int first = 1;
    for (int L = 0; L < c->n_layers; L++) {
        for (int e = 0; e < c->n_experts; e++) {
            const uint32_t v = c->hist[L * c->n_experts + e];
            if (!v) continue;                       /* sparse: most are zero */
            fprintf(f, "%s\"%d,%d\":%u", first ? "" : ",", L, e, v);
            first = 0;
        }
    }
    fprintf(f, "}}\n");
    fclose(f);
    return 0;
}
