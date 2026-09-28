/* Per-phase timeline tracing.
 *
 * WHY THIS EXISTS. Every A/B run to date reported one wall clock and a handful of
 * aggregates, which is not enough to tell a slow device from misplaced work: the run
 * says "81 s/token" but not which of the ~93 layers was blocking, how many bytes that
 * layer read, whether the read landed under the arithmetic or in front of it, or how
 * many of those bytes came from RAM rather than the NVMe. Guessing at that is how a
 * day went into measuring the same three variables.
 *
 * OFF unless K3_TRACE names a file. With it unset every entry point is a single
 * load-and-branch on a static int, and nothing is written.
 *
 * The event record is a completed interval, not a begin/end pair, so a caller brackets
 * its own work and emits once. Slots are claimed with an atomic fetch_add and filled
 * after, so producers never hold a lock -- the trunk reader thread, the expert prefetch
 * reader and the forward thread all emit concurrently.
 */
#ifndef K3_TRACE_H
#define K3_TRACE_H

#include <stdint.h>

/* Phases, kept small and stable so the CSV can be filtered by column. */
enum { K3_PHASE_TRUNK = 1, K3_PHASE_EXPERT = 2, K3_PHASE_COMPUTE = 3,
       K3_PHASE_WIDEN = 4, K3_PHASE_LM = 5 };

/* 8 tokens x 93 layers x 8 phases is ~6k rows; 200k leaves room for a long run. */
#define K3_TRACE_MAX 200000

typedef struct K3TraceEv {
    double   t0, t1;        /* CLOCK_MONOTONIC seconds, from the same now_s() the
                             * engine's own timers use, so the CSV lines up with the
                             * stdout numbers */
    uint64_t bytes;         /* bytes this phase moved (0 when not meaningful) */
    int32_t  token, layer;
    int16_t  phase;
    int32_t  l1_hit, l1_miss, l2_hit, l2_miss;
} K3TraceEv;

int  k3_trace_init(const char *path);  /* path == NULL or "0" disables. Returns 0 if on. */
void k3_trace_token(int token);        /* stamped onto every later event */
int  k3_trace_on(void);

/* Emit one interval. Cheap no-op when tracing is off. */
void k3_trace_ev(int phase, int layer, double t0, double t1, uint64_t bytes,
                 int l1_hit, int l1_miss, int l2_hit, int l2_miss);

/* Write the CSV (header + rows) to the path given to k3_trace_init. Safe to call
 * once at the end of a run; does nothing when tracing is off. */
int  k3_trace_dump(void);

double k3_trace_now(void);   /* same clock as the engine timers */

#endif
