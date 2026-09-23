/* bench_ternary.c - what does a [-1,0,1] expert matmul actually cost?
 *
 * The MXFP4 expert matmul in bench_kernels.c moves 17.55 MB of weight per expert per
 * token and projects to ~10 s/token of expert read at the memory floor. Ternary packing
 * is the same idea pushed to its limit: 0.25 bits/element instead of 4.25, so the same
 * expert is 7.88 MB - and the matmul becomes memory-bound on x, which is 14 KB, instead
 * of on W. This benchmark runs fp32, MXFP4 and ternary at the SAME expert shape and
 * reports GFLOP/s and the projected expert read seconds per token for each.
 *
 * Output rows are hashed with FNV, the same as bench_kernels.c, for the same reason:
 * building with and without AVX2 and comparing hashes is the only real proof that a
 * fast path is bit-identical rather than merely close.
 */
#define _POSIX_C_SOURCE 199309L

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "k3.h"

static double now_s(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void fnv(const char *label, const float *v, int n)
{
    unsigned long long h = 1469598103934665603ull;
    for (int k = 0; k < n; k++) {
        union { float f; unsigned u; } b; b.f = v[k];
        for (int t = 0; t < 4; t++) { h ^= (b.u >> (8 * t)) & 0xFFu; h *= 1099511628211ull; }
    }
    printf("             %s OUTPUT FNV1a = %016llx\n", label, h);
}

static void fillf(float *p, size_t n, unsigned s)
{
    for (size_t i = 0; i < n; i++) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        p[i] = ((float)(s >> 8) / 8388608.0f - 1.0f) * 0.05f;
    }
}

static void fillb(unsigned char *p, size_t n, unsigned s)
{
    for (size_t i = 0; i < n; i++) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        p[i] = (unsigned char)(s >> 13);
    }
}

/* Ternary weights: two-bit codes drawn from {0,1,2} ONLY. fillb's uniform bytes would
 * hit code 3, which this engine treats as invalid and which reads as NaN and poisons the
 * row - deliberately, since a NaN row is a loud failure rather than a silent misread. */
static void fillt(unsigned char *p, size_t n, unsigned s)
{
    for (size_t i = 0; i < n; i++) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        const unsigned a = (s >> 8)  % 3u;
        const unsigned b = (s >> 16) % 3u;
        const unsigned c = (s >> 24) % 3u;
        const unsigned d = (s >> 5)  % 3u;
        p[i] = (unsigned char)(a | (b << 2) | (c << 4) | (d << 6));
    }
}

int main(void)
{
    const int in = 3584, rows = 3072;         /* w1 shape: latent -> inter */
    const int group = K3_MXFP4_GROUP;
    const int pcols = (in + 3) / 4;           /* 896 bytes per ternary row */
    const int ngrp = in / group;

    float *x  = (float *)malloc((size_t)in * sizeof(float));
    float *y  = (float *)malloc((size_t)rows * sizeof(float));
    float *Wf = (float *)malloc((size_t)in * rows * sizeof(float));          /* 44 MB  */
    unsigned char *pk = (unsigned char *)malloc((size_t)rows * (in / 2));    /* 4.7 MB */
    unsigned char *sc = (unsigned char *)malloc((size_t)rows * ngrp);
    unsigned char *pt = (unsigned char *)malloc((size_t)rows * pcols);       /* 2.8 MB */
    if (!x || !y || !Wf || !pk || !sc || !pt) { printf("alloc failed\n"); return 1; }

    fillf(Wf, (size_t)in * rows, 12345u);
    fillt(pt, (size_t)rows * pcols, 9876u);
    fillb(pk, (size_t)rows * (in / 2), 777u);
    memset(sc, 127, (size_t)rows * ngrp);
    fillf(x, in, 4242u);

    printf("ternary benchmark at REAL expert shape (in=%d rows=%d)\n", in, rows);

    /* fp32 baseline */
    k3_matmul(y, x, Wf, in, rows);
    const int reps = 5;
    const double t0 = now_s();
    for (int r = 0; r < reps; r++) k3_matmul(y, x, Wf, in, rows);
    const double dt_f32 = (now_s() - t0) / reps;
    const double gflop = 2.0 * in * rows / 1e9;
    printf("fp32    %5d x %-5d  %7.2f ms  %8.1f GFLOP/s\n", rows, in, dt_f32 * 1e3, gflop / dt_f32);
    fnv("fp32  ", y, rows);

    /* MXFP4 baseline */
    k3_matmul_mxfp4(y, x, pk, sc, in, rows, group);
    const double t1 = now_s();
    for (int r = 0; r < reps; r++) k3_matmul_mxfp4(y, x, pk, sc, in, rows, group);
    const double dt_mx = (now_s() - t1) / reps;
    printf("MXFP4   %5d x %-5d  %7.2f ms  %8.1f GFLOP/s\n", rows, in, dt_mx * 1e3, gflop / dt_mx);
    fnv("mxfp4 ", y, rows);

    /* ternary */
    k3_ternary_matmul(y, x, pt, in, rows);
    const double t2 = now_s();
    for (int r = 0; r < reps; r++) k3_ternary_matmul(y, x, pt, in, rows);
    const double dt_te = (now_s() - t2) / reps;
    printf("ternary %5d x %-5d  %7.2f ms  %8.1f GFLOP/s\n", rows, in, dt_te * 1e3, gflop / dt_te);
    fnv("ternar", y, rows);

    /* One expert is w1 + w3 (both 3072x3584) + w2 (3584x3072), 16 experts, 92 layers.
     * At the memory floor the expert read is the cost that matters: 17.55 MB vs 7.88 MB
     * of weight per expert per token. */
    const double per_tok_f32 = dt_f32 * 3.0 * 16 * 92;
    const double per_tok_mx  = dt_mx  * 3.0 * 16 * 92;
    const double per_tok_te  = dt_te  * 3.0 * 16 * 92;
    printf("\nprojected expert compute, 16 experts x 3 mats x 92 layers:\n"
           "  fp32    %.2f s/token\n  MXFP4   %.2f s/token\n  ternary %.2f s/token\n"
           "\nmeasured compute budget at the floor is about 10 s/token.\n",
           per_tok_f32, per_tok_mx, per_tok_te);
    free(x); free(y); free(Wf); free(pk); free(sc); free(pt);
    return 0;
}