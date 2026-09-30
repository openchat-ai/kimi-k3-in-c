/* Isolate the kio hop: the one component every measurement today has gone through without
 * measuring.
 *
 * v40 issues its preads from the calling thread and gets 2723 MB/s at R=11, IQR 0.039, on
 * the engine's exact geometry with the device cache preconditioned. The engine's own hit-I/O
 * ledger, reading the same file with the same O_DIRECT fd, says 439 MB/s. 6.2x.
 *
 * Six explanations are now excluded with data: page cache, device cache (v39), burst size
 * and concurrency (v40, flat from R=4 while the engine already sustains 11.4x), phase-1
 * serialisation (0.13 s over a 70 s run), refill writes (misses 0, written 0.00 GB), and
 * trunk contention (0.35-1.85 s of wall). What differs between v40 and the engine is that
 * v40 calls pread and the engine calls k3_io_submit_g, which queues onto 16 kio workers and
 * is then waited on.
 *
 * v27 was supposed to settle this by bypassing kio (K3_L2_NATIVE) and read 408 against a
 * 418 control. A 6x effect does not vanish into an 11.6% band, so that pair is not
 * trustworthy in at least one of its two arms. This measures the hop head-on instead of by
 * subtraction: same file, same fd, same O_DIRECT, same offsets, same read size, same thread
 * count, same total bytes. The only difference between arms is whether pread is called by
 * the requesting thread or by a pool worker.
 *
 * The worker's own accounting is the other half of the question. The engine's ledger says
 * 38 MB/s per thread: 16 workers at that is 608 MB/s, above the 439 MB/s actually observed,
 * which means the workers are not being kept busy. Arms C and D vary the worker count to see
 * whether the pool is the limit or the request pattern is.
 */
#include "k3_io.h"

#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define L2        "/mnt/nvme/experts.l2"
/* 14589, not 17096. experts.l2 is 255997034496 bytes and 255997034496/17547264 = 14589.
 * The engine prints this at startup as "expert L2 exact: nslot=...". The first version of
 * this probe hardcoded 17096, which is what a 300 GB file would hold, so every read past
 * slot 14588 returned 0 and all five arms came back 0 MB/s. check_geometry() below asserts
 * the value against the file size so it cannot drift again silently. */
#define NSLOT     14589
#define SLOT      17547264
#define ROUNDS    120

static void check_geometry(void)
{
    struct stat stt;
    if (stat(L2, &stt) != 0) { perror("stat " L2); exit(1); }
    long slots = (long)stt.st_size / SLOT;
    if (slots != NSLOT) {
        fprintf(stderr, "NSLOT is %d but the file holds %ld slots (%ld bytes). "
                        "Fix it; do not run with a stale count.\n",
                NSLOT, slots, (long)stt.st_size);
        exit(1);
    }
    if (SLOT % 4096) { fprintf(stderr, "SLOT not page aligned\n"); exit(1); }
}

/* Was `ts.tv_nsec * 1e9 / 1e9`, which is ts.tv_nsec added straight to tv_sec. The
 * magnitude came out around 1e6 and the difference between two calls was dominated by the
 * nanosecond field, which produced wall times like 390622116 s and made every arm read
 * 0 MB/s. That, not the stale NSLOT, is what made v42 look like a result. Fixed to the
 * intended `* 1e-9`; check_clock() below asserts the unit so it cannot recur. */
static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* A clock that returns seconds must tick forward by a sane amount. A one-second sleep must
 * measure as roughly one second, not as 1e6 or 1e-6. */
static void check_clock(void)
{
    double a = now_s();
    struct timespec ts = { 0, 200 * 1000 * 1000 };   /* 200 ms */
    nanosleep(&ts, NULL);
    double d = now_s() - a;
    if (d < 0.05 || d > 2.0) {
        fprintf(stderr, "now_s() is not in seconds: a 200 ms sleep measured as %.6f s\n", d);
        exit(1);
    }
}

typedef struct {
    int       fd;
    int       nthreads;
    int       workers;      /* 0 = direct pread, no kio */
    K3IO     *io;
    long      base;
    void     *buf;
    long     *done;
    double   *tread;        /* per-thread cumulative pread-equivalent time */
} Arg;

/* Direct arm: the requesting thread issues its own pread. */
static volatile int g_short;   /* a short read anywhere aborts the arm: a partial or
                                 * zero-length read inflates the rate, because the bytes
                                 * never moved but the clock did. The first run of this
                                 * probe produced five arms of 0 MB/s for exactly that
                                 * reason and looked, at a glance, like a real result. */

static void *direct_worker(void *p)
{
    Arg *a = (Arg *)p;
    long s = a->base;
    double acc = 0.0;
    for (int r = 0; r < ROUNDS; r++) {
        if (s >= NSLOT) s -= NSLOT;
        double t0 = now_s();
        ssize_t n = pread(a->fd, a->buf, SLOT, (off_t)s * SLOT);
        acc += now_s() - t0;
        if (n != SLOT) { g_short++; break; }
        s = (s + 89) % NSLOT;
    }
    a->tread[0] = acc;
    a->done[0] = ROUNDS;
    return NULL;
}

/* kio arm: submit, then block until the pool completes it. Exactly the engine's shape --
 * k3_l2_load_direct calls k3_io_submit_g then k3_io_wait. */
