#!/bin/bash
# v55: establish the 2.77x without trusting any counter the engine produces.
#
# v52 concluded the drive idles about half the time, from arithmetic on its own workers:
# 16 x 243.2 s = 3891 worker-seconds available, minus 1988 s inside pread, and the other
# 1903 s was called "waiting for work". That needs two assumptions, and neither is checkable
# where it stands. The 16 workers may not have been available the whole time, and "not in
# pread" may not mean "idle". stat_idle_s, which would have answered it, samples only the
# instant a worker finds the queue empty, never its sleep.
#
# /proc/diskstats cannot settle it in this WSL guest. Its counters reset between samples --
# sectors_read went from 35831 down to 80 across two reads, so a delta is negative and
# meaningless -- and /sys/block/sdd7 is absent, because WSL does not pass the disk through
# as a block device. A guest counter that goes backwards is not a counter.
#
# dd is the measurement. Single O_DIRECT stream on a large file: 1.1-1.2 GB/s, twice in a
# row, 2.2 GB/s, checked. Four streams: 407+399+395+390 = 1591 MB/s. So one stream beats the
# engine's 891 MB/s total from sixteen, and the device has queue depth to spare. What is
# left is how far concurrency actually gets, and whether the scattered pattern the expert
# reads produce is what costs the engine, rather than the block size or the streaming.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v55_stream
mkdir -p "$OUT"
F=/mnt/nvme/trunk_layers_out/$(ls -S /mnt/nvme/trunk_layers_out | head -1)
: > "$OUT/raw.txt"

sleep 120
for _ in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1 /proc/loadavg)  $(date +%T)"

sum_rates() {
  awk '
    /copied,/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9.]+$/ && $(i+1) == "GB/s") rate += $i * 1024
        else if ($i ~ /^[0-9.]+$/ && $(i+1) == "MB/s") rate += $i
        else if ($i ~ /^[0-9.]+$/ && $(i+1) == "kB/s") rate += $i / 1024
      }
      streams++
    }
    END { if (streams > 0) printf "%.0f\t%d", rate, streams; else print "?\t0" }'
}

FAILED=0
# "4M" is not a number. The first version passed bs straight into $((per/bs)) and every arm
# died with "4M: value too great for base". The smoke test missed it because it hardcoded
# 4194304 instead of using the variable -- it exercised a different code path than the script
# ran, which is the same mistake the four instrument defects in BENCH_PROTO section 13 came
# from: testing a path the real run does not take. Strip the suffix once, up front.
to_bytes() { case "$1" in
    *K|*k) echo $(( ${1%[Kk]} * 1024 )) ;;
    *M|*m) echo $(( ${1%[Mm]} * 1048576 )) ;;
    *G|*g) echo $(( ${1%[Gg]} * 1073741824 )) ;;
    *)     echo "$1" ;;
  esac; }

bandwidth() {   # $1 label, $2 bs, $3 streams, $4 stride-in-bytes (0 = sequential)
  local label=$1 bs=$2 ns=$3 stride=$4
  local per=$(( 2147483648 / ns ))          # 2 GiB of work total
  local bsb; bsb=$(to_bytes "$bs")          # byte count, for the arithmetic below
  local out
  # Redirect dd's stderr to a file, not into a captured subshell. `dd 2>&1 &` inside
  # `$( ... 2>&1 )` sends the per-stream output somewhere the sum_rates awk never sees, so
  # every arm came back "0 of N streams" while the same parse worked standalone. Write the
  # raw lines to disk, then read them back -- then a mismatch is visible in the file too.
  local RAW; RAW=$(mktemp)
  if [ "$stride" -eq 0 ]; then
    { for i in $(seq 1 "$ns"); do
        dd if="$F" of=/dev/null bs="$bs" count=$((per/bsb)) iflag=direct 2>>"$RAW" &
      done; wait; }
  else
    # fullblock with a per-stream offset walks the file with a gap, so each stream lands on a
    # different region and the drive sees scattered rather than sequential access.
    local maxoff=$(( $(stat -c %s "$F") - per - stride ))
    { for i in $(seq 1 "$ns"); do
        local_off=$(( i * stride ))
        [ "$local_off" -gt "$maxoff" ] && local_off=$(( i * stride / 2 ))
        dd if="$F" of=/dev/null bs="$bs" count=$((per/bsb)) skip=$((local_off/bsb)) \
           iflag=direct,fullblock 2>>"$RAW" &
      done; wait; }
  fi
  out=$(cat "$RAW")
  local parsed; parsed=$(printf '%s\n' "$out" | sum_rates)
  local rate=$(printf '%s' "$parsed" | cut -f1) got=$(printf '%s' "$parsed" | cut -f2)
  if [ "$got" -ne "$ns" ]; then
    echo "  $label  PARSE MISMATCH: $got of $ns streams reported -- ABORTING"
    echo "  raw dd output was:"
    printf '%s\n' "$out" | head -5 | sed 's/^/     /'
    echo "  saved at $RAW"
    return 1
  fi
  rm -f "$RAW"
  printf "  %-24s bs=%-6s n=%-3s %8s MB/s\n" "$label" "$bs" "$ns" "$rate"
  printf '%s\t%s\t%s\t%s\n' "$label" "$bs" "$ns" "$rate" >> "$OUT/raw.txt"
  sleep 8
}

echo
echo "== single stream"
bandwidth "1 stream 1M"      1M   1 0 || FAILED=1
bandwidth "1 stream 4M"      4M   1 0 || FAILED=1
bandwidth "1 stream 16K"    16K   1 0 || FAILED=1
bandwidth "1 stream 64K"    64K   1 0 || FAILED=1

echo
echo "== concurrency, sequential"
bandwidth "4 streams 4M"    4M   4 0 || FAILED=1
bandwidth "8 streams 4M"    4M   8 0 || FAILED=1
bandwidth "16 streams 4M"   4M  16 0 || FAILED=1
bandwidth "16 streams 1M"   1M  16 0 || FAILED=1
bandwidth "32 streams 4M"   4M  32 0 || FAILED=1

echo
echo "== 16 streams, scattered 64K stride"
bandwidth "16x 16K strided" 16K 16 65536 || FAILED=1
bandwidth "16x 4M strided"   4M 16 4194304 || FAILED=1

[ $FAILED -gt 0 ] && { echo "some arms failed; not reporting an aggregate"; exit 1; }

echo
echo "engine, same drive, same file: 891 MB/s from 16 workers (v52)"
echo
echo "device under 16 sequential streams:"
awk -F'\t' '$2=="4M" && $3=="16" {print "  "$4" MB/s"}' "$OUT/raw.txt"
echo
echo "raw: $OUT/raw.txt   end $(date +%T)"
