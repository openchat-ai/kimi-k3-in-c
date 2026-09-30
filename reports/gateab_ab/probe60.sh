#!/bin/bash
# "Didn't this used to be 60-something?" Sort every real measurement, then ask the only
# question that matters: were the fast ones measuring the same thing as the slow ones.
set -u
cd /mnt/f/kimi-k3-in-c
R=reports/gateab_ab

# Only ctrl.log and run.txt, never the ab*.sh scripts that merely contain the grep string.
find $R -name ctrl.log -o -name run.txt 2>/dev/null | while read -r f; do
  v=$(grep -aoE "[0-9.]+ s/token average" "$f" 2>/dev/null | head -1 | grep -oE "^[0-9.]+")
  [ -z "$v" ] && continue
  # trunk-gb / cache-gb / workers / prefetch, from the same log
  tg=$(grep -aoE "trunk \(STREAMED\) [0-9.]+ GB" "$f" | head -1 | grep -oE "[0-9.]+" | head -1)
  cg=$(grep -aoE "expert cache +[0-9]+ slots x [0-9.]+ MB = [0-9.]+ GB" "$f" | head -1 | grep -oE "= [0-9.]+" | tr -d '= ')
  pw=$(grep -aoE "lookahead depth [0-9]+ layer" "$f" | head -1 | grep -oE "[0-9]+")
  nw=$(grep -aoE "nw=[0-9]+" "$f" | head -1 | grep -oE "[0-9]+")
  tok=$(grep -aoE "[0-9]+ tokens in" "$f" | head -1 | grep -oE "[0-9]+")
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$v" "${tg:-?}" "${cg:-?}" "${nw:-?}" "${pw:-0}" "${tok:-?}" "$f"
done | sort -n > /tmp/all_runs.tsv

echo "== distribution of every real run"
awk -F'\t' '{print $1}' /tmp/all_runs.tsv | sort -n | awk '
  {a[NR]=$1}
  END{ printf "  n=%d  min=%.2f  p25=%.2f  median=%.2f  p75=%.2f  max=%.2f\n",
    NR, a[1], a[int(NR*0.25)+1], a[int(NR/2)], a[int(NR*0.75)], a[NR] }'

echo
echo "== the fastest 8: what config, how many tokens"
head -8 /tmp/all_runs.tsv | while IFS=$'\t' read -r v tg cg nw pw tok f; do
  printf "  %6s  trunk=%-5s cache=%-5s nw=%-3s pf=%-2s tokens=%-3s  %s\n" \
    "$v" "$tg" "$cg" "$nw" "$pw" "$tok" "${f#$R/}"
done

echo
echo "== the slowest 5"
tail -5 /tmp/all_runs.tsv | while IFS=$'\t' read -r v tg cg nw pw tok f; do
  printf "  %6s  trunk=%-5s cache=%-5s nw=%-3s pf=%-2s tokens=%-3s  %s\n" \
    "$v" "$tg" "$cg" "$nw" "$pw" "$tok" "${f#$R/}"
done

echo
echo "== runs below 70 s/token: are they 1-token or 3-token runs?"
awk -F'\t' '$1<70 {print $6}' /tmp/all_runs.tsv | sort | uniq -c | sed 's/^/  tokens=  count /'
echo "== all runs: tokens column distribution"
awk -F'\t' '{print $6}' /tmp/all_runs.tsv | sort | uniq -c | sed 's/^/  tokens=  count /'

echo
echo "== below 70 with 3 tokens (i.e. not a cold-start artefact):"
awk -F'\t' '$1<70 && $6==3 {printf "  %s  %s/%s nw=%s pf=%s  %s\n",$1,$2,$3,$4,$5,$7}' /tmp/all_runs.tsv

echo
echo "== median of 3-token runs only, vs all runs"
for cond in "all" "3tok"; do
  if [ "$cond" = "3tok" ]; then awk -F'\t' '$6==3{print $1}' /tmp/all_runs.tsv; else cut -f1 /tmp/all_runs.tsv; fi \
    | sort -n | awk -v c="$cond" '{a[NR]=$1} END{printf "  %-5s n=%-3d median=%.2f\n", c, NR, a[int(NR/2)]}'
done
