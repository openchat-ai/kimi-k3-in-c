#ifndef K3_IO_H
#define K3_IO_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <pthread.h>

/* Unified media-tier I/O scheduler.
 *
 * Every disk read in the engine (trunk streaming, expert L2 hit, expert
 * slow-checkpoint miss, embed) goes through one module that queues requests
 * PER MEDIUM TIER. Tiers are abstract -- the caller names them at init and maps
 * each device (NVMe, HDD, RAM, network volume) to a tier number -- so the module
 * carries no medium name of its own. Physically separate devices (e.g. sdd7 vs
 * the slow checkpoint) get different tiers with independent worker pools, so a
 * slow tier can never stall a fast one -- the old "gate" parked the whole trunk
 * reader during an expert burst, treating two devices as one, and over-yielded:
 * measured, the trunk parked 382 s to let 153 s of slow-disk misses through.
 *
 * Within a tier, requests queue FIFO and drain by a pool of workers; a fast tier
 * gets several workers so sequential and parallel streams share its bandwidth
 * concurrently, a slow tier gets a few (a HDD measures ~2.6x single-stream rate
 * at 4-way parallelism; more saturates). Callers submit (tier, fd, off, n, dst)
 * and wait for completion. Writes submit through k3_io_submit_write and share the
 * same pools.
 */

#define K3_IO_MAX_TIERS 8
#define K3_IO_MAX_WORKERS 32   /* per-tier worker-pool cap; init clamps to this */
#define K3_IO_MAX_GROUPS 4     /* per-tier request groups (0=default/trunk, 1=L2) */

typedef struct K3IOReq {
    struct K3IOReq *next;
    int      tier;
    int      group;             /* which group's FIFO this request sits in */
    int      fd;
    off_t    offset;
    size_t   nbytes;
    unsigned char *dst;          /* read: pread fills dst; write: pwrite drains dst */
    int      write;              /* 1 = pwrite, 0 = pread */
    /* Optional chunked multi-read: when chunk > 0 the worker reads the WHOLE
     * [offset, offset+nbytes) span as consecutive `chunk`-byte preads instead of
     * one pread. This is how a sequential stream (trunk layer) avoids a
     * submit/wait round-trip per chunk. */
    size_t   chunk;
    ssize_t  rc;
    int      done;            /* 1 when the worker finished (rc valid) */
    /* When the request was handed to the pool, so the worker can time how long it sat in
     * the queue before anyone picked it up. Queue time is the difference between "the drive
     * is slow" and "the drive was never asked", and only the request can carry the answer
     * back: the pool has no other way to know how long a given request was waiting. */
    double   t_sub;
    pthread_mutex_t mu;       /* per-request completion lock */
    pthread_cond_t  cv;
} K3IOReq;

