/* Is the 3.4x round-to-round drift in time, or in which part of the file was read?

 * v44 produced, for one arm: 6291 / 2484 / 1840 / 2823 / 4382 MB/s. The five arms within a
 * round agreed closely, so the drift is at round granularity, and every arm in a round
 * shared it. My own design confounded it: run_arm was called with base = 4096 * (r + 1), so
 * each round started 4096 slots -- 71.8 GB -- further into the file. 4096 is the page size,
 * so the "randomisation" was a constant-stride walk across the whole 256 GB, and the five
 * rounds read five unrelated regions. Whatever varies by region and whatever varies with
 * time were added together and called "drift".
 *
 * This separates them. Series 1 repeats one fixed base, so its spread is time alone.
 * Series 2 walks six different bases, so its spread is time plus region. If series 2 is
 * much wider, the drive's speed depends on where in the file you are reading, which would
 * also invalidate every earlier probe that picked one base and moved on.
 *
 * Six samples each rather than three, because a 3.4x spread estimated from three points is
 * not a spread. Every base is printed so the walk is reproducible.
 */
#include "k3_io.h"

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
#define ROUNDS 120          /* rounds per batch */
#define NBATCH 6            /* batches per measurement -> 720 rounds, finer localisation */
#define NREP   6
#define NTH    11

/* Every sample line carries a wall-clock stamp so it can be lined up against the host's
 * PhysicalDisk counters, which sample once a second on the other side of the hypervisor.
 * v38 showed the host sees things the guest cannot, and the whole point here is to catch a
 * collapse in the act. */
static void stamp(char *out, size_t n)
{
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(out, n, "%H:%M:%S", &tm);
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void check_geometry(void)
{
    struct stat s;
    if (stat(L2, &s) != 0) { perror("stat"); exit(1); }
    long n = (long)s.st_size / SLOT;
    if (n != NSLOT || SLOT % 4096) {
        fprintf(stderr, "geometry mismatch: file holds %ld slots, want %d\n", n, NSLOT);
        exit(1);
    }
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

static volatile int g_short;

typedef struct { int fd; long base; void *buf; } Arg;

static void *lane(void *p)
{
    Arg *a = (Arg *)p;
    long s = a->base;
    for (int r = 0; r < ROUNDS; r++) {
        if (s >= NSLOT) s -= NSLOT;
        ssize_t n = pread(a->fd, a->buf, SLOT, (off_t)s * SLOT);
        if (n != SLOT) { g_short++; return NULL; }
        s = (s + 89) % NSLOT;
    }
    return NULL;
}

/* One measurement: NTH threads, NBATCH batches of ROUNDS slots each, starting at base.
 * Each batch is timed and printed separately. A collapse that lasts a second shows up as
 * one slow batch; one that lasts the whole run shows up as every batch being slow, and
 * those are different faults. */
static double one(int nthreads, int fd, long base, void *buf, const char *label)
{
    pthread_t th[32];
    Arg *args = (Arg *)calloc(nthreads, sizeof(Arg));
    for (int i = 0; i < nthreads; i++) {
        args[i].fd = fd;
        args[i].base = (base + i * 137) % NSLOT;
        args[i].buf = buf;
    }
    double mbs[NTH];
    for (int i = 0; i < nthreads; i++) mbs[i] = 0.0;
    double total = 0.0;

    for (int b = 0; b < NBATCH; b++) {
        char ts[16];
        stamp(ts, sizeof ts);
        double t0 = now_s();
        for (int i = 0; i < nthreads; i++)
            pthread_create(&th[i], NULL, lane, &args[i]);
        for (int i = 0; i < nthreads; i++) pthread_join(th[i], NULL);
        double wall = now_s() - t0;
        if (g_short) {
            printf("%s  %-3s base=%5ld batch %d  ABORTED (short read)\n",
                   ts, label, base, b);
            g_short = 0;
            free(args);
            return -1.0;
        }
        double mb = (double)nthreads * ROUNDS * SLOT / 1e6;
        double rate = mb / wall;
        mbs[0] += mb;
        total += rate;
        printf("%s  %-3s base=%5ld batch %d/%d  %6.0f MB/s\n",
               ts, label, base, b + 1, NBATCH, rate);
        fflush(stdout);
    }
    free(args);
    double avg = total / NBATCH;
    printf("%s  %-3s base=%5ld MEAN                %6.0f MB/s\n", "     ", label, base, avg);
    return avg;
}

static int cmp(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void report(const char *name, double *v, int n)
{
    double s[16];
    for (int i = 0; i < n; i++) s[i] = v[i];
    qsort(s, n, sizeof(double), cmp);
    double med = s[n / 2], lo = s[0], hi = s[n - 1];
    double q1 = s[n / 4], q3 = s[(3 * n) / 4];
    printf("   %-22s median %6.0f  min %6.0f  max %6.0f  "
           "max/med %5.2fx  IQR/med %.3f\n",
           name, med, lo, hi, hi / med, (q3 - q1) / med);
}

int main(void)
{
    check_geometry();
    check_clock();
    int fd = open(L2, O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open"); return 1; }
    void *buf = mmap(NULL, SLOT, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) { perror("mmap"); return 1; }

    printf("geometry: nslot=%d slot=%d, %d threads x %d batches x %d rounds"
           " = %.1f MB per batch\n\n",
           NSLOT, SLOT, NTH, NBATCH, ROUNDS, (double)NTH * ROUNDS * SLOT / 1e6);

    double t[NREP], r[NREP];

    printf("[1/2] series T: base fixed at 4096, %d measurements -- time alone\n", NREP);
    for (int i = 0; i < NREP; i++) t[i] = one(NTH, fd, 4096, buf, "T");

    printf("\n[2/2] series R: %d different bases -- time plus region\n", NREP);
    for (int i = 0; i < NREP; i++)
        r[i] = one(NTH, fd, (long)(NSLOT / (NREP + 1)) * (i + 1), buf, "R");

    double ts[16], rs[16];
    for (int i = 0; i < NREP; i++) { ts[i] = t[i]; rs[i] = r[i]; }
    report("T (fixed base)", ts, NREP);
    report("R (varied base)", rs, NREP);

    printf("\n=== reading\n");
    qsort(ts, NREP, sizeof(double), cmp);
    qsort(rs, NREP, sizeof(double), cmp);
    double tr = ts[NREP - 1] / ts[0], rr = rs[NREP - 1] / rs[0];
    printf("   time-only spread      max/min = %5.2fx\n", tr);
    printf("   time+region spread    max/min = %5.2fx\n", rr);
    if (tr < 1.3 && rr > 2.0)
        printf("   -> the drive's speed depends on WHERE you read, not on when. Every probe\n"
               "      that used one base and reported a single number was reporting a\n"
               "      property of that offset.\n");
    else if (tr > 2.0)
        printf("   -> the drift is temporal: the same region gives different rates minutes\n"
               "      apart. No offset discipline fixes this; only many more repetitions do,\n"
               "      and every single-run figure taken today needs re-reading in that light.\n");
    else
        printf("   -> neither factor explains v44's 3.4x. Its per-round base of\n"
               "      4096*(r+1) also advanced time between the arms, so the two are still\n"
               "      partly confounded here; a proper design crosses base with time.\n");

    munmap(buf, SLOT);
    close(fd);
    return 0;
}
