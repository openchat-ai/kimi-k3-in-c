/* SPDX-License-Identifier: Apache-2.0 */
/* k3_chip.c, Kimi K3 inference engine: simulated MXFP4 GEMV chip.
 *
 * WHAT THIS IS
 *   The K3 routed-expert work is 1,472 expert chains per token, all read as packed
 *   MXFP4 nibbles: 25.8 GB of weight bytes and 97 Gflops of GEMV per token. This module
 *   runs that work on a plain-pthread pool and reports what a real MXFP4 GEMV
 *   accelerator with an advertised TFLOPs and GB/s would say about the same load: how
 *   long the expert matmuls would take at those rates, whether that time is bandwidth-
 *   or compute-bound, how many bytes per token must move, and what the host-side expert
 *   fetch costs in measured wall time.
 *
 *   It is a SIMULATION of the accelerator's accounting, not a faithful model of its
 *   latency. The pool executes the exact k3_matmul_mxfp4 / k3_situ_glu kernels the
 *   serial engine uses, so the results are bit-identical to the streamed path; the bill
 *   is the only new output.
 *
 * THE POOL
 *   CHIP_NWORKERS plain pthreads (default 4, clamp 0..16) plus the caller, all taking
 *   jobs from a shared counter under one mutex. Workers wait on g_post for the next
 *   batch; the caller bumps the batch generation g_gen and broadcasts, then participates
 *   in taking jobs. g_rem counts the participants that have not yet finished their
 *   slice, and the last one to finish broadcasts g_done so the caller's run returns.
 *   Re-entry is gated on the generation, so a worker that has already counted its slice
 *   cannot loop back into an in-flight batch and double-count (the classic pool race).
 *
 *   The intermediate gu/act buffers are private per worker and grown lazily, so there is
 *   no batch-wide allocation and no shared scratch. The caller's own buffer is only ever
 *   touched by the caller. Batches of 1..4 jobs run inline on the calling thread, which
 *   keeps the ~20 us pool handshake out of the many single-expert prefill batches.
 *
 * ACCOUNTING
 *   All counters are caller-side: after a batch completes, the caller reads jobs[0]
 *   (every job in a batch shares dims) and adds flops/bytes/jobs. Workers never touch
 *   the counters. The fetch phase (cache getmany/get) is timed by the callers and
 *   reported through k3_chip_note_copy. Per-token figures use the token count given to
 *   k3_chip_set_tokens once (prompt prefill + generated).
 *
 * ENABLING
 *   k3_chip_init() reads the environment: K3_NO_CHIP=1 or CHIP_NWORKERS=0 disables the
 *   chip; CHIP_TFLOPS (default 4.0) and CHIP_GBPS (default 200.0) set the simulated
 *   wall. It warms the MXFP4 decode tables on this thread and stops k3_matmul_mxfp4
 *   from spawning its own OpenMP teams BEFORE the workers spawn, so the tables are
 *   single-threaded and each worker stays one thread. k3_chip_destroy() joins the pool.
 *   While the chip is active k3_mxfp4 is serial everywhere, including the draft's
 *   cache-only path; correctness never depends on that, only the draft's speed.
 */

/* The config test builds k3_ops.c (and transitively this module) with -std=c99, under
 * which glibc hides clock_gettime behind this feature macro. Harmless under gnu99. */
#define _POSIX_C_SOURCE 200809L

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "k3.h"
#include "k3_chip.h"

#define K3_CHIP_MAX_WORKERS 16
#define K3_CHIP_INLINE_MAX  4

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_post = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  g_done = PTHREAD_COND_INITIALIZER;

static pthread_t       *g_tid = NULL;
static int              g_workers = 0;
static int              g_shutdown = 0;
static unsigned long long g_gen = 0;
static int              g_n = 0, g_next = 0, g_rem = 0;
static K3ChipJob       *g_jobs = NULL;

static float           *g_caller = NULL;
static size_t           g_caller_cap = 0;

static double           g_tflops = 4.0, g_gbps = 200.0;
static unsigned long long g_chain_flops = 0, g_chain_bytes = 0;
static long long        g_ops = 0;
static double           g_compute_s = 0.0, g_copy_s = 0.0, g_copy_b = 0.0;
static int              g_tokens = 0;
static int              g_inited = 0;

double k3_chip_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec;
}

int k3_chip_active(void)
{
    return g_workers > 0;
}

unsigned long long k3_chip_chain_bytes(int in, int rows1, int out, int group)
{
    const unsigned long long I = (unsigned long long)rows1;
    const unsigned long long L = (unsigned long long)in;
    const unsigned long long G = (unsigned long long)group;
    return 2ULL * (I * (L / 2) + I * ((L + G - 1) / G))
         + (unsigned long long)out * (I / 2)
         + (unsigned long long)out * ((I + G - 1) / G);
}

