#!/usr/bin/env python3
"""
overlap_sim.py -- zero-risk timing model for the expert read/compute pipeline.

Question it answers, with no weights and no NVMe: if the expert matmuls for a
layer are submitted to the compute pool AS SOON AS each expert's 17.55 MB read
lands (instead of after the whole top-16 burst completes), what fraction of the
7.34 s/tok of expert arithmetic can hide under the read burst, and what is the
predicted token time?

Everything is driven by MEASURED components (ab56 accounting, v49/steady47
shapes) and by real config dims. Absolute s/tok still needs the PC; this bounds
the mechanism and shows where it degrades.

Device model: one shared-bandwidth NVMe. In-flight reads share Bd equally; a read
completes when it has accrued S bytes. This reproduces the observed behaviour
that equal-size O_DIRECT reads finish clustered near the end of a burst.

Compute model: a pool of P workers; each expert's chain takes tc seconds of one
worker. Jobs queue as reads land (NEW) or all start after the burst (OLD).

Two structures, same bytes, same compute:
  OLD  per MoE layer: issue 16 reads, wait for ALL, then run 16 chains on pool.
  NEW  per MoE layer: issue 16 reads; when read i lands, queue chain i; layer
       ends when the last chain finishes. Read and compute overlap.
"""

import heapq

# ---- real config / shapes -------------------------------------------------
LAYERS_MOE   = 92          # first_dense=1, of 93 total
TOPK         = 16
EXPERT_MB    = 17.55       # slot_bytes ~ 17.55 MB, measured (v49/steady47)
LATENT       = 3584
MOE_INTER    = 3072
HIDDEN       = 7168
N_SHARED     = 2           # shared intermediate = moe_inter*n_shared
SHARED_INTER = MOE_INTER * N_SHARED

# ---- measured components (ab56 accounting, per token) ---------------------
MEAS_TOKEN_S   = 65.21     # best serial wall, s/tok
MEAS_COMP_S     = 7.34     # expert arithmetic on the critical path, s/tok
MEAS_DEV_BYTES  = 72.22e3  # trunk+expert bytes moved per token, MB
MEAS_DEV_BUSY_S = None     # solved from the two above (see below)

# MAC counts per token, split by "does it depend on an expert's bytes?"
def macs():
    routed = 3 * LATENT * MOE_INTER * TOPK * LAYERS_MOE
    shared = 3 * HIDDEN * SHARED_INTER * LAYERS_MOE
    proj   = 2 * HIDDEN * LATENT * LAYERS_MOE
    return routed, shared, proj

# ---- device busy time ----------------------------------------------------
# During the 7.34 s of arithmetic the device idles, so the streaming device is
# busy for (wall - arithmetic). Effective mixed bandwidth when busy:
DEV_BANDWIDTH = MEAS_DEV_BYTES / (MEAS_TOKEN_S - MEAS_COMP_S)   # MB/s
MEAS_DEV_BUSY_S = MEAS_TOKEN_S - MEAS_COMP_S

