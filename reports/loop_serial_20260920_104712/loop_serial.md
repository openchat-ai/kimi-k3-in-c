# Block-serial vs standard decode — 2026-09-20

Prompt: 30 synthetic tokens, gen 4, 12 layers, trunk BF8.
Each arm runs warmup-then-measure so both start with a hot expert L2;
slow layer = trunk (read once per token in standard, once per round in
block-serial), fast layer = expert L2 cache.

| config | s/token | trunk binds | trunk reads | trunk GB | L2 hit% | L2 read GB | L2 write GB | out ids |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| standard | 36.22 | 48 | 45 | 28.18 | 100.0 | 16.30 | 0.00 | 8611,82784,51524,3154 |
| loop_block4 | 33.41 | 48 | 45 | 28.18 | 100.0 | 16.25 | 0.00 | 8611,82784,51524,3154 |

Raw data: reports/loop_serial_20260920_104712/loop_serial.tsv
