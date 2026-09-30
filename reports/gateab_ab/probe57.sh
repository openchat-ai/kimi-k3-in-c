#!/bin/bash
# The v57b smoke reported 11 of 12 invocations and the script deleted the raw dd output, so
# the evidence is gone. Redo 12 reads keeping everything, one read per file, so nothing can
# interleave and nothing gets deleted.
set -u
L2=/mnt/nvme/experts.l2
SLOT=17547264
NSLOT=$(( $(stat -c %s "$L2") / SLOT ))
D=/tmp/slotdiag
rm -rf "$D"; mkdir -p "$D"

echo "== 12 reads, one output file each, run concurrently"
for i in $(seq 0 11); do
  slot=$(( (i * 4096) % NSLOT ))
  ( dd if="$L2" of=/dev/null bs=$SLOT count=1 skip=$slot iflag=direct,fullblock \
        > "$D/out.$i" 2>&1 ) &
done
wait

for i in $(seq 0 11); do
  slot=$(( (i * 4096) % NSLOT ))
  printf "  slot=%-6s out=%-40s\n" "$slot" "$(tr '\n' '|' < "$D/out.$i")"
done

echo
echo "== how many reported a 'copied' line"
grep -lc copied "$D"/out.* 2>/dev/null | wc -l
echo "== how many reported any line at all"
grep -l . "$D"/out.* 2>/dev/null | wc -l
echo
echo "== any line without 'copied', verbatim"
for f in "$D"/out.*; do
  if ! grep -q copied "$f"; then echo "  $(basename "$f"):"; sed 's/^/     /' "$f"; fi
done
echo "== any error keyword anywhere"
grep -inE 'error|denied|No such|Input/output' "$D"/out.* 2>/dev/null | sed 's/^/  /' || echo "  none"
