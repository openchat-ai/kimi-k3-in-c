#!/bin/bash
# Pull together the day. Not a benchmark -- nothing here is a new measurement, it is the
# accounting of 14 experiments that is.
#
# The chain, in the order it actually happened, because the order is the argument:
#
#   1. The headline was wrong. For most of the day I quoted "a 6.2x gap between the engine
#      and the drive". The engine's 439 MB/s comes from l2->bytes_read, which counts the
#      expert L2 path only. trunk_bytes_read is a separate counter in the same json and I
#      had not looked at it: 140.16 GB against 76.51 GB. The engine moves 216.66 GB in
#      243 s = 891 MB/s, and the gap is 2.77x, not 6.2x. Every exclusion list I built was
#      about a number that was too large by more than half.
#
#   2. Six exclusions were real but were not the cause, because there was less to explain
#      than I thought. Kept anyway, they are the only things now known not to matter:
#      page cache (the engine is O_DIRECT throughout), device cache (v39 preconditioned
#      40 GB, still 1377 against 410), burst size (v40, R=1..16 in one order of magnitude),
#      concurrency (the engine already sustains 11.4x; v40 flat from R=4), the kio hop
#      (v44, five arms 2776-3209), phase-1 serialisation (0.02 s/token), refill writes
#      (misses 0, written 0.00 GB), fd selection (v51, 3134 O_DIRECT and 0 buffered).
#
#   3. Four candidates were killed by their own data, each after I had believed them:
#      layer pause (v48: the engine never pauses -- the expert read is 100% inside compute),
#      the window mismatch (v47: 420 s continuous and flat, so it was not a burst-vs-steady
#      artefact), prefetch (v50: 0.75x, and with it the "degraded path" theory -- depth 0
#      is the better configuration), and the reading that v36/v40 were contaminated by a
#      stale slot count (v46: the same continuous arm is stable within 1.13x five times out
#      of six, so the curve was never the artefact I claimed).
#
#   4. Where it actually goes, from counters in the pool rather than probes around it
#      (v52, five counters in k3_io.c):
#
#          kio tier0: 4595 reqs, 216.66 GB, device 109 MB/s
#          queue 52.8 s (2.7% of request time), submit-lock 1.8 s, worker-lock 0.0 s
#          workers inside pread 1988 of 3891 available worker-seconds
#
#      Nothing is queued, nothing is contended, and the workers are asleep about half the
#      time. The drive is idle during arithmetic, because each layer reads, then computes,
#      and the next layer's read cannot be issued until that compute retires. The drive
#      could move 216.66 GB in 88 s; it took 243 s.
#
#   5. The obvious fix does not exist. Feeding the drive across layers is what prefetch is
#      for, and it fails twice over. At 15 GB of arena (v50) it reads 1235 experts and 21%
#      are still resident when the forward thread arrives, and it costs throughput because
#      the wasted reads compete. Making the arena bigger does not fix the survival rate
#      (v54): 1367 slots instead of 854 moved survival from 21.4% to 21.7%, because the
#      evictions were never a capacity problem. And buying that arena costs trunk residency
#      -- 22 of 93 layers down to 15 -- so the trunk streams more, and the queue share went
#      from 2.6% to 11.1% of request time. 75.5 s/token became 126.2. The sequential trunk
#      stream and the scattered expert stream cannot both get faster on one device.
#
# So the answer is not a bug that thirteen experiments failed to find. It is the shape of
# the workload: arithmetic and I/O alternate strictly, and the device idles through half of
# it. The remaining lever is changing that alternation -- cross-layer software pipelining,
# which does not exist in this engine today -- or more devices, which is not on the table.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/DAY1
mkdir -p "$OUT"

