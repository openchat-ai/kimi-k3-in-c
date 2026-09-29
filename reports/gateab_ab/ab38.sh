#!/bin/bash
# v38 driver: the Windows-side sampler in hostcount38.ps1 runs this. Kept separate so the
# launch line and the engine invocation are auditable without reading PowerShell.
set -u
cd /mnt/f/kimi-k3-in-c
unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0
echo "--- before $(date +%T)  load=$(cut -d' ' -f1-3 /proc/loadavg)  MemAvail=$(awk '/MemAvailable/{printf "%.1fGB",$2/1048576}' /proc/meminfo)"
# No drop_caches: the host sampler watches the physical drive, and evicting the guest's
# page cache would make the host-side reading describe a state the engine never sees.
./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 8 --out /tmp/v38.json
echo "EXIT=$?  after $(date +%T)  load=$(cut -d' ' -f1-3 /proc/loadavg)"
