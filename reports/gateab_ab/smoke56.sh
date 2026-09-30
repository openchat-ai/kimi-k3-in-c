#!/bin/bash
# Smoke the rebuilt counters. Short run, and check the new figures are self-consistent
# rather than merely present: sleep must be under nworkers*wall, bytes per group must sum
# to the tier total, and the short-read flag must not be set on a healthy run.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v56_counters
LOG="$OUT/smoke-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG"

./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 1 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
rc=$?
echo "exit=$rc"
grep -aE "^kio tier|^      group|s/token average" "$LOG/ctrl.log" | sed 's/^/  /'

echo
echo "== consistency checks"
python3 - "$LOG/ctrl.log" <<'PY'
import re, sys
txt = open(sys.argv[1], encoding='utf-8', errors='replace').read()
m = re.search(r'kio tier0: (.*)', txt)
if not m:
    print("  no tier0 line -- counters did not print"); sys.exit(1)
body = m.group(1)
g = lambda k, d=0.0: float(re.search(k + r' ([0-9.]+)', body).group(1)) if re.search(k + r' ([0-9.]+)', body) else d
reqs   = g('reqs,') if False else float(re.search(r': (\d+) reqs', body).group(1))
gb     = float(re.search(r': (\d+) reqs, ([0-9.]+) GB', body).group(2))
per    = float(re.search(r'per-stream ([0-9.]+) MB/s', body).group(1))
agg    = float(re.search(r'aggregate ([0-9.]+) MB/s', body).group(1))
conc   = float(re.search(r'concurrency ([0-9.]+)x', body).group(1))
sleep  = float(re.search(r'sleep ([0-9.]+) s in', body).group(1))
waits  = float(re.search(r'in (\d+) waits', body).group(1))
pct    = float(re.search(r'\((\d+)% of worker-time', body).group(1))
short  = 'SHORT/FAILED' in body

print(f"  per-stream {per:.0f}  aggregate {agg:.0f}  concurrency {conc:.1f}x")
print(f"  sleep {sleep:.1f}s over {waits:.0f} waits = {pct:.0f}% of worker-time")

# aggregate should be per-stream * concurrency, by construction
implied = per * conc
ok1 = abs(implied - agg) / agg < 0.06
print(f"  per-stream x concurrency = {implied:.0f} vs aggregate {agg:.0f}  "
      f"{'OK' if ok1 else 'MISMATCH'}")

ok2 = (not short)
print(f"  short/failed reads flagged: {short}  {'OK' if ok2 else 'SUSPECT'}")

# per-group bytes must add up to the tier total
gs = [float(x) for x in re.findall(r'group\d: (\d+) reqs, ([0-9.]+) GB', txt) for x in [x[1]]]
s = sum(gs)
ok3 = abs(s - gb) / gb < 0.02
print(f"  groups sum {s:.2f} GB vs tier {gb:.2f} GB  {'OK' if ok3 else 'MISMATCH'}")

# sleep must be a real fraction of worker-time: 0 and >100 are both impossible readings
ok4 = 0 < pct <= 100
print(f"  worker-time {pct:.0f}% in (0,100]  {'OK' if ok4 else 'IMPOSSIBLE'}")
sys.exit(0 if (ok1 and ok2 and ok3 and ok4) else 1)
PY
echo "  checks exit=$?"
