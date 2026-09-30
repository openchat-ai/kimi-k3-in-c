#!/bin/bash
# The checker failed on a regex, not on the data. The tier line wraps in the log because
# the engine wraps its own output, so re-join the physical line before parsing.
set -u
cd /mnt/f/kimi-k3-in-c
LOG=$(ls -td reports/gateab_ab/v56_counters/smoke-* | head -1)
echo "log: $LOG"
tr '\n' ' ' < "$LOG/ctrl.log" > /tmp/joined.log

python3 - <<'PY'
import re
txt = open('/tmp/joined.log', encoding='utf-8', errors='replace').read()
m = re.search(r'kio tier0: (\d+) reqs, ([0-9.]+) GB delivered \| per-stream ([0-9.]+) MB/s, '
              r'aggregate ([0-9.]+) MB/s, concurrency ([0-9.]+)x \| queue ([0-9.]+) s '
              r'\(([0-9.]+)% of io\), submit-lock ([0-9.]+) s, worker-lock ([0-9.]+) s, '
              r'sleep ([0-9.]+) s in (\d+) waits \(([0-9.]+)% of worker-time\)', txt)
if not m:
    raise SystemExit("tier0 line still does not match; print it verbatim")
(reqs, gb, per, agg, conc, q, qp, sub, lk, slp, waits, wpct) = m.groups()
reqs, gb, per, agg, conc = int(reqs), float(gb), float(per), float(agg), float(conc)
q, qp, sub, lk, slp, waits, wpct = float(q), float(qp), float(sub), float(lk), float(slp), int(waits), float(wpct)

groups = [(int(a), float(b)) for a, b in re.findall(r'group(\d+): (\d+) reqs, ([0-9.]+) GB', txt) and
          [(m2.group(1), m2.group(3)) for m2 in re.finditer(r'group(\d+): (\d+) reqs, ([0-9.]+) GB', txt)]]
gbytes = [float(b) for _, b in groups]

print(f"  tier0   {reqs} reqs  {gb:.2f} GB")
print(f"  rates   per-stream {per:.0f}  aggregate {agg:.0f}  concurrency {conc:.1f}x")
print(f"  waits   {q:.1f}s queue ({qp:.1f}% of io)  {sub:.1f}s submit-lock  {lk:.1f}s worker-lock")
print(f"  sleep   {slp:.1f}s in {waits} waits = {wpct:.0f}% of worker-time")
for i, (gi, gb_i) in enumerate(groups):
    print(f"  group{gi}  {gb_i:.2f} GB")

fails = []
implied = per * conc
if abs(implied - agg) / agg > 0.06:
    fails.append(f"per-stream x concurrency = {implied:.0f} != aggregate {agg:.0f}")
if abs(sum(gbytes) - gb) / gb > 0.02:
    fails.append(f"groups sum {sum(gbytes):.2f} != tier {gb:.2f}")
if not 0 < wpct <= 100:
    fails.append(f"worker-time {wpct:.0f}% outside (0,100]")
if 'SHORT/FAILED' in txt:
    fails.append("short or failed reads reported on a healthy run")

print()
for f in fails:
    print("  FAIL:", f)
print("  all checks passed" if not fails else f"  {len(fails)} failed")
PY
