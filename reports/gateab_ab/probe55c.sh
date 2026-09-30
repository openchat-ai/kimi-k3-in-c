#!/bin/bash
# /proc/diskstats has 20 fields per line, not 14, and the guest WSL is reporting is not
# reflecting the engine's reads. Settle whether sdd7 counters move at all when the engine
# runs, using a read that genuinely comes from the drive this time: an actual file.
#
# Field map confirmed by probe55b (20 fields, matching the documented layout):
#   [6]  sectors read      [7]  ms spent reading
#   [10] sectors written   [11] ms spent writing
#   [14] ms spent discarding (field 12 in older kernels; 14 here is discard)
# Field 12-14 on the sdd7 row are 0/72/294, so writes are tracked but reads are tiny.
set -u
DEV=sdd7
row() { awk -v d="$DEV" '$3==d {print; exit}' /proc/diskstats; }
snap() { r=$(row); set -- $r; echo "$6 $7 $10 $11"; }

echo "== 1. read a real file from the drive, 256 MB"
F=/mnt/nvme/trunk_layers_out
if [ ! -r "$F" ]; then echo "  trunk dir unreadable, pick another"; F=/mnt/nvme; fi
BEFORE=$(snap)
SZ=$(du -sb "$F" 2>/dev/null | cut -f1)
echo "  target: $F  ($SZ bytes)"
# hash a bounded prefix so this cannot run for an hour
head -c 268435456 "$F"/* 2>/dev/null | sha256sum > /dev/null
AFTER=$(snap)
set -- $BEFORE; a6=$1; a7=$2
set -- $AFTER;  b6=$3; b7=$4
echo "  before: sectors=$a6 ms_read=$a7"
echo "  after : sectors=$b6 ms_read=$b7"
echo "  delta : sectors=$((b6-a6)) = $(( (b6-a6)*512/1048576 )) MB   ms_read=$((b7-a7))"

echo
echo "== 2. same, but with dd and O_DIRECT, which is what the engine does"
SZ2=$(stat -c %s "$F"/* 2>/dev/null | sort -rn | head -1)
echo "  largest file: $SZ2 bytes"
B2=$(snap)
dd if="$F/$(ls -S "$F" | head -1)" of=/dev/null bs=4M count=64 iflag=direct 2>&1 | tail -2 | sed 's/^/  /'
A2=$(snap)
set -- $B2; c6=$1; c7=$2
set -- $A2; d6=$3; d7=$4
echo "  delta : sectors=$((d6-c6)) = $(( (d6-c6)*512/1048576 )) MB   ms_read=$((d7-c7))"
echo "  implied rate: $(awk -v a=$((d6-c6)) -v m=$((d7-c7)) 'BEGIN{if(m>0) printf "%.0f MB/s", a*512/1048576/(m/1000); else print "ms_read=0, cannot compute"}')"

echo
echo "== 3. is this the right device? check every block device moving"
awk 'NR>2 {printf "  %-8s rd_sectors=%-12s rd_ms=%-8s wr_ms=%s\n", $3, $6, $7, $11}' /proc/diskstats \
  | grep -vE 'ram[0-9]+|loop[0-9]+'

echo
echo "== 4. WSL block device passthrough?"
echo -n "  /sys/block/sdd7/stat: "; cat /sys/block/sdd7/stat 2>/dev/null || echo "absent"
echo -n "  /sys/block/sdd7/queue/rotational: "; cat /sys/block/sdd7/queue/rotational 2>/dev/null || echo "absent"
