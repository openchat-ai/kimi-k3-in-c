#!/bin/bash
# The 2026-09-26 binary (78.37 s/tok) uses 1405 ymm instructions; a build from today's
# tree uses 323, and k3_matmul_e8m7._omp_fn.0 went 288 -> 1323 instructions. Same source,
# same GCC 15.2.0, same -march=native, so the suspect is incremental-build staleness.
# Force a full rebuild and see which vector width the kernels come out as.
set -eu
cd /mnt/f/kimi-k3-in-c
echo "[b] HEAD before: $(md5sum bin/k3 | cut -c1-16)  $(stat -c%y bin/k3)"
make clean >/dev/null 2>&1 || true
echo "[b] cleaned; building from scratch"
make -j8 2>&1 | tail -3
echo "[b] NEW: $(md5sum bin/k3 | cut -c1-16)  $(stat -c%y bin/k3)"
objdump -d --no-show-raw-insn bin/k3 > /root/dis_CLEAN.txt
echo "[b] ymm=$(awk '/%ymm/{c++} END{print c+0}' /root/dis_CLEAN.txt)  xmm=$(awk '/%xmm/{c++} END{print c+0}' /root/dis_CLEAN.txt)"
for s in k3_matmul_e8m7._omp_fn.0 k3_matmul_q8._omp_fn.0 k3_matmul_bf16._omp_fn.0; do
  n=$(awk -v k="$s" '$0 ~ "<"k">:" {f=1;next} f && /^ /{c++} f && /^[0-9a-f]+ </ && $0 !~ "<"k">:"{f=0} END{print c+0}' /root/dis_CLEAN.txt)
  echo "[b] $s = $n insns"
done
echo "[b] reference: OLD(78.37) ymm=1405 xmm=5322 | e8m7=288 q8=213 bf16=353"