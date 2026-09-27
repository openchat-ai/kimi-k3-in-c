#!/bin/bash
for m in psda psdb sinker sdd7test nvme; do
  echo "== /mnt/$m"
  ls "/mnt/$m" 2>/dev/null | head -6
done
echo "== where is the trunk?"
ls -d /mnt/*/trunk_layers_out /mnt/*/*/trunk_layers_out 2>/dev/null | head
echo "== df:"
df -h 2>/dev/null | grep -vE 'tmpfs|9p|Wsl' | head -8