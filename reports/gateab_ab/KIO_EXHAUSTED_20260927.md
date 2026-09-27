# 2026-09-27 全天实验结账（20 次 A/B）

## 最重要的一条：stale .o 让 matmul 从 AVX2 退化成 SSE

| 二进制 | ymm | xmm | e8m7 内核指令数 | s/tok |
|---|---|---|---|---|
| 09-26 08:59 旧二进制（快） | 1405 | 5322 | 288 | 78.37 |
| **今天 12:16-19:00 我跑的 8 次** | **323** | 8087 | **1323** | 92-137 |
| 18:32 全量 `make clean` 后 | 1425 | 5491 | 288 | 80.93 |

源码、gcc 15.2.0、`-march=native` 全部相同，Makefile 只加了 pc-run 目标 —— 唯一的解释是**增量构建的 stale .o**（`build/*.o` 在 08:59 pull 时被整体删除，此前已处于不一致状态）。**依赖追踪漏了某个头文件，k3_ops.o 长期没重编。**

代价：v8-v15 共 8 次实验的结论全部作废，我在这上面又叠了 group 1 / hold / fallback / 轮转 / 32 worker 五轮测试。

流程修正：每次 A/B 前 `make clean`，或至少校验 matmul 的 ymm 计数。

## 有效结论（均在干净二进制上）

**最佳配置：trunk 6GB / cache 40GB = 80.93 s/tok**（retained 53.04%，share 157.2%）

| 臂 | pinned | trunk/cache | 专家读 | retained | s/tok |
|---|---|---|---|---|---|
| v16 旧二进制 | 1 (3.0G) | 6 / 13.6 | 183.8G | 17.7% | **78.37** |
| **v18** | 1 (3.0G) | **6 / 40** | **137.0G** | **53.0%** | **80.93** |
| v20 | 10 (14.3G) | 17 / 30 | 151.3G | 41.3% | 81.77 |
| v17 | 17 (23.0G) | 26 / 23 | 168.6G | 29.6% | 88.45 |
| v19 | 1 (3.0G) | 5 / 44 | — | — | ring 降到 1 槽，预读失效 |

1. **轮转 drain 修好了"读打架"**：I/O share 从 82-95% 升到 **148-157%**（081 区间）。原代码只 drain `active_group` 一个组，trunk 流让 group 0 永不为空。
2. **cache 是唯一有效内存杠杆**：arena 13.6→40GB 使 retained 17.7%→53.0%，专家读 −25%。
3. **trunk 常驻是负收益**：1→10 层无差别，17 层差 7.5s —— bind wall 从 10.1s 涨到 30.1s（常驻权重每 token 仍 memcpy 184GB）。
4. **"12 层最佳"是 cache 只有 2GB 时代的结论**（`pin20_103044`，81.28 s/tok）。今天 1 层与 10 层差 0.84s，落在环境漂移内。
5. **ring 下限是 5.6GB，不是代码写的 2.5GB**（`k3_run.c:1078` 的 `slot_min=2.5`）。低于此 planner 静默降到 1 槽，而 `k3_trunk.c` 注释明写 "1 ring slot is NOT enough: reads stop overlapping compute"。这是待修的 bug。
6. **trunk+cache 实用上限 46-47GB**，49GB 会把 56GB 机器榨到 `MemFree=0` 触发换页（v19 那个 351s 的 token）。

## 两次死锁（kio 层，已修）

只 drain `active_group` → hold 不挂载时该组恒为 0 → group 1 无人服务 → 41/41 线程 `futex_wait_queue`、I/O 与 CPU 双零、日志冻结在 104B（`v5_l2g1`、`v6_l2g1rw`，各烧 25 分钟）。把写也钉到 group 1 仍死。修法：`io->rr[]` 轮转游标扫全部组（`k3_io.h` 新增字段），`k3_io_set_active` 保留但不再门控。

## 环境漂移大于所有被测效应

v10 与 v12 配置、字节完全相同（trunk 370.13GB / 专家 168.56GB），仅 pread 964 vs 1089 MB/s → 100.77 vs 92.39 s/tok。**任何小于 15% 的改动在这台机器上不可检出。**

## 距 34 s/tok

trunk 读 54.6GB/token 占净读 82%，cache 已尽力（专家剩 17GB），trunk 常驻被 bind memcpy 抵消。可选路径（按可信度）：
1. `--spec` 投机解码 —— 仓库有 `verify_spec_amp.sh` + `rep_estimate.awk`，输出质量不变
2. 零拷贝 bind —— 消掉 184GB memcpy，让 trunk 常驻转正
3. THP 只生效 40%（`AnonHugePages` 12.7G / RSS 31.4G），`defrag=madvise` + `alloc_sleep=60s` 静默失败
4. ~~`--layers 50`~~ —— 是 "bind only the first N layers" 的截断 hack，`27-30 s/tok` 是估算，不算真实加速
