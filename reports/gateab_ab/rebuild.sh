#!/bin/bash
# Clean rebuild plus the checks that must pass before any measurement is trusted.
set -u
cd /mnt/f/kimi-k3-in-c || exit 9

echo "== make clean && make -j8"
make clean >/dev/null 2>&1
if ! make -j8 > /tmp/build.log 2>&1; then
  echo "★ 编译失败，保留 /tmp/build.log 尾部"
  tail -30 /tmp/build.log
  exit 1
fi
grep -icE '\berror\b' /tmp/build.log | sed 's/^/  error 行数: /'
grep -cE 'warning' /tmp/build.log | sed 's/^/  warning 行数: /'
echo "  bin/k3:"
ls -la bin/k3 | sed 's/^/    /'

echo
echo "== AVX2 健全性"
N=$(objdump -d bin/k3 | grep -c ymm)
echo "  ymm = $N"
case "$N" in
  1[34][0-9][0-9]) echo "  ok（预期约 1425–1430）" ;;
  *) echo "  *** 异常，需人工确认（323 = AVX2 退化）" ;;
esac

echo
echo "== 新标签确实进了二进制"
if strings bin/k3 | grep -q "no misses this run"; then
  echo "  ok  'no misses this run' 存在"
else
  echo "  ★ 未找到新标签字符串 —— 改动可能未链接进去"
  exit 2
fi
if strings bin/k3 | grep -q "misses, .* GB from /model in"; then
  echo "  ok  原有 miss I/O 格式串仍在（有 miss 时走另一分支）"
else
  echo "  ★ 原格式串消失，两条分支可能互斥了"
fi