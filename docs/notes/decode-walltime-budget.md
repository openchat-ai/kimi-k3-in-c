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

The expert stream dominates because it is synchronous on the critical path and
latency-bound (34-46 MB/s per stream, 9.1x concurrency over 16 workers). Device-side L2 is a
cache the disk still reads on every "hit"; TRUE RAM-resident is 3.80%.

## What this leaves

The engine moves 216.7 GB over 243 s = 891 MB/s aggregate; the I/O pool's engine shape
measures 1107 MB/s, **88% of the concurrent-shape device ceiling (1257)**. The author's 008449c
verdict on cross-layer expert pipelining is arithmetically right: its ceiling is the device, so
the largest code-evolvable gain is the 65 -> ~57 s/token floor, about 12%, judged not worth
building for a shape whose practical aim (chat-class latency) stays unreachable.

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

## The standing conclusion

1 T-parameter MoE on CPU cannot reach practical chat (<1-2 s/token): the author's own
decode-by-RAM table bottoms out at 5.59 s/token at 128+ GB (compute-bound), and this box's
ceiling is ~57 s/token, with the current best 65-75. The project's value on this hardware is
the measurement discipline and the closed ledger, not a usable product. The notes lineage that
made this possible — `compressed-trunk.md`, `int8-draft-container.md`, the shelved Huffman
prototype, and `tools/qdq_trunk.py` — is fully present in this tree.