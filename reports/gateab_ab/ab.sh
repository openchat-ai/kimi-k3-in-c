#!/bin/bash
# gate A/B box-closing: V0 current-binary default baseline, V2 cache-steal
# (explicit --trunk-gb 5.5 --cache-gb 16.8, no --preset so budget_auto stays 0)
# kio stays ON (well-established: 81-83 vs legacy-gate 83-85).
set -u
echo "[ab] start $(date +%T)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[ab] FATAL: nvme unavailable"; exit 9; }
fi

cd /mnt/f/kimi-k3-in-c
[ -x ./bin/k3 ] || { echo "[ab] FATAL: ./bin/k3 missing"; exit 9; }

runvar () {
  NAME=$1; shift
  LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/$NAME-$(date +%Y%m%d_%H%M%S)
  mkdir -p "$LOG"
  echo "[ab] $NAME -> $LOG"
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
  unset K3_NOKIO
  /usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --ids 1008 --gen 8 --out "$LOG/ctrl.json" "$@" > "$LOG/ctrl.log" 2>&1
  RC=$?
  echo "EXIT=$RC NAME=$NAME"
  {
    echo "--- $NAME (extra: $*)"
    grep -aE "auto budget|explicit budget|trunk .* GB|expert cache|pinned .*/93|s/token average|I/O share|experts, whole|parked on the expert gate|phase2|pread\)" "$LOG/ctrl.log" | tail -12
    grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
    grep -aE "peak_rss_bytes|seconds_per_token" "$LOG/ctrl.json"
  } > "$LOG/summary.txt"
  cat "$LOG/summary.txt"
}

runvar v0_base
runvar v2_cache16.8 --trunk-gb 5.5 --cache-gb 16.8
echo "[ab] end $(date +%T)"