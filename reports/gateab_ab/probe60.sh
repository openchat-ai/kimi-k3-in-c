#!/bin/bash
# v60 produced "0 MB/s" alongside "13179 reads", and each arm took 166 s when 45 s was asked
# for, with loadavg above 21. Find out which of those two is a parse failure and which is a
# fork-storm, before touching the script again.
set -u
S=/mnt/f/kimi-k3-in-c/reports/gateab_ab/v60_shape/spool
echo "== spool files: $(ls "$S" 2>/dev/null | wc -l)"
echo
echo "== one file, verbatim"
f=$(ls "$S"/* 2>/dev/null | head -1)
echo "  $f"
cat -A "$f" 2>/dev/null | head -6 | sed 's/^/    /'
echo
echo "== a bigger one"
f2=$(ls -S "$S"/* 2>/dev/null | head -1)
echo "  $f2 ($(stat -c %s "$f2" 2>/dev/null) bytes)"
head -6 "$f2" 2>/dev/null | sed 's/^/    /'
echo
echo "== how many files contain 'copied'"
echo "  $(grep -lc copied "$S"/* 2>/dev/null | wc -l) of $(ls "$S" | wc -l)"
echo
echo "== does the parser see bytes? test it on a single file"
single=$(ls -S "$S"/* 2>/dev/null | head -1)
awk '/copied,/ {
    for (i = 1; i <= NF; i++)
      if ($i ~ /^[0-9.]+$/ && $(i+1) == "MB") { mb += $i; print "    token: " $i " MB" }
      else if ($i ~ /^[0-9.]+$/ && $(i+1) == "MB/s") print "    (rate token " $i " MB/s, must NOT be counted)"
  }
  END { printf "    summed MB = %.0f\n", mb }' "$single"
echo
echo "== what awk does with a glob of this many files (ARG_MAX check)"
echo "  files: $(ls "$S" | wc -l)"
echo "  bytes if all summed: $(( $(ls "$S" | wc -l) * 18 )) MB"
echo
echo "== how many reads did an arm claim vs how many files exist"
echo "  claimed 13179 reads for A_17.5MB_s1; files now: $(ls "$S" | wc -l)"
echo "  note: filenames are \$stream.\$slot, so a repeated slot appends rather than truncates"