typedef struct K3IO {
    pthread_t   thread[K3_IO_MAX_TIERS][K3_IO_MAX_WORKERS];
    pthread_mutex_t mu;
    pthread_cond_t  cv[K3_IO_MAX_TIERS];     /* one condvar PER TIER so a submit
                                                wakes only that tier's workers */
    int         stop;
    /* Per-group FIFO per tier, so a burst on one group (the L2 expert reads) can be
     * queued separately from the other (the trunk stream). Groups are NOT time-sliced:
     * every worker drains all non-empty groups round-robin (see rr[] below), so both
     * streams are in flight at once. An earlier active_group[] plus k3_io_set_active()
     * did time-slice them, on the theory that 1.3 GB/s shared beats each stream at half
     * speed -- measured worth 0-3 s per run, and it deadlocked whenever group 1 was
     * used with it unmounted. Removed; the round-robin drain is what replaced it. */
    K3IOReq    *q[K3_IO_MAX_TIERS][K3_IO_MAX_GROUPS];
    K3IOReq    *qtail[K3_IO_MAX_TIERS][K3_IO_MAX_GROUPS];
    /* Round-robin cursor over the groups, bumped under mu. Workers start their scan
     * here instead of always at group 0: the trunk stream keeps group 0 permanently
     * non-empty, so an "active group first, fall back when empty" rule never reaches
     * the fallback and both streams end up served in turns. Rotating the start point
     * spreads workers across whichever queues have work, which is what lets the
     * trunk stream (group 0) and the L2 burst (group 1) be in flight together. */
    int         rr[K3_IO_MAX_TIERS];
    int         nworkers[K3_IO_MAX_TIERS]; /* workers per tier */
    int         ntiers;
    /* Where the time goes, per tier. The decisive number is stat_bytes / stat_pread_s: if
     * that is the drive's rate under the same access pattern, the drive is not the limit
     * and the time is in the queue. The two queues are separated because the two streams
     * behave nothing alike -- the trunk stream is one request for a whole 600 MB layer,
     * expert reads are one 17.5 MB slot each -- and a combined total would hide which one
     * is starving. Cumulative across worker threads, so divide by the observed wall to get
     * concurrency, and by nothing at all to get per-device rate.
     *
     * Every field here was a plain += from 16 worker threads with no atomics. That is a data
     * race and not a measurement. The v52 run that produced the day's 51% figure was read
     * through these; the conclusion survived only because dd measured the same thing
     * independently (v55) and agreed to within a few percent. The race was invisible, not
     * harmless -- fix it rather than trusting a plausible number.
     *
     * Times are integer nanoseconds, not double, because GCC's __atomic_add_fetch has no
     * double overload and a CAS loop over bit patterns is a much easier thing to get
     * subtly wrong than a scale factor. 243 s is 2.4e11 ns, far inside uint64. */
#define K3_STAT_ADD_U64(p, v) __atomic_add_fetch((p), (uint64_t)(v), __ATOMIC_RELAXED)
#define K3_STAT_GET_U64(p)     __atomic_load_n((p), __ATOMIC_RELAXED)
    uint64_t    stat_reqs[K3_IO_MAX_TIERS];
    uint64_t    stat_bytes[K3_IO_MAX_TIERS];
    uint64_t    stat_pread_ns[K3_IO_MAX_TIERS];  /* summed across workers */
    uint64_t    stat_queue_ns[K3_IO_MAX_TIERS];  /* submit -> dequeue */
    uint64_t    stat_submit_ns[K3_IO_MAX_TIERS]; /* inside submit_g, under the lock */
    uint64_t    stat_lock_ns[K3_IO_MAX_TIERS];   /* worker waiting for io->mu */
    /* Time actually spent asleep in pthread_cond_wait. The old stat_idle_s sampled only the
     * instant a worker found every queue empty -- the time spent deciding to sleep, not the
     * time spent sleeping. It reported 0.1 s against 243 s of wall, which is why the day's
     * 49%-idle figure had to be derived by subtracting the other counters instead of read. */
    uint64_t    stat_sleep_ns[K3_IO_MAX_TIERS];
    uint64_t    stat_sleep_n[K3_IO_MAX_TIERS];   /* count of sleeps, to check the sum */
    /* Per group. Aggregating a 600 MB sequential trunk request with a 17.5 MB scattered
     * expert read into one number describes neither, and hides which stream is starving. */
    uint64_t    stat_reqs_g[K3_IO_MAX_TIERS][K3_IO_MAX_GROUPS];
    uint64_t    stat_bytes_g[K3_IO_MAX_TIERS][K3_IO_MAX_GROUPS];
    uint64_t    stat_pread_ns_g[K3_IO_MAX_TIERS][K3_IO_MAX_GROUPS];
    uint64_t    stat_queue_ns_g[K3_IO_MAX_TIERS][K3_IO_MAX_GROUPS];
    /* Failed requests. Bytes are counted only on success: the old code added r->nbytes
     * unconditionally, so a short or failed read still counted as delivered and the
     * reported rate would be one the drive never achieved. */
    uint64_t    stat_fail[K3_IO_MAX_TIERS];
    double      t_start_s;                       /* wall when the first request was queued */
} K3IO;

/* io: module state. tiers: number of medium tiers. workers: array of worker
 * counts, one per tier (e.g. {4,1} for a fast NVMe tier and a slow HDD tier).
 * Counts are clamped to [1, K3_IO_MAX_WORKERS]; a NULL workers array means 1
 * everywhere. */
void  k3_io_init(K3IO *io, int tiers, const int *workers);
void  k3_io_free(K3IO *io);
/* Print the per-tier breakdown of where the pool's time went. Call before k3_io_free, which
 * joins the workers; the figures are cumulative across them either way. */
void  k3_io_report(const K3IO *io);
/* Submit one read (or a chunked span) on a tier+group; returns a request to wait
 * on. When chunk > 0, the worker reads the whole [off, off+nbytes) as consecutive
 * `chunk`-byte preads -- one completion for the whole span. */
K3IOReq *k3_io_submit_g(K3IO *io, int tier, int group, int fd, off_t off,
                        size_t nbytes, size_t chunk, void *dst);
K3IOReq *k3_io_submit(K3IO *io, int tier, int fd, off_t off,
                      size_t nbytes, size_t chunk, void *dst); /* group 0 */
/* Submit one write (pwrite of nbytes from src to fd at off); single completion.
 * Writes join group 0, where the L2 refill writes and the trunk stream already are. */
K3IOReq *k3_io_submit_write(K3IO *io, int tier, int fd, off_t off,
                            size_t nbytes, const void *src);
/* Block until the request completes. Returns the pread/pwrite result (bytes
 * transferred, or <0). */
ssize_t k3_io_wait(K3IOReq *req);

#endif /* K3_IO_H */