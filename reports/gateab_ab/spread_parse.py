#!/usr/bin/env python3
"""
spread_parse.py -- turn a PC run's K3_SPREAD_DBG output into the pipeline verdict.

Usage:
    K3_SPREAD_DBG=1 <engine run> 2> run.log
    python3 reports/gateab_ab/spread_parse.py run.log [--pool N] [--bw MBs]

Reads "DBG spread ... frac=" lines emitted by cache_getmany_inner phase 2, reports
the distribution of the within-burst completion spread (span/burst), and feeds the
median into overlap_sim.simulate() to predict the per-expert pipeline gain.

Verdict logic: the pipeline can only hide expert arithmetic under a read burst if
the burst's reads complete STAGGERED. If frac ~ 0 (all together) the per-expert
pipeline is worthless (0%) and should not be built. If frac is large the gain
approaches the pool-limited ceiling. This script turns one real run into that call.
"""

import re
import sys
import statistics as st
from overlap_sim import simulate, MEAS_TOKEN_S, DEV_BANDWIDTH, TOPK

LINE = re.compile(r"DBG spread L(\d+) nw=(\d+) burst=([\d.]+) first=([\d.]+) "
                  r"last=([\d.]+) span=([\d.]+) frac=([\d.]+)")

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    path = sys.argv[1]
    pool = 4                      # production default (CHIP_NWORKERS)
    bw = DEV_BANDWIDTH
    args = sys.argv[2:]
    for i, a in enumerate(args):
        if a == "--pool" and i + 1 < len(args): pool = int(args[i+1])
        if a == "--bw"   and i + 1 < len(args): bw = float(args[i+1])

    fracs, nws, bursts = [], [], []
    with open(path, errors="replace") as f:
        for ln in f:
            m = LINE.search(ln)
            if m:
                fracs.append(float(m.group(7)))
                nws.append(int(m.group(2)))
                bursts.append(float(m.group(3)))

    if not fracs:
        print(f"no 'DBG spread' lines in {path}")
        print("did the run set K3_SPREAD_DBG=1 ? (and stream experts, nw>1)")
        sys.exit(2)

    # Only full top-k bursts carry the pipeline signal; partial ones are L2 hits.
    full = [fr for fr, nw in zip(fracs, nws) if nw >= TOPK]
    use = full if full else fracs
    tag = "full top-k bursts" if full else "ALL bursts (no full top-k seen)"

    med = st.median(use)
    p10 = sorted(use)[max(0, int(0.10*len(use)) - 1)]
    p90 = sorted(use)[min(len(use)-1, int(0.90*len(use)))]
    mean = st.mean(use)

    print(f"== spread distribution ({len(use)} {tag}, from {path}) ==")
    print(f"  frac = (last-first)/burst per layer burst")
    print(f"  mean={mean:.3f}  median={med:.3f}  p10={p10:.3f}  p90={p90:.3f}")
    print(f"  mean burst={st.mean(bursts):.4f}s  mean nw={st.mean(nws):.1f}")
    print()

    print(f"== predicted per-expert pipeline gain (pool={pool}, bw={bw:.0f} MB/s) ==")
    print(f"  {'frac':>6} {'hidden%':>8} {'pred tok':>8} {'gain%':>6}")
    for label, fr in (("p10", p10), ("median", med), ("p90", p90), ("max", max(use))):
        old_w, new_w, hf, tc, rl = simulate(pool, bw, frac=fr)
        pred = MEAS_TOKEN_S - (old_w - new_w)
        gain = (MEAS_TOKEN_S - pred) / MEAS_TOKEN_S * 100
        print(f"  {label:>6} {fr:>5.2f} {hf*100:>7.1f}% {pred:>8.2f} {gain:>5.1f}%")
    print()

    # Verdict on the measured median.
    old_w, new_w, hf, tc, rl = simulate(pool, bw, frac=med)
    pred = MEAS_TOKEN_S - (old_w - new_w)
    gain = (MEAS_TOKEN_S - pred) / MEAS_TOKEN_S * 100
    if med < 0.10:
        call = ("NO-GO: reads land together (frac~0). The per-expert pipeline has "
                "no window to hide arithmetic; do NOT build the chip-path streaming "
                "refactor. Fall back to the safe down+shared variant (~2.9%) or "
                "pursue device bandwidth instead.")
    elif med < 0.30:
        call = (f"MARGINAL: frac~{med:.2f} -> only {gain:.1f}% predicted. Not worth "
                "the chip-path streaming refactor risk. Consider the safe variant.")
    else:
        call = (f"GO-ish: frac~{med:.2f} -> {gain:.1f}% predicted (ceiling is pool-"
                f"limited). Proceed to the per-expert streaming refactor on the PC "
                "and validate bit-exactness with the fixture oracle.")
    print("== VERDICT ==")
    print("  " + call)

if __name__ == "__main__":
    main()
