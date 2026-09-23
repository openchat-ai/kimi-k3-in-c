# SINKER NVMe box: 300G L2 A/B (Sep 2026)

Machine: WSL2, 16-core Hygon C86-3G, 27 GB DRAM, no GPU.
`/mnt/nvme` = SINKER SEV512THK-CEN physical Disk 2 partition 7 (ext4, 384 GB).
`/model` on /dev/sde (1.8 T virtual disk, ROTA=1, spinning) is the raw checkpoint;
all reads in these runs were L2/trunk hits on `/mnt/nvme`, `miss I/O: 0`.

## Steady-state decode, 93-layer full model, 2 generated tokens

`--ids 1008 --gen 2 --incremental --cache-gb 13 --l2-policy heat --embed-dir /mnt/nvme/embed`,
trunk floor 6 GB, L2 file = `/mnt/nvme/experts.l2`.

| L2 logical | s/token | getmany wall median | hit | resident slots | run |
|---|---|---|---|---|---|
| 200 GB (11397 slots) | 107.76 | 0.473 s | 100% | 5733/11397 | `reports/heat_auto_embed.json` |
| 300 GB (17096 slots) | **89.63** | 0.497 s | 100% | 6510/17096 | pass2 |
| 300 GB (17096 slots) | **89.19** | — | 100% | 6510/17096 | pass3 |

***300 GB L2 = 89.4 s/token avg, -17.0% vs 200 GB, reproducible within ±0.5 s.***
Per-token reads 82.5 GB (trunk 55.4 GB @925 MB/s + expert 25.8 GB @445-491 MB/s),
aggregate ~906 MB/s.

## Device ceiling measured

Random-slot 16-thread probe on `experts.l2` (`benchmarks/medium-ladder-out/par_read.c`,
1470 reads × 3 passes, cold cache): **1.70 / 1.75 / 1.50 GB/s (median 1.70)**.
Aggregate at 89.4 s/token is ~53% of; headroom exists but the gap to <80 s/token is
structural (getmany phase2 waits on the last expert; top-16 is only known after router).

## L2 state pollution caveat

Run order matters. A prior 93-layer run with a *different* id set (ids=19180, gen 8)
warmed a disjoint heat set and evicted id-1008's slots: id-1008 reruns then show
hit 80%→70%, write >0, getmany wall median 0.473→1.5-5 s, and the run times out.
After re-warming (one id-1008 pass) hit returns to 100%/write 0 and numbers above hold.
/ A/B with a dirty cache is invalid; warm the measured set first.