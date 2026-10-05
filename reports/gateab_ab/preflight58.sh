#!/bin/bash
# Before spending 28 minutes: confirm the disk is attached, the geometry is intact, and the
# probe's own constants match the file. The first v58 run failed both arms on an empty
# /mnt/nvme and burned the whole window finding that out at the far end.
set -u
echo "== mount"
mountpoint -q /mnt/nvme && echo "  /mnt/nvme is mounted" || { echo "  NOT MOUNTED -- refusing"; exit 1; }
df -h /mnt/nvme | tail -1

echo
echo "== files the run needs"
for f in /mnt/nvme/experts.l2 /mnt/nvme/trunk_layers_out /mnt/nvme/embed; do
  if [ -r "$f" ]; then echo "  ok      $f"; else echo "  MISSING $f"; fi
done

echo
echo "== geometry, from the file and from the engine's own printed values"
SLOT=17547264; NSLOT_ENGINE=14589
FS=$(stat -c %s /mnt/nvme/experts.l2)
NS=$((FS / SLOT))
echo "  file          $(numfmt --to=iec "$FS")"
echo "  nslot (file)  $NS"
echo "  nslot (engine printed) $NSLOT_ENGINE"
[ "$NS" -eq "$NSLOT_ENGINE" ] && echo "  MATCH" || { echo "  MISMATCH -- refusing"; exit 1; }
[ $((FS % SLOT)) -eq 0 ] && echo "  no partial trailing slot" || { echo "  PARTIAL TRAILING SLOT"; exit 1; }

echo
echo "== the probe's hardcoded geometry"
grep -nE '17547264|14589|experts\.l2|trunk_layers_out' /mnt/f/kimi-k3-in-c/reports/gateab_ab/steady58.c \
  | grep -vE '^\s*[0-9]+:\s*\*' | head -8 | sed 's/^/  /'

echo
echo "== the engine binary is from the 10-01 commits"
grep -c 'DBG spread' /mnt/f/kimi-k3-in-c/reports/gateab_ab/steady58.c >/dev/null 2>&1
printf "  bin/k3 %s\n" "$(stat -c %y /mnt/f/kimi-k3-in-c/bin/k3 | cut -c1-19)"
printf "  ymm    %s (expect ~1433, 323 would mean degraded AVX2)\n" \
  "$(objdump -d /mnt/f/kimi-k3-in-c/bin/k3 | grep -c ymm)"

echo
echo "== model weights and embed table"
echo "  /model shards : $(ls /model/*.safetensors 2>/dev/null | wc -l)  (expect 96)"
echo "  embed table   : $(stat -c %s /mnt/nvme/embed/*.safetensors 2>/dev/null | numfmt --to=iec)"
echo "                  (one file, ~4.7 GB = the 'embed + lm_head 4.70 GB' of the memory plan."
echo "                   Its name says model-00094-of-000096 but that is a misleading name for"
echo "                   the embedding table; the 96 weight shards live in /model.)"
echo "  trunk files   : $(ls /mnt/nvme/trunk_layers_out/*.bin 2>/dev/null | wc -l)  (expect 93)"
echo "  free          : $(df -BG /mnt/nvme | tail -1 | awk '{print $4}')"