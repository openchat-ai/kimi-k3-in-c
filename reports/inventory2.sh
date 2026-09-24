#!/bin/bash
# deep search for mxfp8 in WSL root fs and on H:\k3 (via /mnt/h if mounted)
set -u
echo "=== WSL root fs (excluding /mnt Windows mounts) ==="
find / -maxdepth 7 -xdev \( -iname '*mxfp8*' -o -iname '*q81*' -o -iname '*fp8*' \) 2>/dev/null | head -60
echo
echo "=== /mnt (Windows drives mounted in WSL) ==="
ls -la /mnt/ 2>/dev/null
echo
echo "=== search Windows H:\\k3 via /mnt/h if present ==="
if [ -d /mnt/h ]; then
  find /mnt/h -maxdepth 6 -iname '*mxfp8*' 2>/dev/null | head -60
else
  echo "/mnt/h not mounted"
fi
echo
echo "=== also check H: root dirs for k3-like content ==="
ls -la /mnt/h 2>/dev/null | head -30
echo done