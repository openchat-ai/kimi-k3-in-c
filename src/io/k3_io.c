#include "k3_io.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void *k3_io_tier_main(void *arg)
{
    K3IO *io = ((K3IO **)arg)[0];
    int   tier = (int)(intptr_t)((void **)arg)[1];
    free(arg);
    for (;;) {
        /* Stamped before the lock, so the queue-wait figure includes any time the worker
         * spent contending for it. Taken inside the lock instead it would read as zero
         * contention, which is the conclusion one wants to be able to draw. */
        const double t_lock = now_s();
        pthread_mutex_lock(&io->mu);
        /* Take a request from ANY group that has work, scanning round-robin.
         *
         * The old rule drained io->q[tier][active_group[tier]] and ignored every other
         * group until k3_io_set_active switched over. Two consequences, both measured:
         *
         *  - Deadlock. With the phase2 hold unmounted, active_group is pinned at 0
         *    forever, so requests submitted to group 1 waited for a group nobody ever
         *    selected: 41/41 threads in futex_wait_queue, zero IO, log frozen at
         *    104 bytes (v5_l2g1, and again in v6_l2g1rw).
         *  - No overlap. A single group-0 FIFO is served by all 16 workers, so the
         *    trunk stream and the L2 burst took turns instead of flying at the NVMe
         *    together. The 2026-09-26 morning runs reported I/O share 144.1% at
         *    81.28 s/tok, which is only possible with more than one stream in flight;
         *    the park/hold variants measured 82.7-95.2% and 92-137 s/tok.
         *
         * Preference alone does not parallelise: the trunk stream keeps group 0
         * permanently non-empty, so "active group first, fall back when empty" never
         * reaches the fallback (v12/v13: share 86.6% and 95.2%). Rotating the scan start
         * spreads workers across whichever queues have work, so trunk and L2 run
         * concurrently. k3_io_set_active() and active_group[] have since been removed
         * outright: nothing needed them, and leaving a "kept for compatibility" toggle
         * next to a drain it no longer controls is how the next reader wires it back in. */
        int g = -1;
        K3IOReq *r = NULL;
        const double t_deq = now_s();
        {
            /* Round-robin the start point, then take the first non-empty queue. Two
             * workers waking together therefore tend to land in DIFFERENT groups,
             * which is what parallelises the two streams; a fixed scan from group 0
             * would hand every one of them to the trunk FIFO. */
            const int start = io->rr[tier]++ % K3_IO_MAX_GROUPS;
            for (int i = 0; i < K3_IO_MAX_GROUPS; i++) {
                const int k = (start + i) % K3_IO_MAX_GROUPS;
                if (io->q[tier][k]) { g = k; r = io->q[tier][k]; break; }
            }
        }
        if (r) {
            io->q[tier][g] = r->next;
            if (!io->q[tier][g]) io->qtail[tier][g] = NULL;
        }
        if (!r && io->stop) { pthread_mutex_unlock(&io->mu); return NULL; }
        if (!r) {
            /* Time the sleep itself, not the decision to sleep. The previous counter sampled
             * the instant between finding the queues empty and calling cond_wait, which
             * measured the cost of a branch: 0.1 s against 243 s of wall. What the day's
             * conclusion needed was how long workers sat in the wait, so wrap the wait.
             * pthread_cond_wait returns with io->mu held again, which is why the unlock
             * below comes after it. */
            const double t_sleep = now_s();
            pthread_cond_wait(&io->cv[tier], &io->mu);
            K3_STAT_ADD_U64(&io->stat_sleep_ns[tier], (now_s() - t_sleep) * 1e9);
            K3_STAT_ADD_U64(&io->stat_sleep_n[tier], 1);
            pthread_mutex_unlock(&io->mu);
            continue;
        }
        pthread_mutex_unlock(&io->mu);
        K3_STAT_ADD_U64(&io->stat_lock_ns[tier], (now_s() - t_lock) * 1e9);

        /* Time the queue wait separately from the read. If a request spends its life here
         * rather than in pread, the drive is idle and the limit is the pool; if it spends it
         * in pread, the drive is the limit and the pool size is irrelevant. Those two
         * require different fixes and only the ratio between them tells you which applies. */
        K3_STAT_ADD_U64(&io->stat_queue_ns[tier], (t_deq - r->t_sub) * 1e9);

        const double t_io0 = now_s();
        /* Drain one request. Each tier has its own worker POOL; the NVMe pool's
         * several workers let trunk (sequential) and expert L2-hit (parallel)
         * streams share the drive concurrently -- no 0/1 gate. The slow tier also
         * gets a few workers: a HDD reaches ~2.6x its single-stream rate with 4
         * parallel streams, and isolation is preserved because it is a separate
         * pool -- slow reads never stall the fast tier. */
        ssize_t rc;
        if (r->write) {
            rc = pwrite(r->fd, r->dst, r->nbytes, r->offset);
        } else if (r->chunk > 0 && r->nbytes > r->chunk) {
            /* Chunked span: read the whole thing as consecutive chunks in ONE
             * worker pass, so a sequential stream gets one completion instead of
             * one submit/wait round-trip per chunk (which cost ~300 ms/chunk). */
            ssize_t done = 0;
            rc = 0;
            while ((size_t)done < r->nbytes) {
                size_t want = r->nbytes - (size_t)done;
                if (want > r->chunk) want = r->chunk;
                const double bw = now_s();
                ssize_t n = pread(r->fd, r->dst + done, want, r->offset + done);
                if (getenv("K3_IO_DBG"))
                    fprintf(stderr, "DBG io chunk n=%ld want=%zu dt=%.2f\n",
                            (long)n, want, now_s() - bw);
                if (n <= 0) {
                    if (getenv("K3_IO_DBG"))
                        fprintf(stderr, "DBG io chunk pread fail done=%ld want=%zu errno=%d\n",
                                (long)done, want, errno);
                    rc = n; break;
                }
                done += n;
                if (n < (ssize_t)want) { rc = n; break; }
            }
            if ((size_t)done == r->nbytes) rc = done;
        } else {
            rc = pread(r->fd, r->dst, r->nbytes, r->offset);
        }
        if (getenv("K3_IO_DBG"))
            fprintf(stderr, "DBG io worker tier=%d rc=%ld nbytes=%zu\n", tier, (long)rc, r->nbytes);

        /* Cumulative across workers, so stat_bytes / stat_pread_s is the rate one stream
         * would have delivered at the device, and stat_pread_s / wall is the concurrency
         * actually achieved. Reported separately now, because the single figure conflated
         * them and that conflation is what made 109 MB/s look like a device limit when it
         * was a per-thread rate with ~16 threads behind it.
         *
         * Bytes count only on success. Adding r->nbytes unconditionally let a short or
         * failed read count as delivered, which inflates the rate by exactly the shortfall. */
        {
            const double dt = now_s() - t_io0;
            const size_t got = (rc > 0) ? (size_t)rc : 0;
            K3_STAT_ADD_U64(&io->stat_pread_ns[tier], dt * 1e9);
            K3_STAT_ADD_U64(&io->stat_reqs[tier], 1);
            K3_STAT_ADD_U64(&io->stat_bytes[tier], got);
            if (g >= 0 && g < K3_IO_MAX_GROUPS) {
                K3_STAT_ADD_U64(&io->stat_pread_ns_g[tier][g], dt * 1e9);
                K3_STAT_ADD_U64(&io->stat_reqs_g[tier][g], 1);
                K3_STAT_ADD_U64(&io->stat_bytes_g[tier][g], got);
                K3_STAT_ADD_U64(&io->stat_queue_ns_g[tier][g], (t_deq - r->t_sub) * 1e9);
            }
            if (got != r->nbytes) K3_STAT_ADD_U64(&io->stat_fail[tier], 1);
        }

        pthread_mutex_lock(&r->mu);
        r->rc = rc;
        r->done = 1;
        pthread_cond_broadcast(&r->cv);
        pthread_mutex_unlock(&r->mu);
    }
}

