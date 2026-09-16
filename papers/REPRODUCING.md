# Reproducing the paper: 《命中率指标掩盖的慢介质全量重读》

This repository is the single source from which the CJAS submission
(`papers/paper-submit-cjas.md`) and its English cut
(`papers/paper-cuteng-slow-medium-read-once.md`) can be reproduced. Every figure in the
papers maps to a committed script, a committed binary fixture, or a public 1.56 TB
checkpoint fetchable by `scripts/download-model.sh`.

The papers describe an empirical finding on MoE inference: an L2 cache hit-rate
percentage can say "everything is fine" while the *slow-storage full re-read* actually
drives the wall clock. Below is the exact chain from this repo to every claimed number.

## What you need

There are three tiers of reproduction. Only tier 3 needs the full checkpoint.

| tier | needs | covers |
|------|-------|--------|
| 0 | this repo, Python 3.9+ | every byte-flow structure claim (trace-level) |
| 1 | tier 0 + a C compiler | the engine's own weightless conformance (GATE 1-3) |
| 2 | tier 0-1 + the 1.56 TB checkpoint | the end-to-end I/O measurements the papers plot |

```bash
git clone <this repo>
cd kimi-k3-in-c
make -j && make test     # tier 1: engine matches its reference on tiny fixtures
```

## Tier 0: the trace that anchors every byte-flow claim

The papers rest on one real-machine capture: the routed-expert request stream of a full
93-layer Kimi K3 run, committed verbatim as `tests/fixtures/expert_trace.bin`
(100,096 records = 68 real tokens x 1472 requests/token). It is the same file the
measurement ledger `papers/byteflow-matrix.md` cites, byte-for-byte (md5
`5d5ef9f37fabfb2b3976f452061904f3`).

Replay it — pure Python, no model, no network:

```bash
# structure: 8 passes x 92 layers, pass v loads 80+16v experts/layer (80..192)
python3 tools/paper/struct_check.py

# cross-token L2 reuse: token >= 5 is stable 90%+ — this is the paper's ceiling claim
python3 tools/paper/l2_hit_upper.py        # default: tests/fixtures/expert_trace.bin

# the Tier-3 history table: can top-K of recent history predict the run's hot set?
python3 tools/paper/predict_hotset.py      # gamma=0.8, K=30 -> ~34% warm coverage

# the capacity table reprinted in the README, from the same trace
python3 tools/sim_cache.py tests/fixtures/expert_trace.bin
```

Each script takes an optional trace path as its first argument if you want to replay your
own capture (e.g. from `--dump-cache-trace`). The three numbers these print — the 8x92
layer-pass structure, the 90%+ cross-token ceiling, and the ~34% history-table coverage —
are exactly the three numbers the paper's §3-§5 argument depends on. They are reproduced
here without touching the engine.

## Tier 1: the engine's numerical claims

`make test` runs the engine against its committed reference on a 13-layer model with the
same tensor graph as the released checkpoint. It proves the kernels, the streaming
expert cache, the safetensors reader, the config reader and the tokenizer without any
multi-terabyte download:

```
GATE 1  teacher forcing : 32/32 positions match tf_pred
GATE 2  greedy decode   : 20/20 generated tokens match full_ids
GATE 3  incremental     : 20/20 generated tokens match full_ids
VERDICT: ENGINE MATCHES THE REFERENCE EXACTLY
ALL WEIGHTLESS TESTS PASSED
```

The torch-verified fixtures live in `tests/fixtures/`. These same engines were the ones
measured on the real machine in the ledger.

## Tier 2: the end-to-end measurements (1.56 TB)

The papers' I/O numbers (expert re-read bytes, trunk read bandwidth, seconds/token) come
from the full checkpoint. Follow the README's steps 4-6:

```bash
export HF_TOKEN=hf_...                 # read from env, never echoed
./scripts/download-model.sh ~/k3model # 96 shards, byte-exact verification
./scripts/pack-trunk.sh ~/k3model ~/k3trunk
```

Then reproduce the exact runs the ledger's E-xx units define. The ledger records for
each experimental unit the *command*, the *machine state* (disk, memory, cache state),
and the *measured file* — see `papers/byteflow-matrix.md` section "3. 全链路测量方法"
and the E-xx entries. The engine reports per-run byte/seconds at the end of each run
(the `trunk [final]` / cache lines in the run report); copy those into the ledger's
table to re-derive the paper's figures.

Machine note: the one paper was measured on used a fast NVMe for the trunk (1.9 GB/s,
`O_DIRECT`), a slower disk for `/model`, and dropped caches between cold runs. Full
environment in `docs/data/environment.txt`. Numbers are proportional to these disks, so
state the environment alongside any reproduction.

## Repository map

| path | what it is |
|------|------------|
| `papers/paper-submit-cjas.md` | CJAS submission, Chinese, master version |
| `papers/paper-submit-cjas.pdf` | compiled PDF of the master |
| `papers/paper-cuteng-slow-medium-read-once.md` | English translation |
| `papers/paper-cuteng.tex` / `.pdf` | LaTeX source of the English paper |
| `papers/byteflow-matrix.md` | the measurement ledger, the single source of truth for every number |
| `papers/overlap-ch{1,2,3,4,5,6}-*.md` | the paper's section drafts |
| `papers/cover-letter-cjas.md` | submission cover letter |
| `tools/paper/*.py` | the three trace-replay scripts (tier 0) |
| `tools/sim_cache.py` | LRU/PPR capacity simulation over the same trace |
| `tests/fixtures/expert_trace.bin` | the committed 100,096-record capture |
| `docs/data/*` | environment, replication table, measurement outputs |

## Validation status

- Tier 0 scripts are exercised in-repo (see above) and their outputs match the ledger.
- `make test` is green on the current `main` (all GATEs + weightless).
- The 1.56 TB figures come from the machine described in `docs/data/environment.txt`;
  they have not been re-measured on other hardware.