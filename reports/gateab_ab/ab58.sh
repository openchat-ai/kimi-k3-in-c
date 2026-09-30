#!/bin/bash
# ab58.sh -- the mixed ceiling, paired against the engine that has to live under it.
#
# v49 alternated a device arm and an engine arm three times to share thermal state, which
# was the right idea. But steady47's device arm read the expert file alone, while the engine
# arm it was compared against streamed the trunk on its reader thread at the same time. So
# the 6.2x it reported was an expert-only device against a mixed engine, and steady47.c's own
# header had already objected to exactly that kind of window mismatch one level down.
#
# steady58 fixes the arm, not the clock: the same 210 s, the same O_DIRECT scattered-slot
# expert lanes steady47 used, plus a trunk lane reading whole layer files in order, both
# continuous and unpaced -- which is the mix k3_run actually asks of the device. Three pairs,
# device first each time, pairwise ratios reported, engine aggregate taken from its own kio
# counter line (bytes delivered over the run) rather than re-derived from the ledger.
#
# What a result means:
#   aggregate near the engine's 891 MB/s   -> the engine is at the mixed ceiling, the disk is
#                                            the wall, and cross-layer pipelining buys nothing
#   aggregate well above it               -> the engine leaves throughput on the table and the
#                                            pool's 40-49% sleep plus per-layer idle is the
#                                            recoverable part
# There is no third reading, and the trunk column is reported separately precisely so the
# expert number can be compared with steady47's expert-only figures.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v58_mix
mkdir -p "$OUT"

# The engine config is the one that produced 65.21 / 75.62 / 79.91: trunk-gb 32, cache-gb 15.
ENG_GEN=3
DEV_S=210

# steady58 must be built against the same tree the engine comes from. It links nothing from
# the engine on purpose -- it is a device probe, not an engine component.
cc -O2 -std=gnu99 -Wall -Wextra -pthread \
   reports/gateab_ab/steady58.c -o "$OUT/steady58" || { echo "BUILD FAILED"; exit 1; }

# Fail the build step loudly rather than shipping a probe that has never run. The self-test
# wants a real filesystem for O_DIRECT; TMPDIR unset would put it on the repo mount.
TMPDIR=${TMPDIR:-/tmp}
export TMPDIR
"$OUT/steady58" --selftest 2>&1 | tee "$OUT/selftest.txt"
grep -q "SELFTEST OK" "$OUT/selftest.txt" || { echo "SELFTEST FAILED -- refusing to run"; exit 1; }
rm -rf "$TMPDIR/steady58_selftest"   # ~76 MB of scratch; the tee above is the evidence

# Engine aggregate MB/s from the previous best-config runs, for steady58's ratio line. Left at
# 0 the probe omits the ratio entirely rather than comparing against a stale number.
ENG_MBPS=${ENG_MBPS:-891}
export K3P_ENGINE_MBPS="$ENG_MBPS"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{
  echo "start : $(date +%T)"
  echo "load  : $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "engine reference: ${ENG_MBPS} MB/s aggregate"
} > "$OUT/state.txt"

for pair in 1 2 3; do
  D="$OUT/dev$pair"; mkdir -p "$D"
  echo "[v58] pair $pair  MIXED DEVICE first  $(date +%T)"
  "$OUT/steady58" "$DEV_S" 2>&1 | tee "$D/run.txt" | tail -6

  E="$OUT/eng$pair"; mkdir -p "$E"
  echo "[v58] pair $pair  ENGINE              $(date +%T)"
  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0
  ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --trunk-gb 32 --cache-gb 15 \
    --ids 1008 --gen "$ENG_GEN" --out "$E/ctrl.json" > "$E/ctrl.log" 2>&1
  grep -aE "s/token average|hit I/O|read from disk|trunk stream|kio tier0|group0|group1" \
    "$E/ctrl.log" | sed 's/^/    /' | tee "$E/ledger.txt"
  echo "[v58] pair $pair done $(date +%T)"
  sleep 30
done

echo "end   : $(date +%T)" >> "$OUT/state.txt"

# Pairwise ratios: device-mix aggregate over engine aggregate, per pair, next to each other.
python3 - "$OUT" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
rows = []
for pair in (1, 2, 3):
    dev = (out / f"dev{pair}" / "run.txt").read_text(errors="replace")
    eng = (out / f"eng{pair}" / "ledger.txt").read_text(errors="replace") if (out / f"eng{pair}" / "ledger.txt").exists() else ""
    m = re.search(r"aggregate ([\d.]+) GB = (\d+) MB/s", dev)
    if not m:
        rows.append((pair, None, None, None, None)); continue
    dev_trunk = re.search(r"trunk\s+[\d.]+ GB in [\d.]+ s = (\d+) MB/s", dev)
    dev_exp = re.search(r"expert\s+\d+ slots, [\d.]+ GB in [\d.]+ s = (\d+) MB/s", dev)
    e = re.search(r"aggregate (\d+) MB/s", eng)
    eng_spt = re.search(r"([\d.]+) s/token average", eng)
    rows.append((pair, int(m.group(2)),
                 int(dev_trunk.group(1)) if dev_trunk else None,
                 int(dev_exp.group(1)) if dev_exp else None,
                 int(e.group(1)) if e else None,
                 float(eng_spt.group(1)) if eng_spt else None))
lines = ["pair  mix_agg  trunk  expert | engine_agg  s/tok | ratio"]
for r in rows:
    pair, agg, tr, ex, ea, spt = r
    if agg is None:
        lines.append(f"{pair}  (probe output missing)")
        continue
    ratio = f"{agg/ea:.2f}x" if ea else "-"
    lines.append(f"{pair:>4}  {agg:>7}  {tr if tr else '-':>5}  {ex if ex else '-':>6} |"
                 f" {ea if ea else '-':>10}  {spt if spt else '-':>5} | {ratio:>6}")
print("\n".join(lines))
(out / "ratios.txt").write_text("\n".join(lines) + "\n")
PY
cat "$OUT/state.txt"