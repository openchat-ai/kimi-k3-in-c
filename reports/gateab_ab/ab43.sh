#!/bin/bash
# v42: isolate the kio hop.
#
# Same file, same O_DIRECT fd, same offsets, same read size, same thread count, same total
# bytes. Arm A calls pread from the requesting thread, which is what v40 did. Arm B goes
# through k3_io_submit_g onto a pool and blocks on k3_io_wait, which is what
# k3_l2_load_direct does. The 6.2x between v40's 2723 MB/s and the engine's 439 MB/s has to
# come from somewhere in that difference, because everything else is now excluded.
#
# Also varies the pool size, because the engine's ledger says 38 MB/s per worker thread and
# 16 x 38 is above the 439 MB/s observed, i.e. the workers are not kept busy. If more workers
# help, the pool is the limit; if not, it is the request pattern.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v43_kiohop
mkdir -p "$OUT"

cc -O2 -std=gnu99 -D_GNU_SOURCE -Iinclude -Iinclude/k3 -pthread \
   reports/gateab_ab/kiohop.c build/src/io/k3_io.o -o "$OUT/kiohop" 2>&1 | head -20
if [ ! -x "$OUT/kiohop" ]; then echo "BUILD FAILED"; exit 1; fi
echo "built ok"

sleep 240
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
{ echo "load before: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "mem avail : $(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)GB"; } > "$OUT/state.txt"

"$OUT/kiohop" 2>&1 | tee "$OUT/run.txt"
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/state.txt"
