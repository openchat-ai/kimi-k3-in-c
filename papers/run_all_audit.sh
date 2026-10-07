#!/bin/bash
# Run every checker that exists against the current draft.
#
# These are independent audits written at different times for different purposes, so the point
# of running them together is that no single one of them saw the whole draft. Two defects found
# in the previous round were exactly that: a date in a table caption that check_log_tone.py
# cannot see, and an English title kept in two copies where only one was being generated.
cd /mnt/f/kimi-k3-in-c || exit 1
PY=/root/docxenv/bin/python

for s in verify_docx check_table_width check_log_tone check_refs check_cell_len check_mpl style_audit; do
  if [ ! -f "papers/$s.py" ]; then
    printf '\n===== %s : 不存在\n' "$s"
    continue
  fi
  printf '\n===== %s\n' "$s"
  "$PY" "papers/$s.py" 2>&1 | tail -10
done

printf '\n===== 产物新鲜度（源码 mtime vs DOCX mtime）\n'
ls -l --time-style=+%s papers/提交稿-缓存高命中与词元低输出.docx 2>/dev/null | awk '{print "  docx  "$6}'
stat -c '  源文  %Y  %n' papers/论文-慢层只读一次原则.md 2>/dev/null
printf '\n===== 未提交改动\n'
git status --porcelain papers | head -20