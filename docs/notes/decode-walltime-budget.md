# Full-model decode wall time: closed to ~2% without weights

The question put to these records: of the measured **65.21 s/token** (ab56, best config, 3
tokens), where exactly does each second live? This note holds the answer. It was closed from
the v56_counters / ab56_run.log traces and the I/O-pool instrumentation added in
`e3ec059`, on a box with **56 GB RAM** and a **single consumer NVMe** (sdd7, 4M O_DIRECT
about 1600 MB/s; concurrent-shape aggregate 1257). The engine runs a 1.05 T parameter, 93-layer
MoE with a 3.11 GB bf16 trunk per layer and a 1.45 TB nominal expert tensor.

## The budget, per token

| source | seconds | share | where it sits |
|---|---|---|---|
| expert sync reads | 44.6 | 68% | main-thread critical path, inside `k3_decoder_layer_inc` (omp 16 -> kio pool) |
| arithmetic (chip pool wall) | 7.3 | 11% | measured pool wall, not the simulated chip bill |
| bind wall | 5.9 | 9% | trunk bind + kernel launches, main thread |
| trunk read, un-hidden | 5.5 | 8% | 140.0 s read total, 123.7 s (87%) overlapped behind arithmetic on the reader thread |
| widen | 0.5 | <1% | WIDEN re-emission |
| phase 1 reserve | 0.1 | <1% | serial reserve + lock; the old suspect, refuted |
| residue | ~1.4 | ~2% | bookkeeping |
| **sum** | **~65.2** | | matches 195.6 s / 3 toks |

The expert stream dominates the wall, and the size of the gap depends entirely on which
window is compared. Three measurements exist, and the honest ledger keeps all three rather
than picking the flattering one:

| compared against | device | engine | ratio | window |
|---|---|---|---|---|
| expert stream alone, sustained | 2463-2797 MB/s | 439 MB/s | 5.6-6.4x | 210 s |
| trunk + expert concurrent, cold | 1257 MB/s | 891 MB/s | 1.4x | 55 s |
| expert stream alone, burst | 3264 MB/s | -- | not comparable | 4 s |

`steady47.c` (run as `v49_paired/dev1-3`) is the sustained measurement and the one built for
exactly this question: `O_DIRECT`, 11 threads, back-to-back `pread` of the same 17.55 MB slots
from the same `experts.l2`, continuous for 210 s with no pauses and no burst structure. Its
20-second segments stay between 1235 and 3762 MB/s for the whole run and the totals are 2797 /
2607 / 2463 MB/s -- multi-GB/s throughout, which by the probe's own stated decision rule means
the gap against the engine's 439 MB/s is real and is not a burst artefact. Its header also
retires `probe_coldc`'s 3264 MB/s: those were 4-second cache-warm bursts, and quoting them
against a 400-second steady-state number compares a 4 s figure with a 400 s one.

The 6x figure is still not the operative one. The engine does not run the expert stream alone:
it runs trunk (781-1003 MB/s) and experts (345-460 MB/s) on the same device at the same time,
and the 55 s cold concurrent probe bounds that mixed workload at 1257 MB/s aggregate. Against
the workload the engine actually has, the aggregate headroom is 891 -> 1257, about 1.4x. That
1.4x is a statement about bytes per second, not about wall time: what cross-layer pipelining
could actually recover is bounded by the arithmetic below, and it is about a fifth, not a
multiple. 008449c closed the question on the premise that "the device does 368 MB/s at
concurrency 12 for the 17.5 MB shape"; `steady47` refutes that premise directly (same file,
same shape, similar concurrency, sustained, 2.5-2.8 GB/s), so the closure does not stand and
the question returns to the measurement below.

## Cross-layer pipelining: the bound, and the number that decides it

The repo holds two answers and they contradict each other. `e3ec059` concluded that "the
remaining lever is changing the alternation -- cross-layer software pipelining, which this
engine does not do", because arithmetic and I/O alternate strictly and the device idles
through the arithmetic. `008449c` concluded the opposite, that the ceiling is the device and
building it is not justified. The first is an observation about the engine, the second is a
claim about the disk, and the claim is the one `steady47` refuted. So the question is open,
and it is decidable by arithmetic plus one measurement.

