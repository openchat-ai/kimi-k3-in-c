#!/bin/bash
# Is the concurrency question decidable from outside the engine?
#
# The open question (FINDINGS.md 3.4): the 3046 cond_waits -- are workers woken late because
# the next request arrives late, or because the kernel took the worker off its core?
#
# Queue depth cannot tell those apart. A worker descheduled while holding a request has
# already dequeued it, so the request is in-flight and invisible in the queue. That is why the
# earlier "the queue only backs up 3%, so it is not CPU starvation" inference does not hold.
#
# /proc/<tid>/schedstat does tell them apart, and it is kernel accounting rather than a
# hardware PMU counter, so the absence of perf events on this platform does not matter:
#   field 1 = ns on CPU, field 2 = ns waiting on the runqueue, field 3 = timeslices
#
#   runqueue wait large relative to on-CPU  -> workers are CPU-starved, remedy is how they wait
#   runqueue wait ~0 while the engine reports cond_wait time
#                                           -> they are idle for want of work, remedy is the
#                                              producer's cadence
#
# Nothing here rebuilds the engine: the run is the same command ab56.sh used, same geometry
# (32 GB trunk / 15 GB cache, ids 1008, gen 3), and schedstat is read twice, at start and at
# end, so the probe adds no sampling overhead to perturb the run.
set -u

# A background WSL session does not inherit an attached disk. Running the engine against an
# empty /mnt/nvme would fail on geometry rather than on the thing being measured, so refuse.
echo "== 几何门禁"
miss=0
for d in /mnt/nvme/trunk_layers_out /mnt/nvme/embed; do
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    echo "  ok   $d"
  else
    echo "  ★ 缺失或为空：$d"
    miss=1
  fi
done
[ "$miss" -ne 0 ] && {
  echo "  ★ /mnt/nvme 未挂载或几何不全 —— 需先 wsl.exe --mount \\\\.\PHYSICALDRIVE2 --partition 7"
  echo "    再 mount --bind /mnt/wsl/PHYSICALDRIVE2p7 /mnt/nvme，中止"
  exit 5
}

