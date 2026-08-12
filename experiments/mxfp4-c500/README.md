# mxfp4-c500 — C500 张量核融合 MXFP4 matmul 语义模拟

对应设计文档 `docs/notes/mxfp4-c500-kernel.md`。

模拟 64-lane `__builtin_mxc_mma_16x16x16bf16` 的融合去量化 matmul，对真实 checkpoint 字节
（`tests/fixtures/mxfp4.json`）测量三种情形的精度，并与 CPU 双精度融合参考
`k3_matmul_mxfp4`（`tests/unit/test_expert.c` 的 1e-6 权威）比较。

## 构建与运行

```sh
# 依赖：MSVC 或 mingw 的 clang/gcc 均可（-O2，无 AVX 依赖）
clang -O2 -o mma_sim mma_sim.c          # 或 cl /O2 mma_sim.c
./mma_sim ../../tests/fixtures/mxfp4.json
```

输出：
1. dequant vs fixture expected 的 bit-exact 门限（权重侧无损证明）
2. 双精度融合 CPU 内核 vs dequant+matmul（现有 1e-6 门限复现）
3. C500 模拟器（fp32 激活 / bf16 激活）vs 双精度参考的实测 maxrel

## 依赖

- `json.h`：从 `third_party/json.h` 复制的独立 JSON 解析器
- `mma_sim.c`：自包含，仅标准头 + json.h，无仓库其他依赖

## 结论（实测）

见运行输出。要点：1e-6 门限是双精度累加的性质；C500 张量核路径的精度契约是
fp32 累加 ~1e-5、bf16 激活 ~1e-3，与 MXFP4 权重量化噪声同量级，是工程上正确的选择。