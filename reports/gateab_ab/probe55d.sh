#!/bin/bash
# Every arm reported 0 of N streams, but the smoke test parsed four streams fine at 64 MB.
# The difference is work size: count=512 reaches 2 GiB, and dd switches its rate unit as the
# number grows. Capture what dd actually prints instead of assuming the unit.
set -u
F=/mnt/nvme/trunk_layers_out/$(ls -S /mnt/nvme/trunk_layers_out | head -1)

for spec in "1 4M 64" "1 4M 512" "1 4M 2048" "4 4M 128"; do
  set -- $spec
  ns=$1; bs=$2; cnt=$3
  echo "== ${ns} stream(s) bs=$bs count=$cnt  ($((ns*cnt)) MiB)"
  out=$( { for i in $(seq 1 "$ns"); do
             dd if="$F" of=/dev/null bs="$bs" count="$cnt" iflag=direct 2>&1 &
           done; wait; } 2>&1 )
  printf '%s\n' "$out" | grep -a copied | sed 's/^/   RAW: /'
  echo "   my awk says:"
  printf '%s\n' "$out" | awk '
    /copied,/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9.]+$/ && $(i+1) == "GB/s") rate += $i * 1024
        else if ($i ~ /^[0-9.]+$/ && $(i+1) == "MB/s") rate += $i
        else if ($i ~ /^[0-9.]+$/ && $(i+1) == "kB/s") rate += $i / 1024
      }
      streams++
    }
    END { printf "     %d streams, %.0f MB/s\n", streams, rate }'
  echo
done
