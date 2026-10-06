#!/bin/bash
# Can paper table 3 be reproduced? v62 ran the four arms with 57.8 GB available and the engine
# planning 52.3 GB, so neither policy had to evict and they converged (heat 25.50 vs LRU 25.83
# GB/token, -1.3%, and cache 8 vs 15 made no difference at all). Table 3's own qualifier is a
# 26 GB cgroup cap, and heat's stated advantage (k3_cache.c:707, evict lowest cumulative count)
# only exists when there is pressure to evict under. So the condition has to be reproduced, not
# the arms.
#
# Uses systemd-run --scope with MemoryMax. If systemd is unavailable in this WSL guest the
# script says so and exits rather than silently running the arms unconstrained -- an
# unconstrained run already exists (v62) and repeating it would produce a second copy of a
# result that cannot test the claim.
#
# Judged on the byte column, as in v62: bytes are stable to the digit, s/token spans 36% and
# cannot decide a 6-19% difference. Verdict per BENCH_PROTO 14.1.
set -u
cd /mnt/f/kimi-k3-in-c

CAP=26G
echo "== 能否施加 ${CAP} 硬上限"
if ! systemd-run --scope --quiet -p MemoryMax=$CAP /bin/true 2>&1; then
  echo "  systemd-run 不可用 -- 不跑。"
  echo "  理由：无上限运行已由 v62 完成且不能检验本主张；重复它只会得到第二份同样无约束的结果。"
  echo "  替代方案（需明确标注为偏离）：把内存计划压到 ≈26 GB（--trunk-gb/--cache-gb 之和 ≈20 GB），"
  echo "  但那是减少计划容量而非施加压力，机制不同，不能替代 cgroup 上限。"
  exit 2
fi
echo "  systemd-run 可用"

# Confirm the cap actually bites before spending an hour on it.
echo
echo "== 校验上限是否真的生效"
systemd-run --scope --quiet -p MemoryMax=$CAP \
  bash -c 'awk "/MemTotal/{printf \"  cgroup 视图 MemTotal = %.1f GB\n\", \$2/1048576}" /proc/meminfo' 2>&1
echo "  （宿主视角 $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo)）"

OUT=reports/gateab_ab/v63_policy_cgroup
mkdir -p "$OUT"
: > "$OUT/raw.tsv"

run() {   # $1 tag, $2 policy, $3 cache-gb
  local tag=$1 pol=$2 cg=$3
  local LOG="$OUT/$tag"
  mkdir -p "$LOG"
  unset K3_TRACE K3_NOKIO K3_L2_NATIVE K3_IO_NW0 K3_SPREAD_DBG
  systemd-run --scope --quiet -p MemoryMax=$CAP \
    ./bin/k3 /model \
      --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
      --trunk-gb 32 --cache-gb "$cg" --l1-policy "$pol" \
      --ids 1008 --gen 3 --out "$LOG/ctrl.json" > "$LOG/ctrl.log" 2>&1
  local gb tok spt
  gb=$(grep -aoE "experts, whole run: [0-9.]+ GB read" "$LOG/ctrl.log" | grep -oE "[0-9.]+" | tail -1)
  tok=$(grep -aoE "[0-9]+ tokens in" "$LOG/ctrl.log" | head -1 | grep -oE "[0-9]+")
  spt=$(grep -aoE "[0-9.]+ s/token average" "$LOG/ctrl.log" | head -1 | grep -oE "^[0-9.]+")
  if [ -z "$gb" ] || [ -z "$tok" ]; then
    echo "  $tag: no byte figure (likely OOM-killed under the cap) -- not recording"
    grep -aE "memory plan|TOTAL|available|available|Killed|oom" "$LOG/ctrl.log" | head -4 | sed 's/^/      /'
    return 1
  fi
  local per; per=$(awk -v g="$gb" -v t="$tok" 'BEGIN{printf "%.2f", g/t}')
  printf "  %-14s policy=%-4s cache=%-3s  %5s GB/token   %s s/tok\n" "$tag" "$pol" "$cg" "$per" "${spt:-?}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$tag" "$pol" "$cg" "$per" "$spt" >> "$OUT/raw.tsv"
  return 0
}

sleep 180
for _ in $(seq 1 80); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  awk -v a="$l" 'BEGIN{exit !(a<0.5)}' && break
  sleep 15
done
echo "idle: load=$(cut -d' ' -f1-3 /proc/loadavg)  $(date +%T)"

for r in 1 2 3; do
  echo "[round $r] $(date +%T)"
  run "lru8_r$r"  lru  8  || exit 1
  sleep 20
  run "heat8_r$r" heat 8  || exit 1
  sleep 20
  run "lru15_r$r" lru  15 || exit 1
  sleep 20
  run "heat15_r$r" heat 15 || exit 1
  sleep 20
done

echo
python3 - <<'PY'
import statistics, collections
d = collections.defaultdict(list)
try:
    for line in open("reports/gateab_ab/v63_policy_cgroup/raw.tsv"):
        tag, pol, cg, per, spt = line.rstrip("\n").split("\t")
        d[f"{pol}{cg}"].append(float(per))
except FileNotFoundError:
    print("  no raw.tsv"); raise SystemExit
print(f"  {'arm':<10}{'n':>3}{'GB/token per round':>34}{'median':>9}")
for a in ("lru8","heat8","lru15","heat15"):
    if d[a]:
        print(f"  {a:<10}{len(d[a]):>3}   {', '.join(f'{x:6.2f}' for x in d[a]):>28}{statistics.median(d[a]):>9.2f}")
def pair(a,b,claim):
    if len(d[a]) != len(d[b]) or not d[a]:
        print(f"  {a} vs {b}: incomplete"); return
    diffs=[100*(x-y)/y for x,y in zip(d[a],d[b])]
    med=statistics.median(diffs)
    spread=(max(diffs)-min(diffs))/abs(med)*100 if med else float('inf')
    flips=len({1 if x>0 else -1 for x in diffs})>1
    print(f"  {a} vs {b}: paired {[f'{x:+.1f}' for x in diffs]}  median {med:+.1f}%  spread {spread:.0f}%")
    print(f"      paper claims {claim}")
    if flips or spread>=100: print("      -> CANNOT MEASURE (14.1)")
    elif abs(med)>=5:         print(f"      -> reproduced: {med:+.1f}% exceeds a 5% byte threshold")
    else:                     print(f"      -> NOT reproduced: {med:+.1f}% is below 5%")
print()
pair("lru8","heat8","25.83 -> 20.99 GB/token (-19%)")
pair("lru15","heat15","25.83 -> 17.44 GB/token (-32%)")
PY
echo "end $(date +%T)"