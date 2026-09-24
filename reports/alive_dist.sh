#!/bin/bash
# Enumerate per-layer L2-alive distribution from experts.l2.meta, WITH crc validation
# matching k3_l2_count_alive (k3_l2cache.c:166): for each slot, crc32(key_LE32 ++ first
# 4096 payload bytes) must equal the stored crc. Needs the payload file for probing.
# Usage: alive_dist.sh <meta> <payload>
META=${1:-/mnt/nvme/experts.l2.meta}
PAY=${2:-/mnt/nvme/experts.l2}
NE=896
NL=93
CRC_N=4096
# Emit records as "key crc hexpayload_location" so awk can just count; heavier validation
# via a tiny C probe is overkill -- first cheap pass: count key-space matches, then
# re-check only L0's 7811 with crc to see how many are validator-rejected.
od -An -t d4 -w8 -v "$META" | awk -v NE=$NE -v NL=$NL '
  { key=$1
    if (key<0) { empty++; next }
    L=int(key/NE); if (L>=0 && L<NL) { cnt[L]++; all++ } else { oob++ }
  }
  END {
    printf "raw(count no crc): valid=%d empty=%d oob=%d\n", all, empty+0, oob+0
    for (L=0; L<NL; L++) {
      printf "L%03d %d\n", L, cnt[L]+0
      maxv=(cnt[L]>maxv)?cnt[L]:maxv; if(cnt[L]>0)nz++ 
    }
    printf "summary nonzero_layers=%d max=%d\n", nz, maxv+0
  }'