{
echo "===================================================================="
echo "kimi-k3-in-c, 2026-09-29/30: what was established and what was not"
echo "===================================================================="
echo
echo "THE HEADLINE, CORRECTED"
echo "-----------------------"
echo "  engine total  216.66 GB / 243.2 s = 891 MB/s   (trunk 140.16 + expert 76.51)"
echo "  device, same file, O_DIRECT       2463 MB/s    (v47, 420 s continuous, flat)"
echo "  gap 2.77x"
echo
echo "  For most of the day the figure quoted was 439 MB/s, which is l2->bytes_read"
echo "  alone: the expert path. trunk_bytes_read sat unused in the same json."
echo "  Every exclusion list was built around a gap more than twice the real one."
echo
echo "EXCLUDED WITH DATA (not causes; they are the things now known not to matter)"
echo "------------------------------------------------------------------------"
echo "  page cache      engine is O_DIRECT throughout; v51 counted 3134 O_DIRECT, 0 buffered"
echo "  device cache    v39 wrote 40 GB over the cache, 1377 vs 410 remains"
echo "  burst size      v40, R=1..16 all within one order of magnitude"
echo "  concurrency     engine sustains 11.4x already; v40 flat from R=4 onward"
echo "  kio hop         v44, five arms 2776-3209 MB/s, differences inside noise"
echo "  phase-1 lock    0.02 s per token against 70 s of wall"
echo "  refill writes   misses 0, written 0.00 GB, the critical section never entered"
echo
echo "CANDIDATES KILLED BY THEIR OWN DATA (each one I had believed)"
echo "-----------------------------------------------------------"
echo "  layer pause     v48: the engine never pauses; expert reads are 100% inside compute"
echo "  window mismatch v47: 420 s continuous is flat, so not a burst-vs-steady artefact"
echo "  prefetch        v50: 0.75x. depth 0 is the BETTER setting, so 'degraded path' is dead"
echo "  probe pollution v46: the same arm is stable within 1.13x in 5 of 6 runs"
echo
echo "WHERE THE 2.77x ACTUALLY GOES (v52, counters in the pool)"
echo "------------------------------------------------------------"
grep -ahE "^kio tier" reports/gateab_ab/v52_counters/run-*/ctrl.log | head -1 | sed 's/^/  /'
echo "  workers inside pread  1988 s of 3891 available worker-seconds = 51%"
echo "  -> queue 2.7%, locks ~0, workers asleep ~49%: the device is idle during arithmetic"
echo "  -> the drive could move 216.66 GB in 88 s; it took 243 s"
echo
echo "WHY THE FIX IS NOT AVAILABLE"
echo "---------------------------"
echo "  v50  15 GB arena, prefetch on : issued 1235, survival 21.1%, 355 vs 476 MB/s"
echo "  v54  24 GB arena, prefetch on : survival 21.7% (854->1367 slots moved it 0.3pp),"
echo "                                  trunk residency 22->15 layers, queue 2.6%->11.1%,"
echo "                                  75.5 -> 126.2 s/token"
echo "  -> the evictions were never a capacity problem, and buying arena costs trunk"
echo "     residency, so the sequential and scattered streams fight over one device"
echo
echo "THE INSTRUMENT LESSON (BENCH_PROTO section 13)"
echo "----------------------------------------------"
echo "  Thirteen external experiments failed to localise it. The read path is 1500 lines"
echo "  across 58 functions, and five counters in k3_io.c answered it in one run."
echo
echo "  The four instrument defects, all of the same kind -- assuming instead of reading:"
echo "    * a short read was explained as 'past EOF' when errno said EBADF"
echo "    * NSLOT was computed (300 GB / slot) when the engine prints the true value"
echo "    * a struct declared inside a for loop outlived its threads by luck"
echo "    * a report was attached to k3_io_free, which the engine never calls"
echo
echo "  Two of the conclusions drawn from them were wrong on contact with the next"
echo "  experiment, and one of those ('v40 was contaminated') I had to retract."
echo
echo "OPEN, NOT CLOSED"
echo "-----------------"
echo "  * cross-layer pipelining: issue layer L+1's reads during layer L's arithmetic."
echo "    Not implemented; this is the only lever the measurements point at."
echo "  * hit_wall reported 0.00 s in one run while pread_seconds was 1742.60 s."
echo "    Unexplained. Every engine hit I/O rate quoted here comes from a run where"
echo "    hit_wall was sane, but the field is unreliable and should not be trusted blindly."
echo "  * stat_idle_s only samples the instant a worker finds the queue empty, not its"
echo "    sleep, so it proves nothing. The 49% figure is arithmetic on the other counters."
} | tee "$OUT/summary.txt"

echo
echo "wrote $OUT/summary.txt"
wc -l < "$OUT/summary.txt"
