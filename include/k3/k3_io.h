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
 * concurrently, a slow tier gets one. Callers submit (tier, fd, off, n, dst) and
 * wait for completion.
 */

#define K3_IO_MAX_TIERS 8

typedef struct K3IOReq {
    struct K3IOReq *next;
    int      tier;
    int      fd;
    off_t    offset;
    size_t   nbytes;
    unsigned char *dst;
    /* Optional chunked multi-read: when chunk > 0 the worker reads the WHOLE
     * [offset, offset+nbytes) span as consecutive `chunk`-byte preads instead of
     * one pread. This is how a sequential stream (trunk layer) avoids a
     * submit/wait round-trip per chunk. */
    size_t   chunk;
    ssize_t  rc;
    int      done;            /* 1 when the worker finished (rc valid) */
    pthread_mutex_t mu;       /* per-request completion lock */
    pthread_cond_t  cv;
} K3IOReq;

typedef struct K3IO {
    pthread_t   thread[K3_IO_MAX_TIERS][8];  /* per-tier worker pool */
    pthread_mutex_t mu;
    pthread_cond_t  cv[K3_IO_MAX_TIERS];     /* one condvar PER TIER so a submit
                                                wakes only that tier's workers */
    int         stop;
    K3IOReq    *q[K3_IO_MAX_TIERS];      /* FIFO head per tier */
    K3IOReq    *qtail[K3_IO_MAX_TIERS];  /* FIFO tail per tier */
    int         nworkers[K3_IO_MAX_TIERS]; /* workers per tier */
    int         ntiers;
} K3IO;

/* io: module state. tiers: number of medium tiers. workers: array of worker
 * counts, one per tier (e.g. {4,1} for a fast NVMe tier and a slow HDD tier). */
void  k3_io_init(K3IO *io, int tiers, const int *workers);
void  k3_io_free(K3IO *io);
/* Submit one read (or a chunked span) on a tier; returns a request to wait on.
 * When chunk > 0, the worker reads the whole [off, off+nbytes) as consecutive
 * `chunk`-byte preads -- one completion for the whole span. */
K3IOReq *k3_io_submit(K3IO *io, int tier, int fd, off_t off,
                      size_t nbytes, size_t chunk, void *dst);
/* Block until the request completes. Returns the pread result (bytes read, or <0). */
ssize_t k3_io_wait(K3IOReq *req);

#endif /* K3_IO_H */