#!/bin/bash
# The three figures whose locations the earlier output truncated. Everything else in table A.1
# already has a located replacement from remap_paper.sh.
set -u
cd /mnt/f/kimi-k3-in-c
L=papers/byteflow-matrix.md
for p in '25\.83' '303\.58' '11,?697' '14,?589' '20\.99'; do
  echo "--- pattern: $p"
  grep -nE "$p" "$L" | head -5 | cut -c1-150 | sed 's/^/   /'
  echo
done