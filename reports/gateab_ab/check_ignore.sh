#!/bin/bash
# Verify the ignore patterns against paths that are not in the index. A pattern that looks
# right in the .gitignore can still fail to match, and "the file is not being committed" is
# indistinguishable from "the file happens not to exist" -- so check the pattern, not the
# absence.
set -u
cd /mnt/f/kimi-k3-in-c
echo "== 模式对未跟踪路径是否生效（--no-index）"
for f in \
  reports/gateab_ab/v58_mix/steady58 \
  reports/gateab_ab/v99_x/steady58 \
  reports/gateab_ab/steady58 \
  reports/gateab_ab/v60_shape/spool/0.0 \
  reports/gateab_ab/v61_burst/k3_burst \
  reports/gateab_ab/v61_burst/k3_noburst \
  reports/gateab_ab/v58_mix/ratios.txt \
  reports/gateab_ab/FINDINGS.md ; do
  printf "  %-42s " "$f"
  if git check-ignore -q --no-index "$f"; then echo "IGNORED"; else echo "*** NOT ignored ***"; fi
done

echo
echo "== 关键：汇总文件必须仍可入库"
for f in reports/gateab_ab/v58_mix/ratios.txt reports/gateab_ab/FINDINGS.md \
         reports/gateab_ab/v62_policy/raw.tsv reports/gateab_ab/v60_shape/raw.tsv; do
  printf "  %-42s " "$f"
  if git check-ignore -q --no-index "$f"; then echo "*** 被误忽略 ***"; else echo "可入库 (ok)"; fi
done

echo
echo "== 已从索引移除的三个二进制"
git status --short 2>&1 | grep -E '^(D| M)' | head -5 | sed 's/^/  /'
echo
echo "== 索引中是否还有二进制"
git ls-files reports/gateab_ab | while read -r f; do
  case "$f" in
    *.o|*.a|*.so) echo "  $f" ;;
  esac
done
echo "  （上面若无输出即已清空）"