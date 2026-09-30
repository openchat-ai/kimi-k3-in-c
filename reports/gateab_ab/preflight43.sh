#!/bin/bash
# Compile-check both probes before scheduling a 25-minute run. The v42 failure was a stale
# NSLOT, which no compile step could have caught, but a syntax error costs the whole run and
# a compile check costs two seconds.
set -u
cd /mnt/f/kimi-k3-in-c
echo "--- python syntax:"
python3 -c "import ast; ast.parse(open('reports/gateab_ab/probe40.py').read()); print('    probe40.py OK')" || exit 1
echo "--- geometry constants vs the file:"
python3 -c "
import os
slot=17547264
real=os.path.getsize('/mnt/nvme/experts.l2')//slot
print('    file holds %d slots' % real)
src=open('reports/gateab_ab/probe40.py').read()
ns=[l for l in src.splitlines() if l.startswith('NSLOT')][0].split('=')[1].strip()
print('    probe40 NSLOT = %s  -> %s' % (ns, 'OK' if int(ns)==real else 'MISMATCH'))
if int(ns)!=real: raise SystemExit(1)
"
echo "--- C syntax:"
mkdir -p reports/gateab_ab/v42_kiohop
cc -O2 -std=gnu99 -D_GNU_SOURCE -Iinclude -Iinclude/k3 -pthread \
   reports/gateab_ab/kiohop.c build/src/io/k3_io.o \
   -o reports/gateab_ab/v42_kiohop/kiohop 2>&1 | head -10
[ -x reports/gateab_ab/v42_kiohop/kiohop ] || { echo "    kiohop.c FAILED to link"; exit 1; }
echo "    kiohop OK"
echo "--- read the engine's own geometry line for cross-check:"
grep -ah 'expert L2 exact' reports/gateab_ab/v41_phase1/rep1-*/ctrl.log | head -1 | sed 's/^/    /'
