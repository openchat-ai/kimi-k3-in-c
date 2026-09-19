# Medium ladder — measured 2026-09-19

All rates are median-of-3 on this machine; disk reads are O_DIRECT cold
(drop_caches, root), writes are O_DIRECT temp-file probes. Per-token traffic:
trunk 108.81 GB + experts 25.83 GB = 134.64 GB/token; compute
5.6 TFLOP/token. Tier names: 超高 (near-memory
compute) is not configured on this machine and is excluded.

| 档位 | 硬件 | 容量 | 读取 | 写入 | 算力 | 全走此墙 s/token |
|---|---:|---:|---:|---:|---:|---:|
| **高**（DRAM，本机最快可达档） | DDR4 27 GB | 27 GB | 32 GB/s | 32 GB/s | — | **4.2** |
| **超低**（源盘，专家 /model） | /dev/sde |  1.8T | 92.3 MB/s | 133.6 MB/s | — | **1458.7** |
| **低**（高速盘，trunk/L2） | /dev/sdd7 |  384G | 947.9 MB/s | 967.2 MB/s | — | **142.0** |
| **—**（算力墙） | Hygon C86-3G (OPN:3350) 16C/16T | — | — | — | 88 GFLOPS fp32 峰值 | **63.3** |

结论口径（慢层只读一次原则）：输出不取决于"每道墙都满速"——盘的上限是独占测的，
同时跑会互相砍半（gate 存在的原因）；总时间 = max(各墙)，不是求和。唯一能飞的
路径是让复用落在最快层（DRAM），把每 token 135 GB 的重读降为内存搬运。
