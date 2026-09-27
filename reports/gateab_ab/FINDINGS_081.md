# 081 追因：结论与教训（2026-09-27）

## 结论

**081 的 81.28 s/tok 与 gate、group 1、O_DIRECT、native/kio 全都无关。**

| 假设 | 判决 | 证据 |
|---|---|---|
| gate（park）在起作用 | **否** | 上午四跑：park 0.00s 的 81.28/82.43 与 park 165-168s 的 85.00/82.99 只差 1-3 s/tok |
| L2 读该在 group 1 | **否** | 61cf381 提交于 09:22，四跑都在 07:41-08:33，二进制里没有 group 1；v5/v6 两次强行改 group 1 均**死锁** |
| O_DIRECT 缺失 | **否** | 每形态都开（st dfd / l2 fdh / trunk fd） |
| native vs kio 是主因 | **否** | v1 全 native 102.04 < v4 全 native 124.68，同一档内自相矛盾 |
| 冷盘/热盘 | **否** | v2_cold 121.29，比热态 v2 111.56 更差 |
| prefetch 能救 | **否** | share 回到 129.5% 但 128.69，survival 仅 41.3%，读量 +53% |

**真正未解**：同形态代码在上午 81-85、下午 102-128，30 s/tok 的差距。v7（v4 同源二进制，当前环境）正在复测以确认形态等价性。

## 血溅教训

1. **两次死锁（v5_l2g1 / v6_l2g1rw）**：改 L2 的 kio group 归属 → 41/41 线程 `futex_wait_queue`、I/O 归零、日志停在 104B（`indexed tensors` 之前）。把 refill 写一起钉到 group 1 也照样死。**kio 的 group 隔离必须配 phase2_hold 挂载才有意义**。
2. **每次死锁要立刻杀的判据**：`rchar` 与 `read_bytes` 连续 30s 为 0 且 `cpu_ticks` 增量为 0。
3. **时间线优先于推理**：61cf381 在 09:22 提交，四次 81-85 的 run 全在 09:22 之前 —— 先查提交时间，再谈机制。
4. **死进程会留 schtasks 任务**：`pkill` 后必须复查 `pgrep`（`time` wrapper 会有独立 PID）。
5. **WSL 重启后 `/mnt/nvme`**：`wsl --mount` 成功后 `/dev/sde7` 已自动挂上；若再 `mount --bind /mnt/wsl/PHYSICALDRIVE2p7` 会用 tmpfs 盖住 ext4，且 `mountpoint -q` 误判为"已挂"。正确做法：`umount` 后 `mount /dev/sde7 /mnt/nvme`。
6. **日志大小不是死锁判据**：stdout 重定向到文件是块缓冲，104B 只说明没 flush。v5/v6 真正的判据是 I/O 与 CPU 双零。
