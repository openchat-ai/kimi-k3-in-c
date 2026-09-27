#!/bin/bash
# -march=native resolves at COMPILE time. If the host exposed different CPU features
# on 2026-09-26 than it does now, the two binaries use different vector widths --
# which would explain a 1035-instruction gap in the matmul kernels.
for tag in OLD NEW; do
  [ "$tag" = OLD ] && f=/root/k3_0859 || f=/mnt/f/kimi-k3-in-c/bin/k3
  objdump -d --no-show-raw-insn "$f" 2>/dev/null > /root/dis_$tag.txt
  z=$(grep -cE '%zmm' /root/dis_$tag.txt)
  y=$(grep -cE '%ymm' /root/dis_raw_$tag.txt 2>/dev/null || true)
  y=$(awk '/%ymm/{c++} END{print c+0}' /root/dis_$tag.txt)
  x=$(awk '/%xmm/{c++} END{print c+0}' /root/dis_$tag.txt)
  b=$(grep -cE '\bvp?(ternlog|cbroadcast|fmadd|cvt)\b.*%zmm' /root/dis_$tag.txt)
  echo "$tag: zmm=$z  ymm=$y  xmm=$x  avx512-only=$b"
done
echo
echo "== kernel instruction counts (old vs new), the matmul paths:"
printf "%-40s %8s %8s\n" SYMBOL OLD NEW
for s in k3_matmul_e8m7._omp_fn.0 k3_matmul_q8._omp_fn.0 k3_matmul_bf16._omp_fn.0 k3_matmul._omp_fn.0; do
  o=$(awk -v k="$s" '$0 ~ "<"k">:" {f=1;next} f && /^ /{c++} f && /^[0-9a-f]+ </ && $0 !~ "<"k">:"{f=0} END{print c+0}' /root/dis_OLD.txt)
  n=$(awk -v k="$s" '$0 ~ "<"k">:" {f=1;next} f && /^ /{c++} f && /^[0-9a-f]+ </ && $0 !~ "<"k">:"{f=0} END{print c+0}' /root/dis_NEW.txt)
  printf "%-40s %8s %8s\n" "$s" "$o" "$n"
done
echo
echo "== quick sanity: are the two builds' matmul bodies identical in shape?"
for tag in OLD NEW; do
  echo -n "$tag e8m7 first 12 insns: "
  awk '/<k3_matmul_e8m7\._omp_fn\.0>:/{f=1;n=0;next} f&&/^ /{if(n<12){gsub(/^[^\t]*\t[^\t]*\t/,"");printf "%s | ",$0;n++}}' /root/dis_$tag.txt
  echo
done