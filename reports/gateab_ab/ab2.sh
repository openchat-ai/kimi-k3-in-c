#!/bin/bash
# Attribution A/B: is the kio phase2 group-parking (61cf381/2e220d9) the 141s regression?
#   v0_repeat: kio default (parks trunk group) -> expect ~141 (repro of the regression)
#   v1_nokio : K3_NOKIO=1 legacy gate          -> expect ~85 (parking gone)
# Anchors (morning pre-park binary): kio 81.3-82.4 (parked 0.00s), legacy 83.0-85.0.
set -u
echo "[ab2] start $(date +%T) load=$(cut -d' ' -f1-3 /proc/loadavg) nproc=$(grep -c ^processor /proc/cpuinfo)"

if ! mountpoint -q /mnt/nvme 2>/dev/null; then
  for i in /mnt/wsl/PHYSICALDRIVE2p7; do
    [ -d "$i" ] && { mkdir -p /mnt/nvme; mount --bind "$i" /mnt/nvme; break; }
  done
  mountpoint -q /mnt/nvme || { echo "[ab2] FATAL: nvme unavailable"; exit 9; }
fi

cd /mnt/f/kimi-k3-in-c
[ -x ./bin/k3 ] || { echo "[ab2] FATAL: ./bin/k3 missing"; exit 9; }

runvar () {
  NAME=$1; MODE=$2; shift 2
  LOG=/mnt/f/kimi-k3-in-c/reports/gateab_ab/$NAME-$(date +%Y%m%d_%H%M%S)
  mkdir -p "$LOG"
  if [ "$MODE" = nokio ]; then export K3_NOKIO=1; else unset K3_NOKIO; fi
  echo "[ab2] $NAME mode=$MODE -> $LOG"
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
  /usr/bin/time -f "TIME_ELAPSED=%e" ./bin/k3 /model \
    --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
    --ids 1008 --gen 8 --out "$LOG/ctrl.json" "$@" > "$LOG/ctrl.log" 2>&1
  RC=$?
  unset K3_NOKIO
  echo "EXIT=$RC NAME=$NAME load=$(cut -d' ' -f1-3 /proc/loadavg)"
  {
    echo "--- $NAME (mode=$MODE extra: $*)"
    grep -aE "auto budget|explicit budget|trunk .* GB|expert cache|pinned .*/93|s/token average|I/O share|experts, whole|parked on the expert gate|phase2|pread\)" "$LOG/ctrl.log" | tail -12
    grep -aE "^TIME_ELAPSED" "$LOG/ctrl.log"
    grep -aE "peak_rss_bytes|seconds_per_token" "$LOG/ctrl.json"
  } > "$LOG/summary.txt"
  cat "$LOG/summary.txt"
}

runvar v0_repeat kio
runvar v1_nokio  nokio
unset K3_NOKIO
echo "[ab2] end $(date +%T)"