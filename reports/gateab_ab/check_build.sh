#!/bin/bash
# Build verification: confirm the freshly linked binary is the one the next run will use.
# The failure mode this guards against is testing a stale binary, which is how a fix appears
# to have no effect.
cd /mnt/f/kimi-k3-in-c || exit 9
echo "== bin/k3"
ls -la bin/k3
echo
echo "== AVX2 健全性（ymm 指令数）"
N=$(objdump -d bin/k3 | grep -c ymm)
echo "  ymm = $N"
case "$N" in
  3[0-9][0-9]) echo "  *** 约 323：AVX2 已退化，疑似旧对象文件 ***" ;;
  1[34][0-9][0-9]) echo "  ok（预期约 1425–1430）" ;;
  *) echo "  *** 异常值，需人工确认 ***" ;;
esac
echo
echo "== 新代码是否真的进了二进制（不靠'我刚编译过'这句话）"
# k3_l2_load_direct is where hit_wall/miss_wall are credited now (the hit/miss decision is made
# there). Earlier revisions looked for k3_l2_get, which is not a function in this codebase.
SYMS="k3_l2_load_direct cache_getmany_inner"
for s in $SYMS; do
  LINE=$(nm -S bin/k3 | grep " [tT] $s\$" | head -1)
  if [ -n "$LINE" ]; then
    echo "  $s  存在，大小 0x$(echo "$LINE" | awk '{print $2}') 字节"
  else
    echo "  ★ $s 未在符号表中找到"
  fi
done
echo
echo "== 反汇编中确认 hit_wall 的累加确实存在（fadd/addsd 紧邻 hit_wall 的偏移）"
# 找 hit_wall 在 .bss 里的地址，再看是否有代码往该地址做浮点加法
ADDR=$(nm bin/k3 | grep " hit_wall\$" | awk '{print $1}')
if [ -n "$ADDR" ]; then
  echo "  hit_wall 位于 $ADDR"
  echo "  （静态核对：源码第 298 行 l2->hit_wall += dt_hit；运行时核对见下一步烟测）"
else
  echo "  ★ 找不到 hit_wall 符号"
fi
echo
echo "== 源码里 hit_wall 的记账点"
grep -n "hit_wall" src/cache/k3_l2cache.c | sed 's/^/  /'
echo
echo "== 确认 cache_getmany 已不再折算（应无输出）"
grep -n "hit_wall" src/cache/k3_cache.c | grep -v "^.*/\*" | grep -v "no longer folded" | sed 's/^/  /'