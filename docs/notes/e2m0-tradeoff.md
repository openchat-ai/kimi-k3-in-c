# E2M0 弹性量化：可测收益与决定（2026-08-15）

## 背景

MXFP4 专家权重 = E2M1 半字节（4bit，16 码）+ 每 32 元素一个 E8M0 scale。
已实测：真实 checkpoint 的 scale 字节只用 3 个值 {120,121,122}（熵 0.66/8 bit），
E2M1 nibble 16 码全用（熵 3.75/4 bit）。packed 侧已到信息论极限，唯一剩余压缩
杠杆是第二套更低精度格式。

E2M0 是 OCP MX 2bit 格式：1 符号 + 1 指数，块归一化后幅度 {0,1,2,4}，
复用同一个 E8M0 scale。打包字节减半（0.53125 -> 0.28125 bytes/元素）。

## 可测收益（本机合成/真实字节实测）

| 指标 | E2M1（现状） | E2M0 |
|---|---|---|
| 字节/元素 | 0.53125 | 0.28125（**-47%**） |
| vs bf16 压缩率 | 73.4% | 85.9% |
| 反量化结果相对 L2 扰动 | 基准 | **~26%** |
| 一致性 gate | 通过 | **通过（见下）** |

- `tools/probe_quant_tradeoff.py <shard_dir>` 在真实 shard 上逐张量输出
  E2M0 扰动表、scale 熵、字节节省。合成验证输出 rel_L2≈0.255、节省 47.1%，
  与独立实测吻合。
- **一致性 gate 不挡 E2M0**：`tools/verify_real_layer.py::dequant` 与 C 引擎都从
  存储格式反量化，torch/C 同步切到 E2M0 后仍逐位一致。gate 挡结构错误，
  不挡量化噪声。

## 上游价值

- 带宽受限机器上：expert 读取字节减半，直接换算推理提速。
- 但真实代价是**模型质量**：26% 权重扰动传播过 92 层残差流后
  （模拟 ~48%-121% 相对偏差），PPL 必然劣化。只有真实模型 eval 能量化。

## 决定

1. **不整体切换** E2M0——26% 扰动无法接受。
2. **弹性制度是正确形态**：per-tensor 用 `probe_quant_tradeoff.py` 选出
   扰动低于阈值的张量降级 E2M0，其余保持 E2M1。
3. 决策门槛 = 真实 1.56TB checkpoint 的 PPL/MMLU 对比（本机无该模型，
   属后续会话/持有模型者）。
4. 当前状态：**探测工具已落地，全局开关保持 E2M1**。未来验证路径：
   `probe_quant_tradeoff.py <real_shard_dir> --limit 96` 拿全模型扰动分布
   → 定阈值 → torch/C 同步实现 E2M0 反量化 → PPL 对比 → 决定。

## 实测方法存档

- 真实 scale 分布来源：`tests/fixtures/mxfp4.json`（真实 checkpoint 字节，
  layer1 experts.0.w1）。
- 量化规则：`tools/make_tiny_checkpoint.py::mxfp4_quant`
  （exp = floor(log2 amax) - 2，scale = exp+127，与真实 checkpoint 73% 位级吻合）。
- 探测脚本验证：合成 safetensors（std=0.02 正态）→ rel_L2=0.255、节省 47.1%。
