/* Does the engine's per-layer pause explain the 6x, or is the device genuinely slower?
 *
 * v47 settled the comparison I had been getting wrong all morning: over 420 s of continuous
 * reading, the same 11 threads, the same file, O_DIRECT, the drive gives 2610 MB/s against
 * the engine's 439. Five-ninety-five times is not a 4-second-burst-versus-400-second-window
 * artefact. The curve was flat end to end, 1740 to 3088 with no downward trend.
 *
 * So the remaining difference between the two workloads is structure. v47 reads without
 * stopping. The engine does not: it issues roughly 14 slots for a layer, then does that
 * layer's arithmetic before issuing the next layer's. That arithmetic is hidden under the
 * reads in the v41 trace -- the expert union is 100% contained inside the compute union --
 * so it should not cost anything, unless the next layer's requests are not issued until the
 * previous layer's compute retires, in which case the drive is left with nothing queued for
 * the duration of every layer's arithmetic.
 *
 * That is the hypothesis, and it is falsifiable. Same 11 threads, same 420 s, same stride,
 * but with a pause inserted after every burst of B rounds. Four pause lengths, from nothing
 * to three times the engine's own per-layer arithmetic (14.85 s of pure arithmetic over 93
 * layers is 0.16 s per layer). If the rate collapses toward 439 as the pause grows, the
 * engine is starving its own device and the fix is structural. If it barely moves, the pause
 * is not the explanation and the 6x is elsewhere.
 *
 * B is 14, from the engine's own ledger: 22.5 GB of expert reads per token over 93 layers is
 * about 14 slots of 17547264 bytes per layer.
 */
#include "k3_io.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define L2     "/mnt/nvme/experts.l2"
#define NSLOT  14589
#define SLOT   17547264
#define NTH    11
#define BURST  14                  /* slots per burst ~= one layer's expert batch */
#define STRIDE 89
#define RUN_S  100.0                /* per arm; 4 arms = ~7 min, the shape is what matters,
                                     * not the absolute byte count, because v47 already
                                     * established the 420 s rate is flat */

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static long gcd(long a, long b) { while (b) { long t = a % b; a = b; b = t; } return a; }

static void check_geometry(void)
{
    struct stat s;
    if (stat(L2, &s) != 0) { perror("stat"); exit(1); }
    long n = (long)s.st_size / SLOT;
    if (n != NSLOT || SLOT % 4096) {
        fprintf(stderr, "geometry mismatch: %ld slots, want %d\n", n, NSLOT);
        exit(1);
    }
    if (gcd(STRIDE, NSLOT) != 1) {
        fprintf(stderr, "STRIDE %d not coprime with NSLOT %d\n", STRIDE, NSLOT);
        exit(1);
    }
    { long p = 0; for (int i = 0; i < NSLOT; i++) { p += STRIDE; while (p >= NSLOT) p -= NSLOT; }
      if (p != 0) { fprintf(stderr, "stride orbit does not close\n"); exit(1); } }
}

static void check_clock(void)
{
    double a = now_s();
    struct timespec ts = { 0, 200 * 1000 * 1000 };
    nanosleep(&ts, NULL);
    double d = now_s() - a;
    if (d < 0.05 || d > 2.0) {
        fprintf(stderr, "now_s() not in seconds: 200 ms measured as %.6f\n", d);
        exit(1);
    }
}

static volatile int g_short, g_stop;
static long g_counts[NTH];
static double g_pause;          /* seconds between bursts, set before threads start */
static long   g_t0_ms;          /* start epoch, so every worker uses the same deadline */

typedef struct { int fd; long base; void *buf; int idx; } Arg;

