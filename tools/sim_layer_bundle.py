#!/usr/bin/env python
"""
sim_layer_bundle.py - unified layer-bundle cache vs the split trunk+expert cache.

THE QUESTION
    Which per-token disk volume does k3 actually move to reach a decode step, and what
    does a "one pool, one key, key = layer" design change about that number? This replays
    a recorded (layer, expert) trace and answers it in GB/token before any C is written.

THE TWO MODELS
    split    what the engine does today. The trunk owner pins a few prefix layers and
             streams the rest with a small ring (cyclic scan, so ring slots never help
             across tokens); the expert arena holds the remainder of the budget with a
             heat-eviction replay of the trace (the measured shape: arena < one token's
             distinct set, so it churns within a token and retention is low).
    unified  one pool, key = layer. A resident layer serves its trunk AND its requested
             experts from RAM; because the walker visits every layer once per token, a
             resident layer of the 93 always saves its full footprint. The resident set
             is chosen by static footprint (largest trunk+experts first), which is
             knowable ahead (trunk.json + one probe pass), never touches disk again, and
             is exactly the trunk cache's pin-prefix idea generalised to the whole layer.

usage: sim_layer_bundle.py trace.bin [--trunk-gb 56.6] [--expert-bytes 17547264]
       [--n-layers 93] [--layer0-gb 3.0] [--disk-mbs 1300] [--sweep "10,14,18,22,26,28"]
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict

import numpy as np

EXPERT_BYTES = 17_547_264


def segment_tokens(pairs):
    """Split (layer, expert) pairs into tokens. The walker visits layers in ascending
    order every token, so a token boundary is whenever the layer index stops ascending."""
    layers = pairs[:, 0]
    toks = []
    start = 0
    prev = -1
    for i in range(len(layers)):
        if layers[i] < prev and i > start:    # strict decrease: 92 -> 1 wrap, new token
            toks.append(pairs[start:i])
            start = i
        prev = layers[i]
    if start < len(pairs):
        toks.append(pairs[start:])
    return toks


def heat_sim(keys, cap):
    """Expert arena replay: evict lowest cumulative request count (ties by least
    recently used). Returns hits. This is the engine's K3_L1 heat policy.

    Bucketed by count so a miss pays O(1) instead of a O(cap) victim scan."""
    from collections import defaultdict
    count = {}
    stamp = {}                       # monotone request tick per key
    bucket = defaultdict(dict)       # count -> {key: stamp}
    resident = 0
    hits = 0
    now = 0
    cur = 1
    for k in keys:
        now += 1
        c = count.get(k, 0) + 1
        count[k] = c
        if k in stamp:               # resident hit
            del bucket[c - 1][k]
            bucket[c][k] = now
            stamp[k] = now
            hits += 1
            continue
        if resident >= cap:
            while not bucket[cur]:
                cur += 1
            victim = min(bucket[cur], key=bucket[cur].get)
            del bucket[cur][victim]
            del stamp[victim]
            resident -= 1
            if not bucket[cur]:
                cur += 1
        bucket[c][k] = now
        stamp[k] = now
        resident += 1
        if c < cur:
            cur = c
    return hits


def footprint_pin(n_layers, trunk_bytes, distinct_per_layer,
                  budget_bytes, expert_bytes):
    """Choose the resident layer set by static footprint (largest first). Returns a set
    of layer ids and the total RAM they cost."""
    foot = []
    for L in range(n_layers):
        foot.append((trunk_bytes[L] + distinct_per_layer[L] * expert_bytes, L))
    foot.sort(reverse=True)
    sel, used = set(), 0
    for f, L in foot:
        if used + f <= budget_bytes:
            sel.add(L)
            used += f
    return sel, used


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--trunk-gb", type=float, default=56.6,
                    help="packed trunk bytes read per token (measured 56.60 GB)")
    ap.add_argument("--expert-bytes", type=int, default=EXPERT_BYTES)
    ap.add_argument("--n-layers", type=int, default=93)
    ap.add_argument("--layer0-gb", type=float, default=3.0,
                    help="layer 0 is the dense MLP; heavier than a normal layer")
    ap.add_argument("--disk-mbs", type=float, default=1300.0,
                    help="measured sustained sdd7 aggregate, for the time column")
    ap.add_argument("--sweep", default="10,14,18,22,26,28",
                    help="RAM budget (GB) sweep for both models")
    a = ap.parse_args()

    raw = np.fromfile(a.trace, dtype=np.int32)
    if raw.size % 2:
        sys.exit("trace is not an even number of int32")
    pairs = raw.reshape(-1, 2)
    toks = segment_tokens(pairs)
    n = len(toks)
    pairs = np.concatenate(toks) if n else pairs
    layers, experts = pairs[:, 0], pairs[:, 1]
    keys = (layers.astype(np.int64) << 20) | experts.astype(np.int64)

    print("trace: %d requests, %d tokens, layers %d..%d" %
          (len(keys), n, layers.min(), layers.max()))

    trunk_tot = int(a.trunk_gb * 1e9)
    layer0 = int(a.layer0_gb * 1e9)
    tail = (trunk_tot - layer0) / max(a.n_layers - 1, 1)
    trunk_bytes = np.array([layer0 if L == 0 else tail
                            for L in range(a.n_layers)], dtype=np.int64)

    # distinct experts requested per layer, averaged over tokens
    dist = {}                          # (layer) -> set of experts per token
    for t in toks:
        seen = set()
        for L, e in t.tolist():
            seen.add(L)
            dist.setdefault(L, set()).add(int(e))
    # distinct_per_layer mean
    cntL = Counter()
    sumL = Counter()
    for t in toks:
        tl = [int(L) for L, _ in t.tolist()]
        for L, cnt in Counter(tl).items():
            cntL[L] += 1
            sumL[L] += cnt
    distinct_per_layer = [sumL[L] / max(cntL[L], 1) for L in range(a.n_layers)]

    expert_tot_tok = sum(v for v in sumL.values()) / max(n, 1) * a.expert_bytes
    print("unified bundle: trunk %.2f GB + experts %.2f GB = %.2f GB/token (%.2f GB/layer avg)"
          % (a.trunk_gb, expert_tot_tok / 1e9, (a.trunk_gb + expert_tot_tok / 1e9),
             (a.trunk_gb + expert_tot_tok / 1e9) / a.n_layers))

    GB = 1e9
    print("\n%-7s | %-28s | %-28s" % ("RAM", "split (trunk+expert arena)", "unified (layer bundle)"))
    print("%-7s | %-13s %-14s | %-13s %-14s" % (
        "(GB)", "GB read/tok", "sec/tok @%.0fMB/s" % a.disk_mbs,
        "GB read/tok", "sec/tok @%.0fMB/s" % a.disk_mbs))
    print("-" * 78)
    # per-token disk volume for the split cache (heat expert replay)
    tr = trunk_bytes.tolist()
    keysl = keys.tolist()
    for gb in [float(x) for x in a.sweep.split(",")]:
        budget = int(gb * GB)
        # split: trunk floor 6 GB pins the heaviest prefix it can hold, rest to experts
        trunk_budget = 6 * GB
        trunk_pin = []
        used = 0
        for f, L in sorted(((tr[L], L) for L in range(a.n_layers)), reverse=True):
            if used + f <= trunk_budget:
                trunk_pin.append(L)
                used += f
        trunk_disk_tok = a.trunk_gb - sum(tr[L] for L in trunk_pin) / GB
        exp_budget = budget - 6 * GB
        exp_cap = max(exp_budget // a.expert_bytes, 1)
        hits = heat_sim(keysl, exp_cap)
        expert_disk_tok = (len(keysl) - hits) * a.expert_bytes / GB / n
        split_gb = trunk_disk_tok + expert_disk_tok
        split_s = split_gb * 1000.0 / a.disk_mbs

        # unified: pin the largest-footprint layers in one pool
        sel, _ = footprint_pin(a.n_layers, tr, distinct_per_layer,
                               budget, a.expert_bytes)
        trunk_disk_u = a.trunk_gb - sum(tr[L] for L in sel) / GB
        exp_disk_u = (sum(sumL[L] for L in range(a.n_layers) if L not in sel) /
                      max(n, 1) * a.expert_bytes / GB)
        uni_gb = trunk_disk_u + exp_disk_u
        uni_s = uni_gb * 1000.0 / a.disk_mbs
        print("%-7s | %-13.2f %-14.2f | %-13.2f %-14.2f   (%d layers resident)"
              % (gb, split_gb, split_s, uni_gb, uni_s, len(sel)))
    print("-" * 78)
    print("split = trunk pins a 6 GB prefix (streams the rest, cyclic ring never helps)\n"
          "        + expert arena heat replay of this trace.\n"
          "unified = one pool keyed by layer; resident layers serve trunk AND experts\n"
          "        from RAM; all 93 layers requested each token, so a resident layer\n"
          "        always saves its full footprint.\n"
          "sec/tok is I/O only; compute overlaps in a real loop.")
    return 0


if __name__ == "__main__":
    sys.exit(main())