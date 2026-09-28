#!/bin/bash
# What is the actual on-disk layout of experts.l2? The whole "make expert reads
# sequential" idea hinges on one fact: are a layer's 16 routed experts contiguous in
# the file, or scattered across all 96 shards? Read the index only -- no data reads.
set -u
L2=/mnt/nvme/experts.l2
echo "== files:"; ls -la "$L2" 2>/dev/null | head
echo
echo "== index/meta head:"
for f in "$L2.meta" "$L2.index" "$L2.json"; do
  [ -f "$f" ] || continue
  echo "--- $f  ($(stat -c%s "$f") bytes)"
  head -c 600 "$f"; echo; echo
done
echo "== what does the code expect?"
grep -n "l2_path\|L2_PATH\|experts.l2" /mnt/f/kimi-k3-in-c/src/cli/k3_run.c | head -8