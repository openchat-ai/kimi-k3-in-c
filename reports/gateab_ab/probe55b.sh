#!/bin/bash
# /proc/diskstats exists and sdd7 appears in the name column, but grepping for a trailing
# sdd7 returns nothing. Find out which of those three is true: the file is sparse, the row
# format differs from what I assumed, or the fields I need are zero.
set -u
echo "== byte count and line count"
wc -lc /proc/diskstats

echo
echo "== all lines, cat -A on the sdd7 one to show any trailing characters"
awk '$3 ~ /^sdd7?$/ {print NR": ["$0"]"; printf "  fields=%d\n", NF}' /proc/diskstats

echo
echo "== sdd7 fields, numbered"
awk '$3 ~ /^sdd7?$/ {for(i=1;i<=NF;i++) printf "  [%2d] %s\n", i, $i}' /proc/diskstats

echo
echo "== compare: sda (the disk Windows boots from) for layout reference"
awk '$3=="sda" {printf "  sda fields=%d\n", NF; for(i=1;i<=NF;i++) printf "  [%2d] %s\n", i, $i}' /proc/diskstats

echo
echo "== does a read move the sectors field? 1s apart on sdd7"
a=$(awk '$3=="sdd7"{print $6}' /proc/diskstats)
am=$(awk '$3=="sdd7"{print $7}' /proc/diskstats)
echo "  before: sectors=$a  ms_reading=$am"
head -c 200000000 /dev/zero 2>/dev/null > /dev/null || dd if=/dev/zero of=/dev/null bs=1M count=64 2>/dev/null
sleep 1
b=$(awk '$3=="sdd7"{print $6}' /proc/diskstats)
bm=$(awk '$3=="sdd7"{print $7}' /proc/diskstats)
echo "  after : sectors=$b  ms_reading=$bm"
echo "  delta : sectors=$((b-a))  ms=$((bm-am))"

echo
echo "== what does /proc/partitions say about sdd7"
grep -E 'sdd' /proc/partitions | sed 's/^/  /'
