#!/bin/bash
# 15-second smoke of ab55.sh: does the rate parsing work, and is 1.2 GB/s reproducible?
set -u
F=/mnt/nvme/trunk_layers_out/$(ls -S /mnt/nvme/trunk_layers_out | head -1)
echo "file: $F"
echo
echo "== 1 stream, 4M, 256 MB"
dd if="$F" of=/dev/null bs=4M count=64 iflag=direct 2>&1 | tail -1 | sed 's/^/  /'
echo "== 4 streams, 4M, 64 MB each"
{ for i in 1 2 3 4; do
    dd if="$F" of=/dev/null bs=4M count=16 iflag=direct 2>&1 &
  done; wait; } 2>&1 | grep copied | sed 's/^/  /'
echo
echo "== does the awk rate-sum handle that output?"
{ for i in 1 2 3 4; do
    dd if="$F" of=/dev/null bs=4M count=8 iflag=direct 2>&1 &
  done; wait; } 2>&1 | awk '/copied,/ {
    for(i=1;i<=NF;i++) if($i=="(MB/s)") rate+=$(i-1)
  } END{printf "  summed rate: %.0f MB/s across %d streams\n", rate, NR}' | sed 's/^/  /'
