#!/bin/bash
# One arm of ab55.sh, end to end, to prove the mktemp redirection fix works. Eleven arms
# ran once and all came back "0 of N streams"; the parse was never the problem.
set -u
F=/mnt/nvme/trunk_layers_out/$(ls -S /mnt/nvme/trunk_layers_out | head -1)

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

for ns in 1 4 16; do
  per=$(( 2147483648 / ns ))
  RAW=$(mktemp)
  { for i in $(seq 1 "$ns"); do
      dd if="$F" of=/dev/null bs=4M count=$((per/4194304)) iflag=direct 2>>"$RAW" &
    done; wait; }
  out=$(cat "$RAW")
  parsed=$(printf '%s\n' "$out" | sum_rates)
  got=$(printf '%s' "$parsed" | cut -f2)
  printf "  n=%-3s captured=%-3s parsed=%-3s  %s MB/s\n" \
    "$ns" "$(grep -ac copied "$RAW")" "$got" "$(printf '%s' "$parsed" | cut -f1)"
  rm -f "$RAW"
done
