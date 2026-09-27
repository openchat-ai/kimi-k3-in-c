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
         * concurrently. k3_io_set_active is kept for compatibility but no longer gates
         * the drain. */
        int g = -1;
        K3IOReq *r = NULL;
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
            pthread_cond_wait(&io->cv[tier], &io->mu);
            pthread_mutex_unlock(&io->mu);
            continue;
        }
        pthread_mutex_unlock(&io->mu);

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

void k3_io_free(K3IO *io)
{
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
    pthread_mutex_init(&r->mu, NULL);
    pthread_cond_init(&r->cv, NULL);

    pthread_mutex_lock(&io->mu);
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

void k3_io_set_active(K3IO *io, int tier, int group)
{
    if (group < 0) group = 0;
    if (group >= K3_IO_MAX_GROUPS) group = K3_IO_MAX_GROUPS - 1;
    pthread_mutex_lock(&io->mu);
    io->active_group[tier] = group;
    pthread_cond_broadcast(&io->cv[tier]);
    pthread_mutex_unlock(&io->mu);
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
    /* Route the write to the CURRENT active group, not a hardcoded 0. Phase-2
     * hold parks the trunk group (active_group[0]=1): an L2-miss refill write
     * staying in group 0 would queue behind the parked trunk and never be
     * drained, deadlocking the pool (gateAB_085122). Inside the window the write
     * joins group 1 (drained by the L2 burst); outside it falls back to group 0.
     *
     * Pinned hard to group 1 (tried as v6_l2g1rw): the L2 hit reads live in group 0,
     * so a write parked in group 1 waits on a group nothing drains and the pool wedges
     * at startup. active_group is the correct target -- with the hold unmounted it is
     * always 0, i.e. the same group the hit reads use. */
    const int g = io->active_group[tier];
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