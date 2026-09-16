/* SPDX-License-Identifier: Apache-2.0 */
/* k3_chip.h, Kimi K3 inference engine: simulated MXFP4 GEMV chip.
 *
 * The K3 routed experts are 1.6e9 parameters per token read as packed MXFP4, and a
 * token touches 1,472 expert chains and ~25.8 GB of weight bytes. k3_chip.c runs that
 * work on a plain-pthread pool ("the chip") and reports what a real MXFP4 GEMV
 * accelerator with an advertised TFLOPs and GB/s would say about the same load. It is a
 * SIMULATION of the accelerator's accounting, not a faithful model of its latency: the
 * pool runs the exact k3_matmul_mxfp4 / k3_situ_glu kernels the serial engine uses, so
 * results are bit-identical to the streamed path and the bill is the only new output.
 *
 * Integration contract (see k3_ops.c / k3_run.c):
 *   - k3_chip_init()   once, before the first forward pass. Reads the environment
 *                      (K3_NO_CHIP, CHIP_NWORKERS, CHIP_TFLOPS, CHIP_GBPS), warms the
 *                      lazy MXFP4 decode tables on this thread, switches k3_matmul_mxfp4
 *                      to single-threaded (k3_mxfp4_omp(0)) and spawns the pool. While
 *                      the chip is active every MXFP4 matmul in the process runs serial,
 *                      including the draft's cache-only path; only speed is affected.
 *   - k3_chip_run()    replaces a batch of k3_moe expert chains. All jobs in one call
 *                      must share dims (in, rows1, out, group) and each job writes its
 *                      own disjoint edn[] region. The pool never touches the caller's
 *                      x/packed/scales after a job is taken, so the cache slots stay
 *                      valid for the duration of the call (k3_cache_pin is declared but
 *                      never enforced: no get()/admit() may run while a batch is live).
 *   - k3_chip_set_tokens / k3_chip_note_copy / k3_chip_print_bill  bill accounting.
 *   - k3_chip_destroy() after the last forward pass, before the process exits.
 */

#ifndef K3_CHIP_H
#define K3_CHIP_H

#include "k3.h"

#ifdef __cplusplus
extern "C" {
#endif

/* One expert chain: edn[out] = W2[out][rows1] . SiTU(W1[rows1][in].x, W3[rows1][in].x).
 * p1/s1, p3/s3 and p2/s2 are the packed MXFP4 weight + scale pointers for the three
 * matrices, exactly as K3ExpertQ provides. wslot remembers the job's position in the
 * caller's idx[]/wt[] arrays so the caller can accumulate the weighted sum in the
 * original top-k order after the batch completes. */
typedef struct {
    const float         *x;
    const unsigned char *p1, *s1;
    const unsigned char *p3, *s3;
    const unsigned char *p2, *s2;
    float               *edn;
    int                  in, rows1, out, group;
    float                b1, b2;
    int                  wslot;
} K3ChipJob;

/* Non-zero once k3_chip_init has spawned the pool. Callers use this to decide whether
 * to take the chip branch; when the chip is disabled every k3_chip_* is a no-op and
 * the serial path runs, which is the A/B baseline. */
int  k3_chip_active(void);

/* Spawn the pool and read the environment. Call once, before any forward pass. */
void k3_chip_init(void);

/* Join the pool and free its resources. Call once, after the last forward pass. */
void k3_chip_destroy(void);

/* Execute n expert chains. Jobs may run on the pool (n > 4) or inline on the caller
 * (n <= 4). Blocks until every job has written its edn[]. */
void k3_chip_run(K3ChipJob *jobs, int n);

/* Total token-slots (prefill + generated) the bill should divide by. */
void k3_chip_set_tokens(int total);

/* Add measured host time spent fetching expert weights (cache get/getmany) and the
 * bytes those fetches made available. */
void k3_chip_note_copy(double seconds, double bytes);

/* Bytes of packed MXFP4 weight data one expert chain must read:
 *   2 * rows1 * (in/2 + ceil(in/group))   for W1 and W3
 *   + out * (rows1/2 + ceil(rows1/group)) for W2. */
unsigned long long k3_chip_chain_bytes(int in, int rows1, int out, int group);

/* Print the accumulated bill to stdout. */
void k3_chip_print_bill(void);

/* Monotonic seconds, the pool's shared clock. */
double k3_chip_now(void);

#ifdef __cplusplus
}
#endif

#endif /* K3_CHIP_H */