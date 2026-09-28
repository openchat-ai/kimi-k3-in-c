#include "k3_trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdatomic.h>

static K3TraceEv   g_ev[K3_TRACE_MAX];
static atomic_int  g_n;
static int         g_on;
static int         g_token;
static char        g_path[512];

double k3_trace_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int k3_trace_on(void) { return g_on; }

int k3_trace_init(const char *path)
{
    if (!path || !path[0] || !strcmp(path, "0")) { g_on = 0; return 0; }
    snprintf(g_path, sizeof g_path, "%s", path);
    atomic_store(&g_n, 0);
    g_token = 0;
    g_on = 1;
    fprintf(stderr, "[trace] ON -> %s (K3_TRACE_MAX %d events)\n", g_path, K3_TRACE_MAX);
    return 1;
}

void k3_trace_token(int token) { g_token = token; }

void k3_trace_ev(int phase, int layer, double t0, double t1, uint64_t bytes,
                 int l1_hit, int l1_miss, int l2_hit, int l2_miss)
{
    if (!g_on) return;
    const int i = atomic_fetch_add(&g_n, 1);
    if (i >= K3_TRACE_MAX) {                 /* overflow: stop claiming, keep the rest */
        atomic_fetch_sub(&g_n, 1);
        return;
    }
    K3TraceEv *e = &g_ev[i];
    e->t0 = t0; e->t1 = t1;
    e->bytes = bytes;
    e->token = g_token; e->layer = layer;
    e->phase = (int16_t)phase;
    e->l1_hit = l1_hit; e->l1_miss = l1_miss;
    e->l2_hit = l2_hit; e->l2_miss = l2_miss;
}

static const char *phase_name(int p)
{
    switch (p) {
    case K3_PHASE_TRUNK:  return "trunk";
    case K3_PHASE_EXPERT: return "expert";
    case K3_PHASE_COMPUTE:return "compute";
    case K3_PHASE_WIDEN:  return "widen";
    case K3_PHASE_LM:     return "lm";
    default:              return "other";
    }
}

int k3_trace_dump(void)
{
    if (!g_on) return 0;
    const int n = atomic_load(&g_n);
    const int rows = n > K3_TRACE_MAX ? K3_TRACE_MAX : n;
    FILE *f = fopen(g_path, "w");
    if (!f) { fprintf(stderr, "[trace] cannot write %s\n", g_path); return -1; }
    fprintf(f, "token,layer,phase,t0,t1,dur_s,bytes,l1_hit,l1_miss,l2_hit,l2_miss\n");
    for (int i = 0; i < rows; i++) {
        const K3TraceEv *e = &g_ev[i];
        fprintf(f, "%d,%d,%s,%.6f,%.6f,%.6f,%llu,%d,%d,%d,%d\n",
                e->token, e->layer, phase_name(e->phase), e->t0, e->t1,
                e->t1 - e->t0, (unsigned long long)e->bytes,
                e->l1_hit, e->l1_miss, e->l2_hit, e->l2_miss);
    }
    fclose(f);
    fprintf(stderr, "[trace] wrote %d events to %s%s\n", rows, g_path,
            n > K3_TRACE_MAX ? " (TRUNCATED at K3_TRACE_MAX)" : "");
    g_on = 0;
    return rows;
}