**The bound.** Only the arithmetic and the bind can be hidden behind the next layer's reads:
7.3 + 5.9 = **13.2 s/token**, 20% of 65.2. The expert reads (44.6 s/token) are on the critical
path themselves; pipelining overlaps them with compute, it does not remove them. So the
ceiling on this lever is **~52 s/token, about 20%**, and no arrangement of scheduling does
better than that on this workload.

**The acceptance line.** Each token moves 72.22 GB (216.66 GB over 3 tokens). Today that takes
65.21 s, which is the 1107 MB/s aggregate the engine reports. To land at 52.0 s/token the
device must sustain **72.22 / 52.0 = 1389 MB/s** on the mixed trunk+expert shape, unpaced, for
a window as long as an engine run. That single number decides the question:

| steady58 mixed sustained aggregate | verdict |
|---|---|
| >= 1389 MB/s | the full overlap is physically available; build demand-overlap pipelining |
| 900-1389 MB/s | partial; the gain is 1 - 1107/x, and it shrinks as x falls |
| ~891 MB/s (the engine's own figure) | the engine is already at the mixed ceiling; do not build, the disk is the wall |

**What is already ruled out.** The mechanism that exists -- `--prefetch-depth`, which hints the
*previous* token's routing ahead of the demand reads -- was measured, and it loses: v50 pf0
66.61 / 82.25 / 76.21 (mean 75.0) against pf1 88.70 / 89.12 / 88.88 (mean 88.9), about 18%
worse, and the pf1 spread is a fraction of the pf0 spread. v54 showed why the guess does not
pay: only 21% of the prefetched experts are still resident when the forward thread arrives, and
a bigger arena does not fix it (21.4% -> 21.7%), so the evictions were never a capacity
problem. The wasted reads compete with the demand reads for the same device. Whatever gets
built has to move the *demand* reads earlier rather than guess extra ones.

**The measurement.** `steady58.c` with `ab58.sh`, run as v58: the same O_DIRECT scattered-slot
lanes steady47 used plus a trunk lane reading whole layers in order, both continuous and
unpaced for 210 s, alternating against the engine three times at matched thermal state. It
reports each arm separately so the expert figure stays comparable with steady47's, and
ab58.sh refuses to run it if its self-test fails. The trunk arm is the part v49 lacked: v49's
device arm had the drive to itself while the engine arm it was compared against streamed the
trunk at the same time, which is why its 6.2x was not an engine-versus-device gap.

Reading caveat for the record: `steady47.c:165` computes its "running MB/s" column as the last
segment's bytes over cumulative time, so that column decays even while the real trajectory
holds. The `seg MB/s` column and the whole-run totals are the valid figures.

## Corrections kept on record

Claims that died on re-measurement, in order:

- **"scattered 12411-13402 MB/s"** (probe57): invalid. It summed per-invocation `dd` rates instead
  of per-file actuals; the device is ~1600 MB/s in real access shapes (1 stream 1331, 4 streams 1626).
- **2463 MB/s** mapper figure: bound for the mapped-access shape, not the 4M O_DIRECT read shape the
  engine actually uses.
- **34 s/token**: an earlier branch state, superseded by the 65-75 range at 56 GB.
- **11.81 s/token** (spec_pin3): a 12/93-layer partial stack, not the full model.
- The 6.6x "engine vs device" gap chain was 2.77x, then 1.14-1.8x as the access shapes were
  matched to what the engine really does.
- **"expert reads are latency-bound because they are scattered"**: wrong. `steady47` holds
  2463-2797 MB/s on scattered 17.55 MB slots for 210 s straight; the 34-46 MB/s per-stream
  numbers describe the engine's I/O pool, not the disk. The discount applies to the engine,
  not the access pattern.
- **008449c "device does 368 MB/s at concurrency 12 for the 17.5 MB shape"**: refuted by
  `steady47` -- same file, same shape, similar concurrency, sustained 210 s, 2463-2797 MB/s.
  Its 368 also rests on serial-`dd` evidence that the same commit marks invalid in v57b.
- **`probe_coldc`'s 3264 MB/s**: a 4-second cache-warm burst, per `steady47.c`'s own header.
  Fine as a burst number, useless as a ceiling for a 400-second steady-state workload.
- **"the engine's expert stream is at the device's sustained limit"**: also false, and the
  mistake runs the other way. The device sustains 2.5-2.8 GB/s on that shape; the engine's
  439-464 MB/s sits at roughly a third of the concurrent-mix ceiling it is really running
  under. Both the "6x under the ceiling" and the "at the ceiling" readings are wrong: the
  engine is neither, and the recoverable band is 891 -> 1257 MB/s aggregate.

## The standing conclusion

1 T-parameter MoE on CPU cannot reach practical chat (<1-2 s/token): the author's own
decode-by-RAM table bottoms out at 5.59 s/token at 128+ GB (compute-bound). The current
65-75 s/token is not a floor, but the arithmetic headroom is far smaller than it first
looked, because the expert arithmetic cannot be hidden the way a naive "cross-layer
pipelining" story assumes (see the overlap section below): the dependency chain
attention -> router -> experts is strict, `getmany` is fully synchronous, and the 16 reads
of a layer all land at the end of their burst, leaving the 7.34 s/token of expert matmul
with nothing to overlap. The only lever is the device delivering more bytes/s, and even
that is capped by trunk/expert contention (v50, v54). One measurement decides the
per-expert pipeline (`K3_SPREAD_DBG` -> `spread_parse.py`); a second decides the mixed
ceiling (`steady58` / v58). The project's value on this hardware is the measurement
discipline and the closed ledger, not a usable product. The notes lineage that made this
possible -- `compressed-trunk.md`, `int8-draft-container.md`, the shelved Huffman
prototype, and `tools/qdq_trunk.py` -- is fully present in this tree.

## Expert read/compute overlap: the spread verdict

The tempting idea is to submit each expert's matmul to the compute pool the moment its
17.55 MB read lands, instead of after the whole top-16 burst. Two facts, both from the
code, kill the easy version of it:

- Within a layer the chain is strict: `k3_decoder_layer_inc` runs attention, then
  `k3_moe` runs the router (which needs the attention output), then the expert reads.
  There is no intra-layer work to reorder ahead of the wait.
- `cache_getmany_inner` is fully synchronous. Phase 2 runs an `omp parallel for` over
  the batch, the main thread blocks for the whole burst, and the routed matmuls run
  after it. The compute has no window inside the burst.

Whether the per-expert pipeline is worth building reduces to ONE physical question: do
the 16 reads of a layer complete *staggered* or *together*? `reports/gateab_ab/overlap_sim.py`
models both structures against the measured split (7.34 s/tok expert arithmetic, 44.6 s/tok
expert reads, 16 experts x 17.55 MB, 92 MoE layers, pool = `CHIP_NWORKERS`, default 4):

| within-burst spread `frac` | predicted gain (pool 4) |
|---|---|
| 0 (all reads land together) | **0%** |
| 0.1 | ~1-2% |
| 0.3 | ~3-5% |
| >= 0.5 | ~5.6-8.4% (pool-limited ceiling) |

The gain is capped by the pool: 16 chains on 4 workers is 4 waves, so even with perfect
staggering only part of the arithmetic overlaps. The gain is also small at the low end
because the device is a shared-bandwidth bottleneck during the burst.

`K3_SPREAD_DBG=1` prints, per burst, `frac = (last_completion - first_completion)/burst`
in `cache_getmany_inner` phase 2. `reports/gateab_ab/spread_parse.py` reads that log and
turns it into the call:

    K3_SPREAD_DBG=1 <engine run> 2> run.log
    python3 reports/gateab_ab/spread_parse.py run.log

- `frac ~ 0` (reads together) -> the per-expert pipeline is worthless. Do not build the
  chip-path streaming refactor. The independent-only "safe" variant (move down+shared,
  which do not depend on expert bytes) is worth ~2.9% on paper but needs its own window,
  so it is also gated on the same measurement.
- `frac >= 0.3` -> a few percent, pool-limited. Only then is the chip-path per-expert
  streaming refactor (incremental job submission as reads land) worth its concurrency risk,
  and it must still be validated bit-exact with the fixture oracle (`make test`).

The simulation killed the earlier "hide 13.2 s/token, ~52 s/token, 1389 MB/s" estimate.
That number assumed arithmetic and bind could hide under a demand-overlap window that the
dependency chain never opens. The real, measured lever is device bandwidth; the pipeline is
at best a few percent and only if the reads land staggered.