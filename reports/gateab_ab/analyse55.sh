#!/bin/bash
# v55 measured the device with dd, using the engine's own access shape, and it corrects two
# things this file previously got wrong.
#
# CORRECTION 1 -- the device ceiling was never 2463 MB/s.
# The 2463 figure came from a large-block benchmark. The engine reads 17.5 MB expert slots on
# 4M alignment with O_DIRECT, and on that shape the device delivers:
#
#     1 stream   4M    1331 MB/s
#     4 streams  4M    1626 MB/s
#     8 streams  4M    1596 MB/s
#    16 streams  4M    1537 MB/s
#    32 streams  4M    1602 MB/s
#
# So the ceiling is about 1600, and concurrency stops buying anything past 4 streams: 8x the
# streams from 4 to 32 returns zero. The engine's 891 MB/s is therefore 56% of what the
# device can do in this shape, and the gap is 1.8x, not the 2.77x this file reported from
# dividing 2463 by 891. Both the gap and its explanation survive; the denominator did not.
#
# CORRECTION 2 -- the scattered and sequential streams do not fight over the device.
# The v54 commit message said the sequential trunk stream and the scattered expert stream
# cannot both get faster on one device. Measured directly, that is wrong:
#
#    16 streams 4M sequential   1537 MB/s
#    16 streams 4M scattered    1740 MB/s     <- faster, not slower
#
# Scattered access at this block size is not the problem, and the arena's trunk-residency
# cost is still real (v54 measured 75.5 becoming 126.2 s/token) but it is not a contention
# effect between two access patterns. That leaves the prefetcher's slowdown unexplained by
# anything on the device side, which is worth a look next.
#
# The 51% figure, which is the day's actual finding, is now confirmed by two independent
# methods that agree: the engine's own counters say the workers are inside pread 51% of
# available worker-seconds, and dd says the device is handed 56% of the traffic it could
# absorb. Neither depends on the other.
set -u
cd /mnt/f/kimi-k3-in-c
OUT=reports/gateab_ab/v55_stream
{
echo "===================================================================="
echo "v55: the device measured in the engine's own access shape"
echo "===================================================================="
echo
echo "ACCESS SHAPE"
echo "  O_DIRECT, 4M blocks, sequential unless noted, 2 GiB per arm"
echo "  source layer_000.bin, 2232 MiB -- larger than the 2 GiB requested,"
echo "  so no arm was truncated at end of file"
echo
echo "BLOCK SIZE, SINGLE STREAM"
awk -F'\t' '$3==1 {printf "  bs=%-5s %6s MB/s\n", $2, $4}' "$OUT/raw.txt"
echo "  16K is 1/18 of 4M. The engine reads 17.5 MB slots on 4M alignment,"
echo "  so it is on the good side of this cliff, not the bad side."
echo
echo "CONCURRENCY AT 4M"
awk -F'\t' '$2=="4M" && $4 !~ /strided/ {printf "  %2s streams  %6s MB/s\n", $3, $4}' "$OUT/raw.txt"
echo "  4 streams to 32 streams: 8x the concurrency, zero gain."
echo
echo "CONCURRENCY AT 1M"
awk -F'\t' '$2=="1M" && $3==16 {printf "  16 streams  %6s MB/s\n", $4}' "$OUT/raw.txt"
echo
echo "SCATTERED VERSUS SEQUENTIAL"
awk -F'\t' '/strided/ {printf "  %-18s %6s MB/s\n", $1, $4}' "$OUT/raw.txt"
echo "  scattered at 4M is faster than sequential at 4M."
echo
echo "REPEATABILITY, SAME CONFIGURATION TWICE"
echo "  1 stream 4M     1331 / 1024      25%   (small sample)"
echo "  16 streams 4M   1537 / 1569       2%"
echo "  32 streams 4M   1602 / 1606       0.2%"
echo "  16x 4M strided  1740 / 1728       0.7%"
echo "  the concurrency groups repeat to 1-4%; the single-stream group does not,"
echo "  which is why the ceiling is quoted from 4 streams and up, not from 1."
echo
echo "THE NUMBER, CORRECTED"
echo "---------------------"
echo "  device ceiling, engine's shape    ~1600 MB/s   (4 streams, 4M, O_DIRECT)"
echo "  engine, same drive                891 MB/s    (216.66 GB / 243.2 s, v52)"
echo "  utilisation                        56%"
echo "  gap                               1.80x"
echo
echo "  previously reported in this file:  2463 MB/s ceiling, 2.77x gap"
echo "  where 2463 came from: a large-block benchmark, not 4M O_DIRECT."
echo "  Comparing the engine against a number from a different access shape is the"
echo "  same class of error as comparing l2->bytes_read against total bytes, which"
echo "  is the mistake the first third of this file describes."
echo
echo "WHAT THIS DOES NOT EXPLAIN"
echo "-------------------------"
echo "  prefetch is slower at every arena size (v50 0.75x, v54 0.60x) and 21% of"
echo "  prefetched experts survive to be used. Neither is a device effect: the"
echo "  device does not care about the pattern, and there is spare bandwidth."
echo "  So the cost is on the host side -- CPU, contention, or the survival"
echo "  measurement itself being wrong. Note the 21% survival figure has been"
echo "  quoted since v50 without being independently checked, and stat_idle_s and"
echo "  hit_wall have both turned out to be broken counters in the same run."
echo "  Treat it as unverified."
} | tee "$OUT/ANALYSIS.txt"
echo
echo "wrote $OUT/ANALYSIS.txt"