static void chip_oom(const char *what, size_t bytes)
{
    fprintf(stderr,
            "k3 chip: FATAL, could not allocate %zu bytes for %s.\n"
            "    Aborting rather than continuing with an uninitialised buffer.\n",
            bytes, what);
    abort();
}

static int chip_buf_ensure(float **buf, size_t *cap, size_t need)
{
    if (need <= *cap) return 0;
    float *nb = (float *)realloc(*buf, need * sizeof(float));
    if (!nb) return -1;
    *buf = nb;
    *cap = need;
    return 0;
}

/* One expert chain: y = W2 . SiTU(W1.x, W3.x). Bit-identical to the serial path in
 * k3_moe (k3_ops.c), so pool execution order never changes a float. */
static void chip_run_job(const K3ChipJob *jb, float *buf)
{
    float *gu  = buf;
    float *act = buf + 2 * jb->rows1;
    k3_matmul_mxfp4(gu,              jb->x, jb->p1, jb->s1, jb->in, jb->rows1, jb->group);
    k3_matmul_mxfp4(gu + jb->rows1,  jb->x, jb->p3, jb->s3, jb->in, jb->rows1, jb->group);
    k3_situ_glu(act, gu, jb->rows1, jb->b1, jb->b2);
    k3_matmul_mxfp4(jb->edn, act, jb->p2, jb->s2, jb->rows1, jb->out, jb->group);
}

static void *chip_worker(void *arg)
{
    float *buf = NULL;
    size_t cap = 0;
    unsigned long long mygen = 0;
    (void)arg;

    pthread_mutex_lock(&g_lock);
    for (;;) {
        while (g_gen == mygen && !g_shutdown)
            pthread_cond_wait(&g_post, &g_lock);
        if (g_shutdown) break;
        mygen = g_gen;
        for (;;) {
            if (g_next >= g_n) break;
            const int j = g_next++;
            pthread_mutex_unlock(&g_lock);
            const K3ChipJob *jb = &g_jobs[j];
            if (chip_buf_ensure(&buf, &cap, (size_t)3 * jb->rows1) != 0)
                chip_oom("chip worker scratch", (size_t)3 * jb->rows1 * sizeof(float));
            chip_run_job(jb, buf);
            pthread_mutex_lock(&g_lock);
        }
        if (--g_rem == 0) pthread_cond_broadcast(&g_done);
    }
    pthread_mutex_unlock(&g_lock);
    free(buf);
    return NULL;
}

static void chip_account(const K3ChipJob *jobs, int n, double wall)
{
    const K3ChipJob *j0 = &jobs[0];
    g_chain_flops += (unsigned long long)n
        * (2ULL * (unsigned long long)j0->rows1
           * (2ULL * (unsigned long long)j0->in + (unsigned long long)j0->out));
    g_chain_bytes += (unsigned long long)n
        * k3_chip_chain_bytes(j0->in, j0->rows1, j0->out, j0->group);
    g_ops += n;
    g_compute_s += wall;
}

void k3_chip_run(K3ChipJob *jobs, int n)
{
    if (n <= 0) return;
    const double t0 = k3_chip_now();

    if (!g_workers || n <= K3_CHIP_INLINE_MAX) {
        for (int j = 0; j < n; j++) {
            const K3ChipJob *jb = &jobs[j];
            if (chip_buf_ensure(&g_caller, &g_caller_cap, (size_t)3 * jb->rows1) != 0)
                chip_oom("chip caller scratch", (size_t)3 * jb->rows1 * sizeof(float));
            chip_run_job(jb, g_caller);
        }
        chip_account(jobs, n, k3_chip_now() - t0);
        return;
    }

    pthread_mutex_lock(&g_lock);
    g_jobs = jobs;
    g_n = n;
    g_next = 0;
    g_rem = g_workers + 1;
    g_gen++;
    pthread_cond_broadcast(&g_post);
    pthread_mutex_unlock(&g_lock);

    for (;;) {
        pthread_mutex_lock(&g_lock);
        if (g_next >= n) { pthread_mutex_unlock(&g_lock); break; }
        const int j = g_next++;
        pthread_mutex_unlock(&g_lock);
        const K3ChipJob *jb = &jobs[j];
        if (chip_buf_ensure(&g_caller, &g_caller_cap, (size_t)3 * jb->rows1) != 0)
            chip_oom("chip caller scratch", (size_t)3 * jb->rows1 * sizeof(float));
        chip_run_job(jb, g_caller);
    }

    pthread_mutex_lock(&g_lock);
    if (--g_rem == 0) pthread_cond_broadcast(&g_done);
    while (g_rem > 0) pthread_cond_wait(&g_done, &g_lock);
    pthread_mutex_unlock(&g_lock);

    chip_account(jobs, n, k3_chip_now() - t0);
}

