#!/usr/bin/bash
# Table A.1 maps 19 headline figures to ledger line numbers. The figures are all present in
# papers/byteflow-matrix.md, but the line numbers point at unrelated text: the ledger is a
# living document (57 KB, last edited 09-23) and later edits shifted the lines the mapping was
# written against. The values are right, the traceability is broken.
#
# This finds where each figure actually lives, so the mapping can be repaired rather than
# left as a promise a reviewer cannot follow.
set -u
cd /mnt/f/kimi-k3-in-c
L=papers/byteflow-matrix.md
N=$(wc -l < "$L")
echo "ledger $L  $N lines"
echo

find_lines() {   # $1 regex, $2 what it is
  local hits
  hits=$(grep -nE "$1" "$L" | head -6)
  if [ -z "$hits" ]; then
    printf "  %-30s NOT FOUND\n" "$2"
    return 1
  fi
  printf "  %-30s %s\n" "$2" "$(printf '%s' "$hits" | cut -d: -f1 | paste -sd, -)"
  printf '%s\n' "$hits" | sed 's/^/        /' | cut -c1-155
}

echo "== 表 A.1 声称行号 → 实际所在行"
find_lines '25\.83'        '25.83 GB/词元'
echo
find_lines '303\.58|303\.5' '专家段 303.58 s/词元'
echo
find_lines '324\.36'       '端到端 324.36 s/词元'
echo
find_lines '10,?010'       'distinct 集 10,010 个'
echo
find_lines '\b176\s*GB|176GB' '176 GB'
echo
find_lines '588'           '高速盘冷读 588 MB/s'
echo
find_lines '191\.6'        '专家段 191.6 s/词元'
echo
find_lines '262\.78'       'seconds_per_token 262.78'
echo
find_lines '19\.1[0-9]?\s*GB|19\.13' '高速盘命中 19.1 GB/词元'
echo
find_lines '6\.7'          '低速盘 miss 6.7 GB'
echo
find_lines '11,?697'       'KV 11,697 distinct 键'
echo
find_lines '20\.99'        'heat 策略专家段 20.99 GB'
echo
find_lines '\b94%|94\.0%|94\.7%' '端到端占比 94%'