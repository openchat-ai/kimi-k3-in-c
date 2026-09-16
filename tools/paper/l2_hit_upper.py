#!/usr/bin/env python3
"""Replay the expert trace against a large L2 (no eviction) and report, per token,
the L2 hit rate *across tokens* (a key present from an earlier token is a hit).
Answers: can an L2 that holds everything hit 90%+ for this workload?"

Usage: l2_hit_upper.py [trace.bin]
  default trace: tests/fixtures/expert_trace.bin (the paper's original capture,
  100,096 records = 68 real tokens x 1472 requests/token; derived by replaying
  the request stream grouped into 92-layer passes, see struct_check.py).
"""
import struct, sys, os

DEFAULT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                       "tests", "fixtures", "expert_trace.bin")
path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
raw = open(path, 'rb').read()
assert len(raw) % 8 == 0, len(raw)
n = len(raw)//8
keys = []
for i in range(n):
    layer, expert = struct.unpack_from('<ii', raw, i*8)
    keys.append((layer, expert))
tok = 1472
nt = n//tok
seen = set()
for t in range(nt):
    seg = keys[t*tok:(t+1)*tok]
    hits = sum(1 for k in seg if k in seen)
    new = [k for k in seg if k not in seen]
    seen.update(seg)
    print(f"token {t}: req={len(seg)} cross-token L2 hits={hits} ({100.0*hits/len(seg):.1f}%) "
          f"new={len(new)} distinct-so-far={len(seen)}")
print(f"total distinct keys over run: {len(seen)}")