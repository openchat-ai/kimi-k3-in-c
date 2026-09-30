#!/bin/bash
# Confirm the real slot count before touching any probe. v42 read past the end of the file
# because it hardcoded NSLOT=17096, which is what a 300 GB file would hold; experts.l2 is
# 256 GB. The engine prints the true figure at startup, so read it from there rather than
# computing it.
set -u
echo "--- file size and the slot count it implies:"
ls -l /mnt/nvme/experts.l2 | awk '{printf "   %d bytes\n", $5}'
python3 -c "
import os
sz=os.path.getsize('/mnt/nvme/experts.l2')
slot=17547264
print('   %d / %d = %d slots' % (sz, slot, sz//slot))
print('   offset of slot 17095 = %d bytes  -> %s' % (17095*slot, 'PAST EOF' if 17095*slot>=sz else 'ok'))
"
echo "--- what the engine itself reports:"
grep -a 'expert L2 exact' /mnt/f/kimi-k3-in-c/reports/gateab_ab/v41_phase1/rep1-*/ctrl.log | sed 's/^/   /'