echo "== schedstat 可用性自检"
ok=0
for t in /proc/1/task/*; do
  s=$(cat "$t/schedstat" 2>/dev/null || true)
  if [ -n "$s" ]; then ok=$((ok + 1)); fi
done
if [ "$ok" -eq 0 ]; then
  echo "  ★ pid 1 的任何线程都没有 schedstat —— 内核未启用 CONFIG_SCHEDSTATS"
  echo "  ★ 该判据在本平台不可用，改用 /proc/<tid>/status 的上下文切换计数（粒度更粗）"
  exit 2
fi
echo "  $ok 个线程可读 schedstat，可用"
echo "  样例（comm : on_cpu_ns runqueue_wait_ns timeslices）:"
for t in /proc/1/task/*; do
  s=$(cat "$t/schedstat" 2>/dev/null || true)
  if [ -n "$s" ]; then echo "    $(cat "$t/comm" 2>/dev/null) : $s"; fi
done | head -4

echo
echo "== 本机拓扑"
echo "  nproc = $(nproc)"
echo "  loadavg = $(cat /proc/loadavg)"
grep -m1 "model name" /proc/cpuinfo | sed 's/^/  /'

# ---- wait for the machine to be idle; a contaminated run is worse than no run ----
echo
echo "== 空闲门禁（与 ab56.sh 同口径：loadavg(1min) < 0.5）"
sleep 60
for i in $(seq 1 60); do
  l=$(cut -d' ' -f1 /proc/loadavg)
  if awk -v a="$l" 'BEGIN{exit !(a<0.5)}'; then
    echo "  idle: load=$l  $(date +%T)"
    break
  fi
  [ "$i" -eq 60 ] && { echo "  ★ 15 分钟内未达空闲（load=$l），中止 —— 不在受污染环境下测量"; exit 3; }
  sleep 15
done

LOG=reports/gateab_ab/v64_schedstat
mkdir -p "$LOG"
RUN="$LOG/run-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN"

snap() {   # $1 = output file, $2 = pid
  : > "$1"
  for t in /proc/$2/task/*; do
    tid=$(basename "$t")
    comm=$(cat "$t/comm" 2>/dev/null || echo '?')
    st=$(cat "$t/schedstat" 2>/dev/null || echo "")
    sw=$(grep -E 'voluntary_ctxt_switches|nonvoluntary_ctxt_switches' "$t/status" 2>/dev/null \
         | awk '{print $2}' | paste -sd+ - | bc 2>/dev/null || echo "")
    echo "$tid $comm ${st:-none} ${sw:-none}" >> "$1"
  done
}

echo
echo "== 启动引擎（真实几何：trunk 32GB / cache 15GB，ids 1008，gen 3）"
echo "  $RUN"
./bin/k3 /model \
  --trunk /mnt/nvme/trunk_layers_out --embed-dir /mnt/nvme/embed \
  --trunk-gb 32 --cache-gb 15 \
  --ids 1008 --gen 3 --out "$RUN/ctrl.json" > "$RUN/ctrl.log" 2>&1 &
KPID=$!
sleep 5
if ! kill -0 "$KPID" 2>/dev/null; then
  echo "  ★ 引擎 5 秒内退出，原始输出保留在 $RUN/ctrl.log，中止"
  tail -20 "$RUN/ctrl.log"
  exit 4
fi
echo "  pid=$KPID 线程数=$(ls /proc/$KPID/task | wc -l)"

# The first version snapshotted after `wait`, by which time the process was gone and
# /proc/$KPID/task was empty -- it reported the criterion as unusable rather than wrong, which
# is the right way to fail, but it produced no measurement. schedstat is a monotonic cumulative
# counter, so a sample taken while the process is alive is enough; it has to be taken before
# exit. Sampling 26 small proc files every 2s is on the order of 13 reads per second, which is
# too small to perturb a run measured in minutes.
snap "$RUN/sched_first.txt" "$KPID"
SAMPLES=0
(
  while kill -0 "$KPID" 2>/dev/null; do
    snap "$RUN/.sched_cur.txt" "$KPID" 2>/dev/null || true
    [ -s "$RUN/.sched_cur.txt" ] && cp "$RUN/.sched_cur.txt" "$RUN/sched_last.txt"
    SAMPLES=$((SAMPLES + 1))
    sleep 2
  done
) &
SAMPLER=$!

echo "  运行中（不轮询日志）……"
wait "$KPID"
RC=$?
kill "$SAMPLER" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true
echo "  引擎退出 rc=$RC  $(date +%T)  采样轮次≈$SAMPLES"

echo
echo "== 引擎自报（作为对照）"
grep -aE "s/token average|^kio tier0|^ +group|sleep" "$RUN/ctrl.log" | sed 's/^/  /' | head -24

echo
echo "== 逐线程 schedstat 增量（on_cpu_ns  runqueue_wait_ns  timeslices）"
python3 - "$RUN/sched_first.txt" "$RUN/sched_last.txt" <<'PY'
import sys, pathlib

def load(p):
    d = {}
    for ln in pathlib.Path(p).read_text().splitlines():
        f = ln.split()
        if len(f) >= 4 and f[2] != "none":
            try:
                d[f[0]] = (f[1], int(f[2]), int(f[3]), int(f[4]))
            except ValueError:
                pass
    return d

b, a = load(sys.argv[1]), load(sys.argv[2])
rows = []
for tid, (comm, on0, wait0, sl0) in b.items():
    if tid not in a:
        continue
    _, on1, wait1, sl1 = a[tid]
    don, dwait, dsl = on1 - on0, wait1 - wait0, sl1 - sl0
    if don + dwait < 100_000_000:      # <0.1 s: thread did nothing in this window
        continue
    rows.append((comm, tid, don, dwait, dsl))

rows.sort(key=lambda r: -(r[2] + r[3]))
print("  %-6s %14s %14s %8s %9s" %
      ("tid", "on_cpu_ms", "runqueue_ms", "timesl", "wait/oncpu"))
tot_on = tot_wait = 0
main_on = main_wait = 0
for comm, tid, don, dwait, dsl in rows:
    r = dwait / don if don else float("inf")
    print("  %-6s %14.1f %14.1f %8d %9.4f"
          % (tid, don / 1e6, dwait / 1e6, dsl, r))
    tot_on += don
    tot_wait += dwait
    if tid == min(b, key=int):          # main thread = the producer
        main_on, main_wait = don, dwait

if not rows:
    print("  ★ 无线程有可读增量 —— 判据不可用")
    sys.exit(2)

print("  %-6s %14.1f %14.1f" % ("合计", tot_on / 1e6, tot_wait / 1e6))
r = tot_wait / tot_on if tot_on else float("inf")
print("  参与统计线程数 %d / %d" % (len(rows), len(b)))
print()
print("  主线程（producer）在核 %.1f ms，运行队列等待 %.1f ms，比值 %.4f"
      % (main_on / 1e6, main_wait / 1e6, (main_wait / main_on) if main_on else float("inf")))
print()
if r > 0.20:
    print("  判定：CPU 受限。worker 有 %.0f%% 的在核时间花在等待被调度上。" % (100 * r))
    print("        对应处置是改 worker 的等待方式（自旋/忙等改阻塞），而不是加 worker。")
elif r > 0.02:
    print("  判定：介于两者之间（等待/在核 = %.4f）。既有调度损失也有等活。" % r)
else:
    print("  判定：非 CPU 受限。worker 上核后极少被抢走（等待/在核 = %.4f）。" % r)
    print("        故那 40–49%% 的 cond_wait 是等下一个请求迟到，对应处置是改生产者节律。")
PY
echo
echo "  原始件：$RUN"