void k3_io_init(K3IO *io, int tiers, const int *workers)
{
    memset(io, 0, sizeof *io);
    pthread_mutex_init(&io->mu, NULL);
    io->stop = 0;
    io->ntiers = tiers;
    for (int t = 0; t < tiers; t++) {
        pthread_cond_init(&io->cv[t], NULL);
        int nw = workers ? workers[t] : 1;
        if (nw < 1) nw = 1;
        if (nw > K3_IO_MAX_WORKERS) nw = K3_IO_MAX_WORKERS;
        io->nworkers[t] = nw;
        for (int w = 0; w < io->nworkers[t]; w++) {
            void **arg = (void **)malloc(2 * sizeof *arg);
            arg[0] = io;
            arg[1] = (void *)(intptr_t)t;
            pthread_create(&io->thread[t][w], NULL, k3_io_tier_main, arg);
        }
    }
}

void k3_io_report(const K3IO *io)
{
    /* Two rates, not one. stat_bytes / stat_pread_s is what ONE stream delivered at the
     * device, and it is the figure to compare against a standalone probe reading the same
     * file in the same shape. stat_pread_s / wall is how many streams were actually in
     * flight. The old line printed the first and labelled it "device", which read as a
     * device limit; the engine's 109 MB/s was a per-thread rate with sixteen threads behind
     * it, against a device that does 1600. Both numbers are needed to tell a saturated
     * device from an idle one, and printing one invites exactly the error v55 corrected.
     *
     * Sleep is reported as time and count, because a large total from a handful of long
     * waits and the same total from many short ones mean different things, and a single
     * figure cannot distinguish them. */
    const double now = now_s();
    const double wall = (io->t_start_s > 0) ? (now - io->t_start_s) : 0.0;

    for (int t = 0; t < io->ntiers; t++) {
        const uint64_t reqs = K3_STAT_GET_U64(&io->stat_reqs[t]);
        if (!reqs) continue;
        const double pread_s = (double)io->stat_pread_ns[t] / 1e9;
        const double queue_s = (double)io->stat_queue_ns[t] / 1e9;
        const double lock_s  = (double)io->stat_lock_ns[t] / 1e9;
        const double sleep_s = (double)io->stat_sleep_ns[t] / 1e9;
        const double pr = pread_s > 0 ? pread_s : 1e-9;
        const double wall_s = wall > 0 ? wall : pr;
        printf("kio tier%d: %llu reqs, %.2f GB delivered | "
               "per-stream %.0f MB/s, aggregate %.0f MB/s, concurrency %.1fx | "
               "queue %.1f s (%.1f%% of io), submit-lock %.1f s, worker-lock %.1f s, "
               "sleep %.1f s in %.0f waits (%.0f%% of worker-time)%s\n",
               t, (unsigned long long)reqs,
               (double)io->stat_bytes[t] / 1e9,
               (double)io->stat_bytes[t] / pr / 1e6,
               (double)io->stat_bytes[t] / wall_s / 1e6,
               pread_s / wall_s,
               queue_s,
               100.0 * queue_s / pr,
               (double)io->stat_submit_ns[t] / 1e9, lock_s,
               sleep_s, (double)io->stat_sleep_n[t],
               100.0 * sleep_s / (io->nworkers[t] * wall_s),
               io->stat_fail[t] ? "  [HAS SHORT/FAILED READS]" : "");

        for (int g = 0; g < K3_IO_MAX_GROUPS; g++) {
            const uint64_t gr = K3_STAT_GET_U64(&io->stat_reqs_g[t][g]);
            if (!gr) continue;
            const double gp = (double)io->stat_pread_ns_g[t][g] / 1e9;
            const double gq = (double)io->stat_queue_ns_g[t][g] / 1e9;
            const double gpr = gp > 0 ? gp : 1e-9;
            printf("      group%d: %llu reqs, %.2f GB | per-stream %.0f MB/s | queue %.1f s (%.1f%%)\n",
                   g, (unsigned long long)gr,
                   (double)io->stat_bytes_g[t][g] / 1e9,
                   (double)io->stat_bytes_g[t][g] / gpr / 1e6,
                   gq, 100.0 * gq / gpr);
        }
    }
}

