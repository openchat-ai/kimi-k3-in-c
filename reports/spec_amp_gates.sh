#!/bin/bash
# spec-amp empirical probe on a REAL prompt (gates.txt, 4151 ids, 37% draft fire
# per tools/rep_estimate.awk). Protocol mirrors tools/verify_spec_amp.sh stage 4:
#   --spec K --incremental --layer-bundle --loop-serial 1 --loop-block 4
# plus the gateAB page-cache-drop discipline (drop_caches per run) so each run
# re-reads the cold trunk (859 MB/s) instead of riding RAM.
set -u

for try in 1 2 3 4 5; do
  if mountpoint -q /mnt/nvme 2>/dev/null; then break; fi
  if [ -d /mnt/wsl/PHYSICALDRIVE2p7 ]; then
    mkdir -p /mnt/nvme; mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme 2>/dev/null
    mountpoint -q /mnt/nvme && break
  fi
  echo "[bg] nvme attempt $try failed, retrying in 5s"
  sleep 5
done
mountpoint -q /mnt/nvme || { echo "[bg] FATAL: nvme unavailable"; exit 9; }

LOG=/mnt/f/kimi-k3-in-c/reports/spec_gates_$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG"
echo "[bg] LOGDIR=$LOG"

cd /mnt/f/kimi-k3-in-c
# ids payload: gates fixture truncated to 1024 tokens (KV 2.4 GB) so the
# 28.6 GB box passes the REFUSING guard. --trunk-gb/--cache-gb are given both
# so the layer-bundle planner does not override them with its auto budget
# (autobudget trunk 6.0 / expert 13.8 pushed total to 28.23 vs 27.2 cap).
./bin/test_tok /model encodefile tests/fixtures/gates/gates.txt | tr ',' '\n' > "$LOG/gates_full.ids"
head -1024 "$LOG/gates_full.ids" > "$LOG/gates.ids"
N=$(wc -l < "$LOG/gates.ids")
echo "[bg] gates.ids tokens=$N (truncated from full)"

SPECS="${SPECS:-4 8}"
for K in $SPECS; do
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
  echo "[bg] spec K=$K run start $(date +%T)"
  /usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --ids "$(cat "$LOG/gates.ids")" --gen 8 \
    --spec "$K" --incremental --layer-bundle \
    --trunk-gb 9 --cache-gb 4 \
    --loop-serial 1 --loop-block 4 \
    --out "$LOG/spec$K.json" > "$LOG/spec$K.log" 2>&1
  echo "[bg] spec K=$K EXIT=$?"
done

{
  echo "--- spec-amp gates probe (real prompt, cold cache each run)"
  for K in $SPECS; do
    grep -aE "s/token average|I/O share|--spec|mean accepted|TRUE resident|pinned .*/93|spec_draft|speedup" "$LOG/spec$K.log" | tail -8 | sed "s/^/[K=$K] /"
    grep -aE "^TIME_ELAPSED" "$LOG/spec$K.log" | sed "s/^/[K=$K] /"
  done
} > "$LOG/summary.txt"
cat "$LOG/summary.txt"
echo "[bg] end $(date +%T)"