def chain_time(pool, target_comp_s):
    """Per-expert single-worker chain time so that OLD pool makespan/token ==
    target. Pools are integer, n=TOPK jobs per layer."""
    per_layer_makespan = target_comp_s / LAYERS_MOE
    waves = max(1, -(-TOPK // pool))          # ceil(n/pool)
    return per_layer_makespan / waves

def burst_time(bandwidth, nreads=TOPK, size=EXPERT_MB, conc=TOPK):
    """Shared-bandwidth event model: bytes accrue at Bd/inflight per read."""
    inflight = []      # (finish_time, remaining_bytes)
    t = 0.0
    # issue reads in small dt steps; all start together at layer start
    remaining = [size] * nreads
    # simulate: all nreads issued at t=0, share bandwidth
    # completion time of read i = time to serve its size given fair sharing
    # With n reads sharing, each gets Bd/n until fewer remain.
    served_order = sorted(range(nreads))     # equal sizes -> symmetric
    active = nreads
    t = 0.0
    served = 0.0
    # total bytes to serve; time to finish all = nreads*size/Bd (device saturated)
    # per-read finish: when cumulative served reaches (i+1)*size at rate Bd*min(1,active/active)
    # For equal sizes all finish together at total/Bd once saturated. Model:
    finish = []
    if active <= 0:
        return 0.0
    # simple closed form: all n reads issued together, share equally, so each
    # finishes at n*size/Bd (they all accrue at Bd/n). Stagger only if a
    # concurrency cap limits in-flight reads to `conc`.
    cap = min(conc, nreads)
    if cap >= nreads:
        return nreads * size / bandwidth
    # capped concurrency: reads in waves of `cap`
    total = 0.0
    done = 0
    while done < nreads:
        wave = min(cap, nreads - done)
        total += wave * size / bandwidth
        done += wave
    return total

def simulate(pool, bandwidth, conc=TOPK, frac=0.0):
    """Event sim over all MoE layers. frac in [0,1] is the fraction of the burst
    over which the TOPK reads' COMPLETIONS are spread (0 = all land together,
    the shared-bandwidth limit; measured directly as span/burst by
    K3_SPREAD_DBG in k3_cache.c). Returns
    (old_wall, new_wall, hidden_frac, tc, read_layer)."""
    tc = chain_time(pool, MEAS_COMP_S)
    read_layer = burst_time(bandwidth, TOPK, EXPERT_MB, conc)

    # ---- OLD: read all, then compute all ----
    old_wall = LAYERS_MOE * (read_layer + max(1, -(-TOPK // pool)) * tc)

    # ---- NEW: stream compute as reads land ----
    # read completion times WITHIN a layer, relative to its start, spread so
    # that (max-min)/read_layer == frac, matching the measured quantity.
    cap = min(conc, TOPK)
    if cap >= TOPK:
        if frac <= 0.0:
            read_times = [read_layer] * TOPK          # all land together
        else:
            # The device finishes delivering at read_layer, so the LAST read
            # completes exactly at read_layer; completions spread back over
            # frac*read_layer so (max-min)/read_layer == frac. Compute for a
            # read that lands early hides under the reads still in flight.
            read_times = [read_layer * (1.0 - frac + frac * i / (TOPK - 1))
                          for i in range(TOPK)]
    else:
        read_times = []
        t = 0.0
        done = 0
        while done < TOPK:
            wave = min(cap, TOPK - done)
            fin = t + wave * EXPERT_MB / bandwidth
            read_times.extend([fin] * wave)
            t = fin
            done += wave
    read_times.sort()

    free = [0.0] * pool        # absolute time each worker next frees up
    now = 0.0
    for _ in range(LAYERS_MOE):
        layer_start = now
        for rt in read_times:
            wi = min(range(pool), key=lambda k: free[k])
            read_done = layer_start + rt
            start = max(free[wi], read_done)
            free[wi] = start + tc
        now = max(free)        # layer ends when its last chain finishes
    new_wall = now

    read_sum = LAYERS_MOE * read_layer
    comp_new_exposed = max(0.0, new_wall - read_sum)
    hidden_frac = 1.0 - (comp_new_exposed / MEAS_COMP_S) if MEAS_COMP_S else 0.0
    return old_wall, new_wall, hidden_frac, tc, read_layer

def main():
    r, s, p = macs()
    print("== config / shapes ==")
    print(f"  MoE layers={LAYERS_MOE} topk={TOPK} expert={EXPERT_MB} MB")
    print(f"  routed/shared/proj MAC per token: {r/1e9:.1f}G / {s/1e9:.1f}G / {p/1e9:.1f}G")
    print(f"  (routed share of MoE matmul: {r/(r+s+p)*100:.0f}%)")
    print()
    print("== measured calibration ==")
    print(f"  token wall        = {MEAS_TOKEN_S:.2f} s")
    print(f"  expert compute    = {MEAS_COMP_S:.2f} s  (on critical path today)")
    print(f"  device bytes/tok  = {MEAS_DEV_BYTES/1e3:.1f} GB")
    print(f"  device busy       = {MEAS_DEV_BUSY_S:.2f} s")
    print(f"  eff mixed bw      = {DEV_BANDWIDTH:.0f} MB/s (busy)")
    print()

    print("== per-token prediction: OLD vs NEW (expert phase), frac=0 ==")
    print(f"{'pool':>4} {'read/layer':>10} {'OLD exp':>8} {'NEW exp':>8} {'hidden%':>7} {'pred tok':>8} {'gain%':>6}")
    for pool in (2, 4, 8, 12, 16):
        old_w, new_w, hf, tc, rl = simulate(pool, DEV_BANDWIDTH, frac=0.0)
        save = (old_w - new_w)
        pred_tok = MEAS_TOKEN_S - save
        gain = (MEAS_TOKEN_S - pred_tok) / MEAS_TOKEN_S * 100
        print(f"{pool:>4} {rl:>10.4f} {old_w/LAYERS_MOE:>8.4f} {new_w/LAYERS_MOE:>8.4f} "
              f"{hf*100:>6.1f}% {pred_tok:>8.2f} {gain:>5.1f}%")
    print()
    print("== THE decisive variable: within-burst completion SPREAD (pool=8) ==")
    print("   frac=0 -> all 16 reads land together (shared-bandwidth limit): no window")
    print("   measured live by K3_SPREAD_DBG (span/burst) in k3_cache.c")
    pool = 8
    for frac in (0.0, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0):
        old_w, new_w, hf, tc, rl = simulate(pool, DEV_BANDWIDTH, frac=frac)
        save = (old_w - new_w)
        pred_tok = MEAS_TOKEN_S - save
        gain = (MEAS_TOKEN_S - pred_tok) / MEAS_TOKEN_S * 100
        print(f"  frac={frac:>4.2f}  hidden={hf*100:5.1f}%  pred tok={pred_tok:6.2f}  gain={gain:5.1f}%")
    print()
    print("== frac x device bandwidth (pool=8): gain% ==")
    hdr = "  frac  |" + "".join(f"{b:>7}" for b in (1000,1250,1500,2000,2500))
    print(hdr)
    for frac in (0.0, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0):
        row = f"  {frac:>4.2f} |"
        for bw in (1000, 1250, 1500, 2000, 2500):
            old_w, new_w, hf, tc, rl = simulate(pool, bw, frac=frac)
            gain = ((old_w - new_w)) / MEAS_TOKEN_S * 100
            row += f"{gain:>7.1f}"
        print(row)
    print()
    print("== 'safe' variant: only hide independent down+shared ==")
    r, s, p = macs()
    indep = (s + p)
    frac = indep / (r + s + p)
    safe_comp = MEAS_COMP_S * frac
    safe_tok = MEAS_TOKEN_S - safe_comp
    print(f"  independent (down+shared) share of matmul = {frac*100:.0f}%")
    print(f"  hideable compute = {safe_comp:.2f} s -> pred tok = {safe_tok:.2f} s "
          f"(gain {(MEAS_TOKEN_S-safe_tok)/MEAS_TOKEN_S*100:.1f}%)")
    print()
    print("NOTE: model only. Bit-exactness must be checked with the fixture")
    print("oracle; absolute s/tok requires the real PC + NVMe run.")

if __name__ == "__main__":
    main()