void k3_io_free(K3IO *io)
{
    k3_io_report(io);
    pthread_mutex_lock(&io->mu);
    io->stop = 1;
    for (int t = 0; t < io->ntiers; t++) pthread_cond_broadcast(&io->cv[t]);
    pthread_mutex_unlock(&io->mu);
    for (int t = 0; t < io->ntiers; t++)
        for (int w = 0; w < io->nworkers[t]; w++) pthread_join(io->thread[t][w], NULL);
    for (int t = 0; t < io->ntiers; t++) pthread_cond_destroy(&io->cv[t]);
    pthread_mutex_destroy(&io->mu);
}

K3IOReq *k3_io_submit_g(K3IO *io, int tier, int group, int fd, off_t off,
                        size_t nbytes, size_t chunk, void *dst)
{
    if (group < 0) group = 0;
    if (group >= K3_IO_MAX_GROUPS) group = K3_IO_MAX_GROUPS - 1;
    K3IOReq *r = (K3IOReq *)calloc(1, sizeof *r);
    if (!r) return NULL;
    r->tier = tier;
    r->group = group;
    r->fd = fd;
    r->offset = off;
    r->nbytes = nbytes;
    r->chunk = chunk;
    r->dst = (unsigned char *)dst;
    /* Stamped after the calloc but before the lock, so the worker's queue figure starts
     * where the caller decided to make the request rather than where the pool got to it. */
    r->t_sub = now_s();
    pthread_mutex_init(&r->mu, NULL);
    pthread_cond_init(&r->cv, NULL);

    const double t_lk = now_s();
    pthread_mutex_lock(&io->mu);
    K3_STAT_ADD_U64(&io->stat_submit_ns[tier], (now_s() - t_lk) * 1e9);
    /* Stamp the tier's clock origin on the first request, so the report can divide by wall
     * and print the concurrency actually achieved. Before this the report had no wall and
     * had to guess one, which is why it printed a per-stream rate under the label "device". */
    if (io->t_start_s == 0.0) io->t_start_s = now_s();
    if (io->qtail[tier][group]) io->qtail[tier][group]->next = r;
    else                        io->q[tier][group] = r;
    io->qtail[tier][group] = r;
    if (getenv("K3_IO_DBG"))
        fprintf(stderr, "DBG io submit tier=%d g=%d nbytes=%zu qhead=%p\n",
                tier, group, nbytes, (void*)io->q[tier][group]);
    pthread_cond_broadcast(&io->cv[tier]);
    pthread_mutex_unlock(&io->mu);
    return r;
}

