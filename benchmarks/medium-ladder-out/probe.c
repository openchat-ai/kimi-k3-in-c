#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec*1e-9; }
/* RAM bandwidth: several threads each stream one big memcpy, best of 3 rounds.
 * Single-threaded memcpy under WSL2 understates the wall (page-fault and
 * migration effects); the engine's GEMMs also run across all cores. */
#define MEMTHREADS 8
static double *g_src, *g_dst;
static void *worker_memcpy(void *arg){
    (void)arg;
    const size_t n = 1u<<28;                 /* 256M doubles = 2 GiB per thread */
    memcpy(g_dst, g_src, n*8);
    return NULL;
}
static double mem_bw(void){
    const size_t n = 1u<<28;
    g_src = malloc(n*8); g_dst = malloc(n*8);
    if (!g_src || !g_dst) return 0;
    memset(g_src, 1, n*8); memset(g_dst, 2, n*8);
    pthread_t th[MEMTHREADS];
    for (int i=0;i<MEMTHREADS;i++) pthread_create(&th[i], NULL, worker_memcpy, NULL);
    for (int i=0;i<MEMTHREADS;i++) pthread_join(th[i], NULL);   /* warmup */
    volatile double sink = 0;
    double best = 0;
    for (int r=0;r<3;r++){
        double t0=now();
        for (int i=0;i<MEMTHREADS;i++) pthread_create(&th[i], NULL, worker_memcpy, NULL);
        for (int i=0;i<MEMTHREADS;i++) pthread_join(th[i], NULL);
        double dt=now()-t0;
        sink += g_dst[n/2];                  /* defeat dead-store elimination */
        double gb = 2.0*n*8*MEMTHREADS/dt/1e9;
        if (gb>best) best=gb;
    }
    (void)sink;
    free(g_src); free(g_dst);
    return best;
}
/* FMA peak, one worker per core: tiny L1-resident arrays, many iterations,
 * explicit fma so the loop cannot become memory-bound. Sums across workers. */
typedef struct { double gf; } worker_out;
static double w_fp64, w_fp32;
static void *worker_fp64(void *arg){
    const int n = 4096;
    double a[4096], b[4096], c[4096];
    for (int i=0;i<n;i++){ a[i]=1.0; b[i]=2.0; c[i]=0.5; }
    const long iters = 500000;
    double t0 = now();
    for (long it=0; it<iters; it++)
        for (int i=0;i<n;i+=4){
            c[i+0] = __builtin_fma(a[i+0], b[i+0], c[i+0]);
            c[i+1] = __builtin_fma(a[i+1], b[i+1], c[i+1]);
            c[i+2] = __builtin_fma(a[i+2], b[i+2], c[i+2]);
            c[i+3] = __builtin_fma(a[i+3], b[i+3], c[i+3]);
        }
    double dt = now()-t0;
    volatile double sink = c[0] + c[1023] + c[4095];
    (void)sink;
    worker_out *o = arg;
    o->gf = (double)n * iters * 2.0 / dt / 1e9;
    return NULL;
}
static void *worker_fp32(void *arg){
    const int n = 4096;
    float a[4096], b[4096], c[4096];
    for (int i=0;i<n;i++){ a[i]=1.0f; b[i]=2.0f; c[i]=0.5f; }
    const long iters = 500000;
    double t0 = now();
    for (long it=0; it<iters; it++)
        for (int i=0;i<n;i+=8){
            c[i+0] = __builtin_fmaf(a[i+0], b[i+0], c[i+0]);
            c[i+1] = __builtin_fmaf(a[i+1], b[i+1], c[i+1]);
            c[i+2] = __builtin_fmaf(a[i+2], b[i+2], c[i+2]);
            c[i+3] = __builtin_fmaf(a[i+3], b[i+3], c[i+3]);
            c[i+4] = __builtin_fmaf(a[i+4], b[i+4], c[i+4]);
            c[i+5] = __builtin_fmaf(a[i+5], b[i+5], c[i+5]);
            c[i+6] = __builtin_fmaf(a[i+6], b[i+6], c[i+6]);
            c[i+7] = __builtin_fmaf(a[i+7], b[i+7], c[i+7]);
        }
    double dt = now()-t0;
    volatile float sink = c[0] + c[1023] + c[4095];
    (void)sink;
    worker_out *o = arg;
    o->gf = (double)n * iters * 2.0 / dt / 1e9;
    return NULL;
}
static double peak_all(void *(*fn)(void *)){
    int nc = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (nc < 1) nc = 1;
    pthread_t *th = calloc((size_t)nc, sizeof *th);
    worker_out *out = calloc((size_t)nc, sizeof *out);
    if (!th || !out) return 0;
    double best = 0;
    for (int r=0;r<2;r++){
        for (int i=0;i<nc;i++) pthread_create(&th[i], NULL, fn, &out[i]);
        for (int i=0;i<nc;i++) pthread_join(th[i], NULL);
        double sum = 0;
        for (int i=0;i<nc;i++) sum += out[i].gf;
        if (sum > best) best = sum;
    }
    free(th); free(out);
    return best;
}
int main(void){
    double m = mem_bw();
    double g64 = peak_all(worker_fp64);
    double g32 = peak_all(worker_fp32);
    printf("memcpy_gbps %.2f\n", m);
    printf("fma_gflops_fp64 %.1f\n", g64);
    printf("fma_gflops_fp32 %.1f\n", g32);
    return 0;
}
