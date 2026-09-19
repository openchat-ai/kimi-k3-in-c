# Medium ladder — measured 2026-09-19

All rates are median-of-3 on this machine; disk reads are O_DIRECT cold
(drop_caches, root) of the named production file, writes are O_DIRECT
temp-file probes removed afterwards. A read can be slower than a write
when the read target is a fragmented file on a near-full volume while
the write lands on contiguous free space -- both numbers are the real
path they measure. Per-token traffic:
trunk 108.81 GB + experts 25.83 GB = 134.64 GB/token; compute
5.6 TFLOP/token. Tier names: 超高 (near-memory
compute) is not configured on this machine and is excluded.

| 档位 | 硬件 | 容量 | 读取 | 写入 | 算力 | 全走此墙 s/token |
|---|---:|---:|---:|---:|---:|---:|
| **高**（DRAM，本机最快可达档） | DDR4 27 GB | 27 GB | 31 GB/s | 31 GB/s | — | **4.4** |
| **超低**（源盘，专家 /model） | /dev/sde |  1.8T | 88 (87-92) MB/s | 150.2† MB/s | — | **1530.0** |
| **低**（高速盘，trunk/L2） | /dev/sdd7 |  384G | 534 (513-538) MB/s | 588.6 MB/s | — | **252.1** |
| **—**（算力墙） | Hygon C86-3G (OPN:3350) 16C/16T | — | — | — | 89 GFLOPS fp32 峰值 | **62.6** |

† virtual disk: guest-side O_DIRECT+fsync flush only to the hypervisor
  layer, the host cache absorbs the write, so this is an upper bound,
  not the physical write rate.
结论口径（慢层只读一次原则）：输出不取决于"每道墙都满速"——盘的上限是独占测的，
同时跑会互相砍半（gate 存在的原因）；总时间 = max(各墙)，不是求和。唯一能飞的
路径是让复用落在最快层（DRAM），把每 token 135 GB 的重读降为内存搬运。