static void *kio_worker(void *p)
{
    Arg *a = (Arg *)p;
    long s = a->base;
    double acc = 0.0;
    for (int r = 0; r < ROUNDS; r++) {
        if (s >= NSLOT) s -= NSLOT;
        double t0 = now_s();
        K3IOReq *q = k3_io_submit_g(a->io, 0, 1, a->fd, (off_t)s * SLOT,
                                    SLOT, 0, a->buf);
        if (!q) { g_short++; break; }
        ssize_t n = k3_io_wait(q);
        acc += now_s() - t0;
        if (n != SLOT) { g_short++; break; }
        s = (s + 89) % NSLOT;
    }
    a->tread[0] = acc;
    a->done[0] = ROUNDS;
    return NULL;
}

static double run_arm(int nthreads, int workers, int fd, long base, void *buf)
{
    K3IO io;
    K3IO *p = &io;
    int nw[1] = { workers };
    if (workers > 0) k3_io_init(&io, 1, nw);

    pthread_t th[32];
    long  *done = (long *)calloc(nthreads, sizeof(long));
    double *tr = (double *)calloc(nthreads, sizeof(double));
    Arg  *args = (Arg *)calloc(nthreads, sizeof(Arg));

    double t0 = now_s();
    for (int i = 0; i < nthreads; i++) {
        args[i].fd = fd;
        args[i].nthreads = nthreads;
        args[i].workers = workers;
        args[i].io = &io;
        args[i].base = (base + i * 137) % NSLOT;
        args[i].buf = buf;
        args[i].done = &done[i];
        args[i].tread = &tr[i];
        pthread_create(&th[i], NULL, workers > 0 ? kio_worker : direct_worker, &args[i]);
    }
    for (int i = 0; i < nthreads; i++) pthread_join(th[i], NULL);
    double wall = now_s() - t0;

    long slots = 0;
    double tread = 0.0;
    for (int i = 0; i < nthreads; i++) { slots += done[i]; tread += tr[i]; }
    if (workers > 0) k3_io_free(&io);
    free(done); free(tr); free(args);

    double mb = (double)slots * SLOT / 1e6;
    if (g_short) {
        printf("   threads=%2d workers=%2d  ABORTED: %d short read(s) -- bytes did not "
               "move but the clock did, so the rate would be fiction\n",
               nthreads, workers, g_short);
        g_short = 0;
        if (workers > 0) k3_io_free(&io);
        free(done); free(tr); free(args);
        return -1.0;
    }
    printf("   threads=%2d workers=%2d  wall %6.2f s  %6.0f MB/s  "
           "(in-request %6.0f MB/s, concurrency %5.2fx)\n",
           nthreads, workers, wall, mb / wall, mb / tread, tread / wall);
    return mb / wall;
}

static int cmp(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(void)
{
    check_geometry();
    check_clock();
    int fd = open(L2, O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open " L2); return 1; }
    void *buf = mmap(NULL, SLOT, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) { perror("mmap"); return 1; }

    printf("geometry: slot=%d aligned=%d, %d rounds/arm, %.1f MB per arm\n\n",
           SLOT, SLOT % 4096 == 0, ROUNDS,
           (double)ROUNDS * 11 * SLOT / 1e6);

    /* A: direct pread, 11 threads -- what v40 did.
     * B: the same through kio with 16 workers, 11 requesters -- what the engine does.
     * C/D: vary the pool to see whether the pool size or the pattern is the limit. */
    struct { const char *name; int nth; int wk; } arms[] = {
        { "A  direct pread, 11 threads      (v40's shape)", 11, 0 },
        { "B  via kio, 11 requesters, 16 workers (engine)",  11, 16 },
        { "C  via kio, 11 requesters,  4 workers",         11,  4 },
        { "D  via kio, 11 requesters, 32 workers",         11, 32 },
        { "E  via kio, 16 requesters, 16 workers",         16, 16 },
    };
    const int NARMS = (int)(sizeof arms / sizeof arms[0]);
    const int NREP  = 5;
    double *res = (double *)calloc(NARMS * NREP, sizeof(double));

    for (int r = 0; r < NREP; r++) {
        for (int a = 0; a < NARMS; a++) {
            printf("  rep %d  %s\n", r + 1, arms[a].name);
            res[a * NREP + r] = run_arm(arms[a].nth, arms[a].wk, fd, 4096 * (r + 1), buf);
            usleep(200000);
        }
    }

    printf("\n=== results, MB/s, n=%d, interleaved\n", NREP);
    printf("   %-44s %8s %8s %9s %10s\n",
           "arm", "median", "min", "IQR/med", "vs direct");
    for (int a = 0; a < NARMS; a++) {
        double v[16];
        for (int r = 0; r < NREP; r++) v[r] = res[a * NREP + r];
        qsort(v, NREP, sizeof(double), cmp);
        double med = v[NREP / 2];
        double q1 = v[NREP / 4], q3 = v[(3 * NREP) / 4];
        double iqr = (q3 - q1) / med;
        double direct_med = 0.0;
        for (int r = 0; r < NREP; r++) direct_med = res[r];
        /* median of arm A */
        double a0[16];
        for (int r = 0; r < NREP; r++) a0[r] = res[r];
        qsort(a0, NREP, sizeof(double), cmp);
        printf("   %-44s %8.0f %8.0f %9.3f %9.2fx%s\n",
               arms[a].name, med, v[0], iqr, med / a0[NREP / 2],
               iqr > 0.15 ? "   NOISY" : "");
        (void)direct_med;
    }
    printf("\n   engine's own hit I/O ledger :  439 MB/s\n");
    printf("   v40 direct pread, R=11      : 2723 MB/s\n");

    munmap(buf, SLOT);
    close(fd);
    free(res);
    return 0;
}
