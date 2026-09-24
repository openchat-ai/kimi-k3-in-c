#!/bin/bash
set -u
cd /mnt/h/k3 || { echo "no /mnt/h/k3"; exit 1; }
echo "=== ks dir listing ==="
ls -la | head -20
echo
echo "=== e2e_mxfp8.log tail ==="
tail -40 e2e_mxfp8.log 2>/dev/null
echo
echo "=== e2e_mxfp8_fix.log tail ==="
tail -40 e2e_mxfp8_fix.log 2>/dev/null
echo
echo "=== e2e_run_mxfp8.json ==="
head -c 2000 e2e_run_mxfp8.json 2>/dev/null
echo
echo done