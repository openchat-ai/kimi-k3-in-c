#!/bin/bash
# Disassemble the two suspect hot-path functions in both binaries.
A=/root/k3_0859
B=/mnt/f/kimi-k3-in-c/bin/k3
for fn in k3_trunk_prefetch k3_trunk_bind; do
  for tag in OLD NEW; do
    [ "$tag" = OLD ] && f=$A || f=$B
    objdump -d --no-show-raw-insn "$f" 2>/dev/null \
      | awk -v fn="$fn" '
        $0 ~ "<"fn">:$" {on=1}
        on && /^[0-9a-f]+ </ && $0 !~ "<"fn">:$" {on=0}
        on {print}
      ' > /root/${fn}_${tag}.txt
    echo "== $fn $tag: $(wc -l < /root/${fn}_${tag}.txt) lines, calls:"
    grep -oE "call.*<[a-zA-Z_0-9.]+>" /root/${fn}_${tag}.txt | sed 's/.*<//;s/>//' | sort | uniq -c | sort -rn | head -8
  done
  echo "-------------------------------------------------------------"
done