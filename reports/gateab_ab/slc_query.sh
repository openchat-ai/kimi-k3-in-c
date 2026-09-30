#!/bin/bash
# How big is this drive's SLC cache, and is there any knob to keep it there?
#
# v46's shape is the signature of an SLC cache cliff: on one fixed base the rate fell from
# 7192 to 4705 MB/s within a minute and never recovered, and across bases the same drive
# gave 4667 at one offset and 1728 at another, a 2.7x spread. SLC-to-TLC is the usual ratio.
# If the cache is larger than v39's 40 GB of preconditioning writes, then every measurement
# today ran in a mixed state and the "6.2x" and the "3.4x" are both partly this.
#
# nvme-cli may not be installed. smartctl and the sysfs/lsblk views are checked first
# because they need nothing, then nvme-cli if present. Read-only throughout.
set -u

echo "=== 1. tools available"
for t in nvme smartctl lsblk; do
  printf "   %-10s %s\n" "$t" "$(command -v $t || echo 'not installed')"
done

echo
echo "=== 2. sysfs view of the drive (needs no tooling)"
if [ -d /sys/block/nvme0n1 ]; then
  D=/sys/block/nvme0n1
elif [ -d /sys/block/sdd ]; then
  D=/sys/block/sdd
  echo "   (exposed as sdd, not nvme0n1 -- WSL's view of the attached partition)"
fi
if [ -n "${D:-}" ]; then
  echo "   device        : $D"
  for f in queue/rotational queue/scheduler queue/nr_requests queue/optimal_io_size; do
    [ -r "$D/$f" ] && printf "   %-13s : %s\n" "$(basename $f)" "$(cat "$D/$f")"
  done
  # rotational=0 plus a scheduler of mq-deadline/kyber is the host's view; the device
  # itself is what matters and only nvme-cli can report that.
fi

echo
echo "=== 3. nvme-cli, if present"
if command -v nvme >/dev/null 2>&1; then
  echo "--- identify-controller (SLC cache size lives in the identify output as"
  echo "---   sqs/caps, and nsid 0x02 reports the write-cache attributes)"
  nvme id-ctrl /dev/nvme0 2>&1 | grep -iE "model|serial|firmware|mn|ver" | sed 's/^/   /'
  echo "--- id-namespace"
  nvme id-ns /dev/nvme0n1 2>&1 | grep -iE "ncap|nuse|nsze|lbaf" | sed 's/^/   /'
  echo "--- smart-log: the throughput and temperature trend is what shows a cliff"
  nvme smart-log /dev/nvme0 2>&1 | sed 's/^/   /'
  echo "--- get-log, SLC/DRAM info if the drive exposes it"
  nvme get-log /dev/nvme0 -e 1 2>&1 | head -30 | sed 's/^/   /'
  nvme get-log /dev/nvme0 -e 2 2>&1 | head -30 | sed 's/^/   /'
else
  echo "   nvme-cli absent"
fi

echo
echo "=== 4. smartctl as a fallback"
if command -v smartctl >/dev/null 2>&1; then
  for d in /dev/nvme0n1 /dev/sdd; do
    [ -b "$d" ] || continue
    echo "--- smartctl -a $d"
    smartctl -a "$d" 2>&1 | grep -iE "model|firmware|SLC|cache|temperature|percent|power|unsafe|shutdown" | sed 's/^/   /'
  done
fi

echo
echo "=== 5. the block device the guest actually uses, for the record"
grep -E "experts.l2" /etc/fstab 2>/dev/null | sed 's/^/   /' || true
findmnt -no SOURCE,FSTYPE,SIZE,OPTIONS /mnt/nvme 2>/dev/null | sed 's/^/   /'

echo
echo "=== 6. what this can and cannot tell us"
echo "   The SLC cache SIZE determines whether v39's 40 GB of preconditioning fills it."
echo "   If it does not, the '1377 MB/s with a full cache' figure is not full at all, and"
echo "   every rate quoted today sits somewhere on the cliff rather than on a rung."
echo "   The fix, if the cache is large, is to precondition past it, not past 40 GB."
