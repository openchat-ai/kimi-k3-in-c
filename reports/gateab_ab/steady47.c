/* Measure the device over the engine's window, not a probe's window.
 *
 * Every comparison today has been between two different windows. The engine's own hit-I/O
 * ledger integrates 179.74 GB over 409.18 s of continuous work -- a steady state, with the
 * drive thermally soaked and its cache long since collapsed. My probes measured 23 GB
 * bursts of four seconds -- cache-warm, cold NAND. Quoting a 6.2x gap between those is
 * comparing a 400-second reliable number against a 4-second unreliable one, and at least
 * some of the seven explanations I eliminated this morning were explaining an artefact of
 * that mismatch rather than anything real.
 *
 * So: read continuously for as long as the engine read, report the rate over the whole run
 * and in fixed segments so the trajectory is visible. If the rate falls and stays down, the
 * engine's 439 MB/s is a steady-state number and the gap is smaller than claimed. If it
 * holds at multi-GB/s throughout, the gap is real and the difference is between steady state
 * and burst.
 *
 * No burst structure, no pauses, no per-arm interleaving -- those were what made every
 * earlier probe drift. One continuous stream, segmented for reporting only. 409 s at even
 * 1 GB/s is 409 GB, which the 14589-slot file can supply twice over, so the run is bounded
 * by time rather than by data.
 */
#include "k3_io.h"

#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define L2     "/mnt/nvme/experts.l2"
#define NSLOT  14589
#define SLOT   17547264
#define NTH    11
#define SEG_S  20                    /* report every 20 s */
/* Coprime with NSLOT=14589 (14589 = 3 * 11 * 13 * 31, so 89 = 89 is coprime with it; 89 is
 * chosen because it is prime and shares no factor with 14589). Verified at startup. */
#define STRIDE 89

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
    /* The stride must be coprime with the slot count, or the walk visits only a subset and
     * eventually steps past the last slot. Asserted here because the alternative is a probe
     * that reads 11 slots and then silently stops. */
    if (gcd(STRIDE, NSLOT) != 1) {
        fprintf(stderr, "STRIDE %d is not coprime with NSLOT %d\n", STRIDE, NSLOT);
        exit(1);
    }
    /* And the orbit must stay in range over a full lap. */
    {
        long p = 0;
        for (int i = 0; i < NSLOT; i++) { p += STRIDE; while (p >= NSLOT) p -= NSLOT; }
        if (p != 0) { fprintf(stderr, "stride orbit does not close: %ld\n", p); exit(1); }
    }
}

static volatile int g_short, g_stop;
static double g_t0;

typedef struct { int fd; long base; void *buf; int idx; } Arg;

/* Each lane publishes its own completed-slot count so the reporter can integrate
 * throughput while the run is still going. A relaxed atomic load of a long can tear, which
 * is fine: the reporting window is 20 s wide, so a few slots do not move the figure, and
 * the only number that must be exact is the end-of-run total. */
static long g_counts[16];

static void *lane(void *p)
{
    Arg *a = (Arg *)p;
    long s = a->base;
    long done = 0;
    while (!g_stop) {
        ssize_t n = pread(a->fd, a->buf, SLOT, (off_t)s * SLOT);
        if (n != SLOT) {
            if (g_short < 5)
                fprintf(stderr, "SHORT lane=%d done=%ld slot=%ld off=%lld n=%zd errno=%d %s\n",
                        a->idx, done, s, (long long)((off_t)s * SLOT), n, errno,
                        n < 0 ? strerror(errno) : "(no error: read past EOF)");
            g_short++;
            break;
        }
        /* Step by a value coprime with NSLOT, and bound-check rather than wrapping.
         * `s = (s + 89) % NSLOT` after an `if (s >= NSLOT) s -= NSLOT` guard is the bug:
         * the stride orbit does not divide 14589 evenly, so the walk runs off the end and
         * every read past the last slot returns 0. The first short-run of this probe died
         * after 11 slots, which is exactly one thread's worth before it walked out. */
        s += STRIDE;
        while (s >= NSLOT) s -= NSLOT;
        done++;
        if ((done & 0x3F) == 0)
            __atomic_store_n(&g_counts[a->idx], done, __ATOMIC_RELAXED);
    }
    __atomic_store_n(&g_counts[a->idx], done, __ATOMIC_RELAXED);
    return NULL;
}

int main(int argc, char **argv)
{
    double run_s = (argc > 1) ? atof(argv[1]) : 420.0;
    check_geometry();

    int fd = open(L2, O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open"); return 1; }
    void *buf[16];
    for (int i = 0; i < NTH; i++) {
        buf[i] = mmap(NULL, SLOT, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (buf[i] == MAP_FAILED) { perror("mmap"); return 1; }
    }

    pthread_t th[16];
    /* The Arg array must outlive every thread. Declared inside the loop, its storage is
     * reclaimed on the last iteration and the last-spawned lane -- which is also the one
     * still running -- reads a clobbered fd. That surfaced as EBADF on lane 10 only, which
     * looked like a read-past-EOF and was not. */
    Arg args[16];
    for (int i = 0; i < NTH; i++) {
        args[i].fd = fd;
        args[i].base = (long)((i * 137) % NSLOT);
        args[i].buf = buf[i];
        args[i].idx = i;
        pthread_create(&th[i], NULL, lane, &args[i]);
    }

    printf("geometry: nslot=%d slot=%d, %d threads, continuous, target %.0f s\n",
           NSLOT, SLOT, NTH, run_s);
    printf("engine's ledger for comparison: 179.74 GB in 409.18 s = 439 MB/s\n");
    printf("  %8s %10s %12s %12s\n", "t(s)", "seg MB/s", "cumul GB", "running MB/s");
    fflush(stdout);

    long prev = 0;
    double t0 = now_s(), seg0 = t0, wall0 = t0;
    for (;;) {
        sleep(1);
        double t = now_s() - t0;
        if (t >= run_s || g_short) break;
        if (t - (seg0 - t0) >= SEG_S) {
            long total = 0;
            for (int i = 0; i < NTH; i++)
                total += __atomic_load_n(&g_counts[i], __ATOMIC_RELAXED);
            double dseg = (total - prev) * (double)SLOT / 1e6;
            double seg_rate = dseg / (t - (seg0 - t0));
            printf("  %8.0f %10.0f %12.1f %12.0f\n",
                   t, seg_rate, total * (double)SLOT / 1e9, dseg / t);
            fflush(stdout);
            prev = total;
            seg0 = now_s();
        }
    }
    g_stop = 1;
    for (int i = 0; i < NTH; i++) pthread_join(th[i], NULL);

    long total = 0;
    for (int i = 0; i < NTH; i++) total += g_counts[i];
    double wall = now_s() - wall0;
    double gb = total * (double)SLOT / 1e9;

    printf("\n=== whole run\n");
    printf("   %ld slots read, %.1f GB in %.1f s = %.0f MB/s\n",
           total, gb, wall, gb * 1000.0 / wall);
    printf("   engine: 439 MB/s over 409 s  ->  ratio %.2fx\n", (gb * 1000.0 / wall) / 439.0);
    if (g_short) printf("   ABORTED: short read\n");

    for (int i = 0; i < NTH; i++) munmap(buf[i], SLOT);
    close(fd);
    return g_short ? 1 : 0;
}
