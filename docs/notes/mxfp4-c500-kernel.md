# 融合 MXFP4 去量化的 C500 张量核 matmul 设计

## 目标

为 C500 张量核（64-lane，`__builtin_mxc_mma_16x16x16bf16`）设计一个"融合 MXFP4 去量化 + 矩阵乘"
内核：不再是 `k3_mxfp4_dequant` 先物化出 fp32 权重矩阵、再 `k3_matmul`，而是把去量化直接
放进张量核的 fragment 加载阶段，让 MXFP4 的 packed 权重与 scale 字节直接进入 MMA。

本设计的语义正确性由独立实验 `experiments/mxfp4-c500/mma_sim.c` 验证（见下文"精度契约"），
验证基准是真实 checkpoint 字节 `tests/fixtures/mxfp4.json`。

> 假设声明：仓库内没有任何 C500/MMA 代码。f16/bf16 builtin 的 fragment 布局规格来自外部
> 子代理报告，未在本仓库内以硬件实测确认。本文档与模拟器依赖该布局假设；若目标硬件布局不同，
> 变的是"值落在哪个 lane"，算术（每个 lane 的 4 个部分乘积 + 跨 lane 归约）不变，结论仍成立。

## 背景：MXFP4 格式

OCP MX E2M1，group_size = 32（每 32 个逻辑元素一个共享 scale 字节）：

- 权重字节 `packed[r][i>>1]`，低 nibble = 偶数元素、高 nibble = 奇数元素（`k3_ops.c:1356`）。
  解出的 nibble 查 `K3_E2M1[16]` 表（`k3_ops.c:1027`，bit3 = 符号）。
- 每 32 个元素一个 E8M0 scale 字节：`mult = (sb==255) ? 0 : ldexpf(1.0f, sb-127)`（`k3_ops.c:1346`）。
- 元素值 = `K3_E2M1[nibble] * mult`。

本设计的关键性质（下文"权重侧无损"证明）：E2M1 值域 {0, ±0.5, ±1, ±1.5, ±2, ±3, ±4, ±6} 中的
每个值都只需 ≤1 个存储尾数位即可表示（1.5 = 1.1×2^0，3 = 1.1×2^1，6 = 1.1×2^2，其余为 1.0× 或 0），
而 bf16 有 7 个存储尾数位。乘以 2 的幂（scale）只是移指数。**因此每个 MXFP4 权重值在 bf16 中精确可表示，
去量化到 bf16 不损失任何信息。**

## 目标 MMA 与 fragment 布局

`__builtin_mxc_mma_16x16x16bf16(B, A, C)` 计算 `C[16][16] += A[16][16] · B[16][16]`，
A、B 为 bf16，C 为 fp32。64 个 lane 各持 4 个值：

| fragment | 维度 | lane L 持有的值 | 语义 |
|---|---|---|---|
| A | m×k | `A[L%16][4*(L/16)+r]`, r=0..3 | 激活，m=token, k=in |
| B | k×n | `B[4*(L/16)+r][L%16]`, r=0..3 | 权重（转置），n=out, k=in |
| C | m×n | `C[L%16][4*(L/16)+r]`, r=0..3 | 输出累加 |

每个 lane 对 4 个 k 做部分乘积，4 个 lane group（lg=0..3）通过累加器网络归约为完整输出。
`C[m][n] += Σ_{k=0..15} A[m][k]·B[k][n]`，乘积在 fp32 中累加。

## 融合去量化如何进入 B fragment

目标运算：`y[out] = Σ_in W[out][in] · x[in]`。把权重放 B 侧（n=out, k=in），激活放 A 侧（m=token, k=in）。

一个 16×16 的 B tile 覆盖 k=0..15（16 个 in-feature）与 n=0..15（16 个 out）。MXFP4 group=32 沿 `in`
方向，所以一个 16 宽的 k-tile 恰好落在单个 32 元素 group 的**一半**内：

- 若 `ktile` 为偶数，tile 是 group `g=ktile/2` 的低半（k 全局 ≤ 16g+15）；
- 若 `ktile` 为奇数，tile 是 group `g=(ktile-1)/2` 的高半。

