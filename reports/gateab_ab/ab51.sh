#!/bin/bash
# v51: which descriptor do the L2 hit reads actually use?
#
# k3_l2cache.c opens experts.l2 twice -- fdh O_RDONLY|O_DIRECT for whole-slot aligned
# reads, fd O_RDWR buffered for everything else -- and picks between them on whether the
# expert's real nbytes equals the padded slot size. The branch is silent. If any expert's
# nbytes differs, those reads fall back to the buffered descriptor, which on this drive has
# measured IQR 1.140 across runs (13.6x). That would mean the 476 MB/s engine figure and the
# 2463 MB/s device figure were not measured over the same kind of read at all, and it would
# be the first candidate all day that is both unexcluded and cheap to confirm.
#
# One engine run, 3 tokens, same 32/15 config. The report now prints the fd split, and the
# first four reads print want / slot_bytes / nbytes / which descriptor.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v51_fdsplit
mkdir -p "$OUT"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
LOG="$OUT/run-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG"
{ echo "start : $(date +%T)"; echo "load  : $(cut -d' ' -f1-3 /proc/loadavg)"; } > "$LOG/state.txt"

unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0
./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 3 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
echo "EXIT=$?  end $(date +%T)" >> "$LOG/state.txt"

echo "=== the first few reads: want vs slot_bytes vs nbytes, and which fd"
grep -a "L2 want=" "$LOG/ctrl.log" | head -6 | sed 's/^/   /'
echo
echo "=== fd split in the ledger"
grep -aE "fd split|hit I/O|s/token average|expert phase split" "$LOG/ctrl.log" | sed 's/^/   /'
cat "$LOG/state.txt"