static void *lane(void *p)
{
    Arg *a = (Arg *)p;
    long s = a->base;
    long done = 0;
    while (!g_stop) {
        /* One burst, then the layer's arithmetic. */
        for (int r = 0; r < BURST; r++) {
            ssize_t n = pread(a->fd, a->buf, SLOT, (off_t)s * SLOT);
            if (n != SLOT) {
                if (g_short < 5)
                    fprintf(stderr, "SHORT lane=%d done=%ld slot=%ld n=%zd errno=%d %s\n",
                            a->idx, done, s, n, errno,
                            n < 0 ? strerror(errno) : "(no error: past EOF)");
                g_short = 1;
                return NULL;
            }
            s += STRIDE;
            while (s >= NSLOT) s -= NSLOT;
            done++;
        }
        __atomic_store_n(&g_counts[a->idx], done, __ATOMIC_RELAXED);
        if (g_pause > 0) {
            /* All 11 lanes sleep the same wall duration after the same number of rounds, so
             * they resume together the way the engine's 16 do. This is deliberately a plain
             * relative sleep, not an absolute deadline: the question is what the DEVICE sees
             * when it goes idle for P seconds between bursts, and an absolute schedule would
             * silently absorb the read time into the pause and answer a different question. */
            struct timespec d = { (time_t)g_pause,
                                  (long)((g_pause - (long)g_pause) * 1e9) };
            nanosleep(&d, NULL);
        }
    }
    __atomic_store_n(&g_counts[a->idx], done, __ATOMIC_RELAXED);
    return NULL;
}

/* One arm: run for RUN_S with the given pause, report the whole-run rate. The buffer
 * array is passed as a pointer to its first element, not as void*[16]: a parameter declared
 * void *buf[16] decays to void **, and the compiler flagged the 128-vs-88 mismatch. */
static double arm(double pause, int fd, void **buf, long seed)
{
    g_pause = pause;
    g_stop = 0;
    g_short = 0;
    for (int i = 0; i < NTH; i++) __atomic_store_n(&g_counts[i], 0, __ATOMIC_RELAXED);

    pthread_t th[NTH];
    Arg args[NTH];                       /* must outlive every thread */
    for (int i = 0; i < NTH; i++) {
        args[i].fd = fd;
        args[i].base = (long)((seed + i * 137) % NSLOT);
        args[i].buf = buf[i];
        args[i].idx = i;
        pthread_create(&th[i], NULL, lane, &args[i]);
    }
    double t0 = now_s();
    while (now_s() - t0 < RUN_S && !g_short) usleep(200000);
    g_stop = 1;
    for (int i = 0; i < NTH; i++) pthread_join(th[i], NULL);
    double wall = now_s() - t0;

    long total = 0;
    for (int i = 0; i < NTH; i++) total += g_counts[i];
    double gb = total * (double)SLOT / 1e9;
    double rate = gb * 1000.0 / wall;
    printf("   pause %5.2f s  %8.1f GB in %6.1f s = %6.0f MB/s   %s\n",
           pause, gb, wall, rate, g_short ? "(ABORTED short read)" : "");
    fflush(stdout);
    return rate;
}

int main(void)
{
    check_geometry();
    check_clock();
    int fd = open(L2, O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open"); return 1; }
    void *buf[NTH];
    for (int i = 0; i < NTH; i++) {
        buf[i] = mmap(NULL, SLOT, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (buf[i] == MAP_FAILED) { perror("mmap"); return 1; }
    }

    printf("geometry: nslot=%d slot=%d, %d threads, burst=%d rounds, %.0f s per arm\n",
           NSLOT, SLOT, NTH, BURST, RUN_S);
    printf("engine: 439 MB/s. Its arithmetic is 14.85 s / 93 layers = 0.16 s per layer.\n\n");

    const double pauses[4] = { 0.0, 0.16, 0.32, 0.48 };
    double res[4];
    for (int i = 0; i < 4; i++) res[i] = arm(pauses[i], fd, buf, 4096 + 2000 * i);

    printf("\n=== summary\n");
    printf("   %-12s %10s %12s\n", "pause", "MB/s", "vs engine");
    for (int i = 0; i < 4; i++)
        printf("   %-12.2f %10.0f %11.2fx\n", pauses[i], res[i], res[i] / 439.0);
    printf("\n   v47, no pause at all, 420 s continuous : 2610 MB/s (5.95x)\n");

    for (int i = 0; i < NTH; i++) munmap(buf[i], SLOT);
    close(fd);
    return 0;
}
