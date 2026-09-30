#!/bin/bash
# Run the real bandwidth() from ab55.sh, with the real variable-path block sizes, for the
# two shapes that decide the question: 1 stream and 16 streams, plus the scattered case.
# The previous smoke test passed because it hardcoded 4194304; this one calls the same
# function the script does.
set -u
F=/mnt/nvme/trunk_layers_out/$(ls -S /mnt/nvme/trunk_layers_out | head -1)

to_bytes() { case "$1" in
    *K|*k) echo $(( ${1%[Kk]} * 1024 )) ;;
    *M|*m) echo $(( ${1%[Mm]} * 1048576 )) ;;
    *G|*g) echo $(( ${1%[Gg]} * 1073741824 )) ;;
    *)     echo "$1" ;;
  esac; }
echo "== to_bytes: 1M=$(to_bytes 1M)  4M=$(to_bytes 4M)  16K=$(to_bytes 16K)  64K=$(to_bytes 64K)"

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

arm() {
  local label=$1 bs=$2 ns=$3 stride=$4
  local bsb; bsb=$(to_bytes "$bs")
  local per=$(( 2147483648 / ns ))
  local RAW; RAW=$(mktemp)
  if [ "$stride" -eq 0 ]; then
    { for i in $(seq 1 "$ns"); do
        dd if="$F" of=/dev/null bs="$bs" count=$((per/bsb)) iflag=direct 2>>"$RAW" &
      done; wait; }
  else
    local maxoff=$(( $(stat -c %s "$F") - per - stride ))
    { for i in $(seq 1 "$ns"); do
        o=$(( i * stride )); [ "$o" -gt "$maxoff" ] && o=$(( i * stride / 2 ))
        dd if="$F" of=/dev/null bs="$bs" count=$((per/bsb)) skip=$((o/bsb)) \
           iflag=direct,fullblock 2>>"$RAW" &
      done; wait; }
  fi
  local parsed; parsed=$(sum_rates < "$RAW")
  local got=$(printf '%s' "$parsed" | cut -f2)
  if [ "$got" -ne "$ns" ]; then
    printf "  %-22s FAILED %s of %s\n" "$label" "$got" "$ns"
    head -3 "$RAW" | sed 's/^/      /'
  else
    printf "  %-22s %6s MB/s  (%s streams)\n" "$label" "$(printf '%s' "$parsed" | cut -f1)" "$ns"
  fi
  rm -f "$RAW"
}

arm "1 stream 4M"       4M  1 0
arm "1 stream 16K"     16K  1 0
arm "16 streams 4M"     4M 16 0
arm "32 streams 4M"     4M 32 0
arm "16x 16K strided"  16K 16 65536
arm "16x 4M strided"    4M 16 4194304