两种情况都**只有一个 scale 字节**管辖整个 16 宽 tile（对给定的 out 行）。因此 B fragment 的
融合去量化是：每个 lane 读 `scale[sb] = scales[n=L%16][g]`，再对 r=0..3 依次解出
`k = ktile*16 + 4*(L/16) + r` 全局下标对应的 nibble，`bf16(K3_E2M1[nib] * mult)` 写入 B fragment。

没有物化的 fp32 权重矩阵：packed 字节 + scale 字节直接进 fragment，带宽减半。

## 循环结构

外层沿 `ktile`（in/16 = 224 个）与 `ntile`（out/16 = 4 个）分块，内层一次 MMA：

```
for each ntile (out block of 16):
    C[16][16] = 0                       # fp32 fragment 清零
    for each ktile (in block of 16):
        A = x[token][ktile*16 .. +16]   # 激活，bf16（见精度契约）
        B = fused_dequant(W, ntile, ktile)   # MXFP4 → bf16，见上
        mma(B, A, C)                    # C += A·B
    copy C → y[ntile*16 .. +16]
```

C fragment 在 ktile 循环内携带累加（每个 MMA 的 16 项乘积累加进同一组 fp32 C 值），
跨 ktile 持续累加，即对 in 维做 fp32 顺序累加。这与参考 `k3_matmul_mxfp4` 的"每 32 元素 group
先归约再乘 scale、group 间累加至单一 double acc"不同——见精度契约。

## 精度契约

模拟器 `mma_sim.c` 对真实字节测量三种情形，全部与 CPU 融合参考 `k3_matmul_mxfp4`（double 累加，
`tests/unit/test_expert.c` 的 1e-6 权威）比较：

| 情形 | 激活 | 累加 | 与 double 参考的 maxrel | 结论 |
|---|---|---|---|---|
| CPU 参考（基准） | fp32 | double | 0.000e+00（实测，bit 级一致） | 现有 1e-6 门限的成立前提 |
| C500 + fp32 激活（隔离） | fp32 | fp32 | 1.159e-06（实测） | 布局/顺序/去量化正确，仅 fp32 累加误差 |
| C500 真实（bf16 激活） | bf16 | fp32 | 1.818e-03（实测） | bf16 激活舍入主导 |

**权重侧无损**（证明见上）：E2M1×2^(sb-127) 在 bf16 中精确，融合去量化不引入权重误差；
`t_mxfp4` 对 dequant 的 bit-exact 门限（`test_ops.c:778`）在设计上仍然成立。

**结论（实测确认）**：现有 1e-6 门限是 **double 累加**的性质，不是张量核的性质。
fp32 累加的 C500 路径在 3584 项点积中实测 maxrel=1.159e-06（略超 1e-6 门限）；
bf16 激活舍入（fp32→bf16 实测 maxrel=1.818e-03）决定真实路径精度。因此：

- 若专家权重本来就是 MXFP4 量化的（精度预算 ~1e-3 量级），bf16 激活 + fp32 累加的 ~1e-3 误差
  与权重量化噪声同量级，**可接受**——这是工程上正确的选择。
- 若要求 C500 路径与 fp32 双精度参考对齐到 1e-6，则**不可行**，除非激活保持 fp32（需 f32 MMA
  变体，或分两次 bf16 分离高低位）且累加用 fp64/更高精度。不要用 1e-6 门限框住张量核。

## 风险 / 待实证

- bf16 fragment 布局为外部假设，未硬件实测；若与真实 C500 不符，需改 lane 映射，算术不变。
- fp32 累加顺序（MML 内 k=0..15 顺序 + ktile 顺序）为模拟假设；硬件点积单元的求和树顺序未知，
  但只影响 fp32 累加误差的 ~1e-6 内部差异，不影响 ~1e-3 的主导项。
- 单 token（batch=1）时 64 lane 中仅 m=0 的 16 个 lane 被使用，其余浪费；批量 ≥16 token 才满利用率。
  模拟器以单 token 复现 test_expert 语义，layout 语义不变。