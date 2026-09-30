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

The expert stream dominates the wall, and that is an **engine** fact, not a device fact, which
is the one conclusion here that must survive. `probe_coldc.py` reads the same expert tensor the
engine reads -- 736 random 17.5 MB slots, O_DIRECT, 16 strided preadv threads, page cache
dropped between phases -- and the device serves that exact scattered shape at **3264 MB/s
single-stream, 12.9 GB in 3.96 s**, faster than the sequential trunk at 1509. Scattered slot
reads are the device's fastest access; the engine's own expert stream measures 34-46 MB/s per
stream / 345-460 MB/s aggregate (e3ec059 counters, v56_groupcheck), about **7-9x under its
shape's device rate**. That gap is in the I/O pool (shared-mutex dispatch, 40-49% of worker
time asleep, per-layer getmany bursts that leave the pool idle between layers), not in the
disk. TRUE RAM-resident is 3.80%; device-side L2 keeps reading the disk on every "hit".

## What this leaves

The engine moves 216.7 GB over 243 s = 891 MB/s aggregate; a probe of the same streams in the
same session (1 thread sequential trunk + 16 threads scattered expert, all cold) totals 1257.
The expert portion supplies almost none of that headroom: 460 MB/s against a shape that the
probe runs at 3264. The 008449c claim that "the device does 368 MB/s at concurrency 12 for the
17.5 MB shape, agreeing with the engine" does not survive confrontation with probe_coldc's 3264
for the identical shape, and its 368 rests on the serial-dd evidence that the same commit
declares invalid in v57b. Cross-layer pipelining is therefore **open, not closed**: sustained
expert concurrency across layer boundaries and a cheaper dispatch are the levers, and their
ceiling is whatever the engine can make of a shape the device serves ~7x faster. The "65 -> 57
s/token device-floor" framing from that reading is withdrawn -- it assumed the expert stream
was already at a device limit it is not at.

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
- **"expert reads are latency-bound because they are scattered"**: wrong. probe_coldc's scattered
  slot reads run 3264 MB/s, the shape's best rate; the 34-46 MB/s per-stream numbers describe
  the engine's I/O pool, not the disk. The discount applies to the engine, not the access.
- **008449c "device does 368 MB/s at concurrency 12 for the 17.5 MB shape"**: suspicious on two
  counts -- the 3264 probe_coldc number for the same shape, and its own serial-`dd` evidence base
  (v57b interleaving) which the same commit marks invalid. Re-measure before citing as a limit.

## The standing conclusion

1 T-parameter MoE on CPU cannot reach practical chat (<1-2 s/token): the author's own
decode-by-RAM table bottoms out at 5.59 s/token at 128+ GB (compute-bound). Whether this box
can do better than its current 65-75 is now an open engine question: the expert stream sits
~7x under the rate its read shape serves (3264 vs ~400), and no clean same-shape measurement
has yet bounded the recoverable fraction. The project's value on this hardware is the
measurement discipline and the closed ledger, not a usable product. The notes lineage that
made this possible -- `compressed-trunk.md`, `int8-draft-container.md`, the shelved Huffman
prototype, and `tools/qdq_trunk.py` -- is fully present in this tree.