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
the workload the engine actually has, the headroom is 891 -> 1257, about **1.4x**, not 6x.
008449c closed cross-layer pipelining on the premise that "the device does 368 MB/s at
concurrency 12 for the 17.5 MB shape"; `steady47` refutes that premise directly (same file,
same shape, similar concurrency, sustained, 2.5-2.8 GB/s). Cross-layer pipelining is
therefore open with a bounded size: most of the 1.4x is reachable only if sustained expert
concurrency can rise across layer boundaries, since today the pool sleeps 40-49% of worker-time
and each layer's getmany leaves it idle in between.

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
decode-by-RAM table bottoms out at 5.59 s/token at 128+ GB (compute-bound). But the current
65-75 s/token is not a floor. Against the mixed trunk+expert workload the engine actually
runs, the device delivers 1257 MB/s aggregate and the engine extracts 891, so the honest
headroom is about 1.4x -- and closing it means sustained cross-layer expert concurrency plus
cheaper dispatch, since the pool sleeps 40-49% of worker-time and every layer boundary leaves
it idle. The project's value on this hardware is the measurement discipline and the closed
ledger, not a usable product. The notes lineage that made this possible --
`compressed-trunk.md`, `int8-draft-container.md`, the shelved Huffman prototype, and
`tools/qdq_trunk.py` -- is fully present in this tree.