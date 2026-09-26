# NVMe 带宽微基准结论 — /mnt/nvme (SINKER SEV512THK)

日期：2026-09-26  测量：reports/nvme_bench/bench_20260926_113449.log (v1) + bench_20260926_114142.log (v2)

## 实测结果（读 /dev/sdd7，ext4 noatime）

| 场景 | O_DIRECT | buffered | 倍差 |
|---|---|---|---|
| 顺序 trunk 1 线程 16-20GiB | 771 MB/s | 353 MB/s | 2.2× |
| 顺序 experts.l2 8 线程(QD8) 16GiB | 1952 MB/s | – | – |
| 随机 17.5MB 槽 16 线程 2048 槽(35.9GB) | 3765 MB/s | 589 MB/s | 6.4× |
| 混合: seq1(12GiB)+rnd16(26.9GB) | 1525 MB/s (seq493+rnd1032) | 208 MB/s (seq67+rnd141) | 7.3× |
| 随机 4K 16 线程 262144 次 | 254 MB/s / 65k iops | – | – |

运行参数：VM 28GB RAM，buffered 场景前 drop_caches，S4/S5 溢出 bug 已修复（v2）。

## 对照 app 实测（gateAB 20260926_075554）
- trunk_layers_out：436.45 GB / 9 tokens = **48.5 GB/token** @ 859 MB/s（buffered pread）
- experts.l2：183.65 GB / 9 tokens = **20.4 GB/token** @ ~0.4-0.6 GB/s
- 运行中聚合 ~1.26 GB/s —— 距 O_DIRECT 混合硬上限 1.5 GB/s 仅差 20%！！

## 结论
1. **82 s/token 是磁盘混合带宽墙，不是计算墙**（计算仅 ~61 ms/token）。app 现已几乎顶着该盘的混合 O_DIRECT 上限跑。
2. 该盘（疑似桥接/低端主控，PHY-SEC 4096）混合吞吐硬上限约 **1.5 GB/s**：单独 rnd 16thr 能到 3.8 GB/s，但与 1 条 seq 流并发后总聚合塌到 1.5 GB/s。
3. buffered 大读（17.5MB）页缓存复制/清零开销极重：单 rnd 丢 6.4×、混合丢 7.3×。app 用的正是 buffered，因此实测 ~1.26 GB/s。
4. **理论地板**：68.9 GB/token ÷ 1.5 GB/s ≈ **46 s/token**（全部改 O_DIRECT 后）。**<34 s/token 在此盘上不可行**。

## 可选方向（需用户批准，未实施）
- **A（小改，~1.2×）**：专家/trunk 读改 O_DIRECT + 4096 对齐缓冲，顶近 1.5 GB/s 混合上限。
- **B（大改）**：trunk 占 71% 流量（48.5 GB/token 的 layer 切片固定重复读）→ 层切片驻留内存/预取复用，按 28GB 可用 RAM 估算可砍 ~40-50 GB/token。预期 46s → ~15-20s/token。
- **C（换盘）**：需 ≥2.3 GB/s 混合的 NVMe 才能真正 <34s。spec-amp 只减 token 数，不减每 forward 全量 I/O，救不了带宽墙。