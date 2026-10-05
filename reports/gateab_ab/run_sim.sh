#!/bin/bash
# Re-run the overlap model with the current baseline. MEAS_TOKEN_S was 65.21, the best serial
# wall from the 09-30 binary; the 10-01 async-burst commits moved the engine to 76.72-87.56,
# so every predicted wall was unreachable while the gain percentage still looked right.
set -u
cd /mnt/f/kimi-k3-in-c
python3 -c 'import ast; ast.parse(open("reports/gateab_ab/overlap_sim.py").read())' \
  && echo "SYNTAX_OK" || exit 1
echo
python3 reports/gateab_ab/overlap_sim.py 2>&1