void k3_chip_set_tokens(int total)
{
    g_tokens = total;
}

void k3_chip_note_copy(double seconds, double bytes)
{
    g_copy_s += seconds;
    g_copy_b += bytes;
}

void k3_chip_print_bill(void)
{
    if (!g_workers || g_ops == 0) return;
    const int tok = g_tokens > 0 ? g_tokens : 1;
    const double cwall = (double)g_chain_flops / (g_tflops * 1e12);
    const double bwall = (double)g_chain_bytes / (g_gbps * 1e9);
    const int bw = bwall > cwall;
    printf("\n[chip] simulated MXFP4 GEMV bill over %d tokens\n", g_tokens);
    printf("  %lld expert chains | %llu flops | %llu bytes (%.2f GB)\n",
           (long long)g_ops, g_chain_flops, g_chain_bytes, (double)g_chain_bytes / 1e9);
    printf("  per token: %llu chains | %.2f GB | %.2f Gflops\n",
           (unsigned long long)(g_ops / tok),
           (double)g_chain_bytes / (1e9 * tok),
           (double)g_chain_flops / (1e12 * tok));
    printf("  compute wall @ %.0f TFLOPS : %.2f s (%.2f ms/token)\n",
           g_tflops, cwall, 1000.0 * cwall / tok);
    printf("  bandwidth wall @ %.0f GB/s : %.2f s (%.2f ms/token)\n",
           g_gbps, bwall, 1000.0 * bwall / tok);
    printf("  -> %s-bound; to be compute-bound at %.0f TFLOPS this needs %.0f GB/s\n",
           bw ? "bandwidth" : "compute",
           g_tflops, (double)g_chain_bytes / (cwall > 0 ? cwall : 1.0) / 1e9);
    if (g_copy_s > 0.0)
        printf("  expert fetch (host wall, measured): %.2f s moving %.2f GB = %.0f GB/s\n",
               g_copy_s, g_copy_b / 1e9,
               g_copy_s > 0 ? g_copy_b / g_copy_s / 1e9 : 0.0);
    printf("  chip pool wall (measured): %.2f s\n\n", g_compute_s);
}

void k3_chip_init(void)
{
    if (g_inited) return;
    g_inited = 1;

    const char *no = getenv("K3_NO_CHIP");
    if (no && no[0] && no[0] != '0') return;

    const char *nw = getenv("CHIP_NWORKERS");
    int w = nw ? atoi(nw) : 4;
    if (w > K3_CHIP_MAX_WORKERS) w = K3_CHIP_MAX_WORKERS;
    if (w < 0) w = 0;
    if (w == 0) return;

    const char *tf = getenv("CHIP_TFLOPS");
    if (tf) { const double v = atof(tf); if (v > 0.0) g_tflops = v; }
    const char *gb = getenv("CHIP_GBPS");
    if (gb) { const double v = atof(gb); if (v > 0.0) g_gbps = v; }

    /* Warm the lazy decode tables on this thread and stop k3_matmul_mxfp4 from opening
     * its own OpenMP region BEFORE the workers spawn. A table write racing a worker's
     * read is the one real hazard in k3_matmul_mxfp4's thread-safety (see the lazy init
     * in k3_ops.c); doing it here serialises it, and leaving OpenMP on would
     * oversubscribe the box with workers x teams. */
    k3_mxfp4_warmup();
    k3_mxfp4_omp(0);

    g_workers = w;
    g_tid = (pthread_t *)malloc((size_t)w * sizeof(pthread_t));
    if (!g_tid) {
        g_workers = 0;
        k3_mxfp4_omp(1);
        return;
    }
    int created = 0;
    for (int i = 0; i < w; i++) {
        if (pthread_create(&g_tid[i], NULL, chip_worker, NULL) == 0) created++;
        else break;
    }
    if (created < w) {
        g_workers = created;
        k3_chip_destroy();
        k3_mxfp4_omp(1);
        return;
    }
    fprintf(stderr, "k3 chip: %d workers, %.0f TFLOPS, %.0f GB/s simulated wall\n",
            g_workers, g_tflops, g_gbps);
}

void k3_chip_destroy(void)
{
    free(g_caller);
    g_caller = NULL;
    g_caller_cap = 0;
    if (!g_workers) return;
    pthread_mutex_lock(&g_lock);
    g_shutdown = 1;
    pthread_cond_broadcast(&g_post);
    pthread_mutex_unlock(&g_lock);
    for (int i = 0; i < g_workers; i++) pthread_join(g_tid[i], NULL);
    free(g_tid);
    g_tid = NULL;
    g_workers = 0;
}