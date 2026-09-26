#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>

/* Pipeline-rate proof: per-layer wall = max(read_wall, compute_wall) once the
 * read of layer L is overlapped with the compute of layer L-1 (double buffer).
 * Sweep read bytes per layer (R) and compute budget (C) to show the total is
 * pinned by the SLOWEST stage, and that the faster stage can keep getting
 * faster with zero effect once it is below the other.
 */

#define SLOTS  16
static int LAYERS = 20;

static int fd;

static double now_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void compute_wall(double secs, long work) {
    volatile long sink = 0;
    const double t0 = now_s();
    while (now_s() - t0 < secs) { sink += work; }
    (void)sink;
}

static void read_layer(unsigned char *buf[2], int L, long per_slot, long spread) {
    /* 16 slots, each per_slot bytes, from 16 disjoint chunks of one nvme file. */
    for (int i = 0; i < SLOTS; i++) {
        unsigned char *dst = buf[L & 1] + (size_t)i * per_slot;
        ssize_t n = pread(fd, dst, per_slot, (off_t)(i * spread + (long)L * per_slot));
        if (n != per_slot) { fprintf(stderr, "pread short L=%d i=%d n=%zd\n", L, i, n); exit(1); }
    }
}

static long g_per_slot, g_spread;
static volatile int rd_done;   /* monotonic count of completed read layers */

static void *reader_t2(void *arg) {
    unsigned char **buf = (unsigned char **)arg;
    for (int L = 0; L < LAYERS; L++) {
        read_layer(buf, L, g_per_slot, g_spread);
        __sync_synchronize();
        rd_done = L + 1;
    }
    return NULL;
}

static void wait_rd(int need) {
    while (rd_done <= need) sched_yield();
}

/* S0: strictly serialized read-then-compute per layer. */
static double run_serial(unsigned char *buf[2], double C, long per_slot, long spread) {
    double t0 = now_s();
    for (int L = 0; L < LAYERS; L++) {
        read_layer(buf, L, per_slot, spread);
        compute_wall(C, 1);
    }
    return now_s() - t0;
}

/* S1: double-buffer pipeline. Reader fills buf[next] while main computes
 * buf[cur]. Monotonic rd_done counter removes any parity race. */
static double run_pipe(unsigned char *buf[2], double C, long per_slot, long spread) {
    g_per_slot = per_slot;
    g_spread = spread;
    pthread_t rt;
    rd_done = 0;
    __sync_synchronize();
    double t0 = now_s();
    pthread_create(&rt, NULL, reader_t2, buf);
    /* warm compute pipeline on garbage (CPU only) so the reader can catch up */
    compute_wall(C, 1);
    wait_rd(0);
    for (int L = 0; L < LAYERS; L++) {
        compute_wall(C, 1);
        if (L + 1 < LAYERS) wait_rd(L + 1);
    }
    pthread_join(rt, NULL);
    return now_s() - t0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *path = argc > 1 ? argv[1] : "/mnt/nvme/trunk_layers_out/layer_000.bin";
    double C = argc > 2 ? atof(argv[2]) : 0.09;
    long per_slot = argc > 3 ? atol(argv[3]) : (4L * 1024 * 1024);
    if (argc > 4) LAYERS = atoi(argv[4]);
    fprintf(stderr, "start path=%s C=%.3f per_slot=%ld layers=%d\n", path, C, per_slot, LAYERS);

    fd = open(path, O_RDONLY | O_DIRECT);
    if (fd < 0) { perror(path); return 1; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < per_slot * SLOTS) {
        fprintf(stderr, "file too small for %d x %ld bytes: %ld\n", SLOTS, per_slot, (long)st.st_size);
        return 1;
    }
    const long spread = (long)(st.st_size / SLOTS);
    fprintf(stderr, "stage: open ok size=%ld spread=%ld\n", (long)st.st_size, spread);

    unsigned char *buf[2];
    for (int i = 0; i < 2; i++) {
        if (posix_memalign((void **)&buf[i], 4096, (size_t)SLOTS * per_slot)) { perror("memalign"); return 1; }
        memset(buf[i], 0xAB, (size_t)SLOTS * per_slot);
    }

    (void)run_serial(buf, C, per_slot, spread);   /* warmup / fill page cache */
    fprintf(stderr, "stage: warmup done\n");
    double S0 = run_serial(buf, C, per_slot, spread);
    fprintf(stderr, "stage: serial done S0=%.2f\n", S0);
    double S1 = run_pipe(buf, C, per_slot, spread);
    fprintf(stderr, "stage: pipe done S1=%.2f\n", S1);

    /* single-stage read-only time (no compute) for independent R */
    fprintf(stderr, "stage: read-only pass\n");
    double t0 = now_s();
    for (int L = 0; L < LAYERS; L++) read_layer(buf, L, per_slot, spread);
    double Rtotal = now_s() - t0;
    double R = Rtotal / LAYERS;
    fprintf(stderr, "stage: read-only done R=%.4f\n", R);

    printf("L=%d slots=%d per_slot=%ld (%.0f MB) C=%.3f s\n",
           LAYERS, SLOTS, per_slot, per_slot / 1e6, C);
    printf("  R(one layer wall, 16-way)  = %.4f s\n", R);
    printf("  S0 serial (L*(R+C)+)       = %.2f s  L*(R+C)=%.2f\n", S0, (double)LAYERS * (R + C));
    printf("  S1 piped  (L*max(R,C)+)    = %.2f s  L*max(R,C)=%.2f\n", S1, (double)LAYERS * (R > C ? R : C));
    printf("  speedup S0/S1              = %.2fx\n", S0 / S1);

    if (R < C)
        printf("  REGIME: R<C -> total pinned by compute (read is free/hidden conforms)\n");
    else
        printf("  REGIME: R>C -> total pinned by read bandwidth (compute hidden)\n");
    close(fd);
    return 0;
}