K3IOReq *k3_io_submit(K3IO *io, int tier, int fd, off_t off,
                      size_t nbytes, size_t chunk, void *dst)
{
    return k3_io_submit_g(io, tier, 0, fd, off, nbytes, chunk, dst);
}

K3IOReq *k3_io_submit_write(K3IO *io, int tier, int fd, off_t off,
                            size_t nbytes, const void *src)
{
    K3IOReq *r = (K3IOReq *)calloc(1, sizeof *r);
    if (!r) return NULL;
    r->tier = tier;
    r->fd = fd;
    r->offset = off;
    r->nbytes = nbytes;
    r->dst = (unsigned char *)src;
    r->write = 1;
    r->chunk = 0;
    pthread_mutex_init(&r->mu, NULL);
    pthread_cond_init(&r->cv, NULL);

    pthread_mutex_lock(&io->mu);
    /* Writes join group 0. This used to follow io->active_group[tier], because the
     * phase-2 hold parked the trunk in group 1 and a refill write left in group 0
     * would queue behind it (gateAB_085122). Two later changes made that moot: the
     * hold is gone, and workers now drain every non-empty group round-robin, so group
     * choice no longer decides who gets served. Hard-pinning to group 1 instead was
     * also tried (v6_l2g1rw) and wedged: the L2 hit reads live in group 0, so a write
     * parked in group 1 waited on a queue nothing drained. */
    const int g = 0;
    r->group = g;
    if (io->qtail[tier][g]) io->qtail[tier][g]->next = r;
    else                    io->q[tier][g] = r;
    io->qtail[tier][g] = r;
    if (getenv("K3_IO_DBG"))
        fprintf(stderr, "DBG io submit_w tier=%d g=%d nbytes=%zu qhead=%p\n", tier, g, nbytes, (void*)io->q[tier][g]);
    pthread_cond_broadcast(&io->cv[tier]);
    pthread_mutex_unlock(&io->mu);
    return r;
}

ssize_t k3_io_wait(K3IOReq *r)
{
    pthread_mutex_lock(&r->mu);
    while (!r->done) pthread_cond_wait(&r->cv, &r->mu);
    const ssize_t rc = r->rc;
    pthread_mutex_unlock(&r->mu);
    pthread_mutex_destroy(&r->mu);
    pthread_cond_destroy(&r->cv);
    free(r);
    return rc;
}