# Kimi Delta Attention on Apple Metal

A register-resident Metal kernel for KDA, the gated delta-rule linear attention that Kimi K3 is built around. Measured 1.9 to 2.9x over the straightforward GPU implementation, bit-exact across runs, parity-gated against the CPU engine. This is one piece of a full Metal backend for [kimi-k3-in-c](https://github.com/FareedKhan-dev/kimi-k3-in-c): on this branch the entire 93-layer model runs on the GPU and produces token-identical greedy output to the CPU reference on the test checkpoint.

A standalone version of just the KDA work, with its own harness, lives at [kda-metal](https://github.com/Exorust/kda-metal).

## What KDA is

69 of Kimi K3's 93 layers replace softmax attention with a linear-attention recurrence. Each head carries a 128x128 state matrix `S`, updated per token by a channel-wise gated delta rule:

```
S[i][:] *= alpha[i]          1. per-channel forget gate (decay)
u = S^T k                    2. read: what the state predicts for this key
S += k (beta (v - u))^T      3. write the prediction ERROR, rank one
o = S^T q                    4. output from the ALREADY-UPDATED state
```

Step 3 is what makes it a delta rule: the state absorbs only what it got wrong. The order is load-bearing. `u` must see the decayed state and `o` must see the updated one. No KV cache, so memory per layer stays flat at any context length. That recurrence is this kernel.

## The two kernels

v1 (`k_kda_step`) is the honest first implementation: one thread per state column, row-major state, scalar loads. Correct and deterministic, but issue-bound. Per thread it executes about 256 scalar state loads plus 128 stores, plus 768 redundant broadcast loads, since every one of 128 threads re-reads all of `k`, `alpha`, and `q`. It also touches the state three times per token: a read for `u`, then a read and a write for the update.

v2 (`k_kda_step2`) keeps the math and changes where the data lives. Prior art for the shape is mtplx's gated-delta-net kernel, which matches what this port's DESIGN.md specified independently:

- State transposed to dv-major `[head][j][i]`, dk contiguous, so one simdgroup owns column `j` and lane `L` holds `S[j][4L..4L+3]` as a `float4` in registers. At dk=128 the whole column lives across 32 lanes.
- `k`, `alpha`, and `q` are loaded once per simdgroup as `float4` and reused across its columns. The 768 broadcast reads become 3 vector loads.
- The decayed column is computed in registers, so the state is touched once for read and once for write, 2x traffic instead of 3x.
- `u` and `o` are `simd_sum` reductions, fixed shuffle trees, so the kernel stays deterministic. Columns are independent, so there are no barriers anywhere.
- fp32 accumulation, fast math off, no atomics. The port's numerical contract, unchanged.

Per lane, v1's roughly 1,150 memory instructions become about 19 vector operations.

## Measured (Apple M5, GPU timestamps, 2000 chained dispatches/cb)

| shape (one KDA layer)      | v1 / step | v2 / step | speedup | determinism |
|----------------------------|-----------|-----------|---------|-------------|
| real: H=96, D=128 (6 MB)   | 86.30 us  | 46.06 us  | 1.87x   | bit-exact |
| half: H=48, D=128          | 45.50 us  | 22.55 us  | 2.02x   | bit-exact |
| tiny: H=2, D=16            | 3.81 us   | 1.30 us   | 2.92x   | bit-exact |

At full-model scale that is about 40 us saved per layer across 69 KDA layers, roughly 2.8 ms of GPU time per token returned to the budget.

Two caveats worth stating plainly. The effective-bandwidth column the bench prints (218 to 273 GB/s at real dims) reflects largely cache-resident state, since 6 MB per layer fits on-chip; the trustworthy number is the ratio, which both kernels contest on equal terms. And the benchmark isolates kernel GPU time. The engine currently runs in a correctness-first mode with per-op dispatch and host copies, so the end-to-end win lands together with the encode-batching milestones (PLAN.md M3/M5), at which point the state also becomes permanently device-resident and the transpose at the copy boundary disappears.

## Verification

- `make metal-test`: 49 CPU-vs-GPU parity cases, all routed through v2, including chained recurrence steps with state compared, the full KDA layer with carried conv and recurrent state, and two chained decoder layers. Worst observed error is about 1e-6 against a 2^-10 gate.
- `make bench-kda`: the table above, plus a run-to-run bitwise determinism check on v2 (same init, same steps, `memcmp` over the full state).
- `make test`: the upstream CPU suite, untouched and green.
- End to end: `bin/k3 <ckpt> --ids ... --backend metal` produces token-for-token identical greedy output to `--backend cpu` on the tiny oracle checkpoint, and the first token matches the PyTorch reference.

## Reproduce

```
brew install libomp
make metal-test     # parity gates
make bench-kda      # the comparison table
```

Kernel: `src/metal/k3_kernels.metal` (`k_kda_step` and `k_kda_step2`).
Host + benchmark: `src/metal/k3_metal.m` (`k3m_kda_bench`).
