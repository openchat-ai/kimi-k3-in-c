# Block-serial vs standard decode — 2026-09-20

Prompt: 30 synthetic tokens, gen 4, 12 layers, trunk BF8.
Each arm runs warmup-then-measure so both start with a hot expert L2;
slow layer = trunk (read once per token in standard, once per round in
block-serial), fast layer = expert L2 cache.

| config | s/token | trunk binds | trunk reads | trunk GB | L2 hit% | L2 read GB | L2 write GB | out ids |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| standard | 74.44 | - | - | 28.18 | 76.1 | 11.98 | 4.30 | 8611,82784,51524,3154 |
| loop_block4 | 39.59 | - | - | 28.18 | 100.0 | 16.23 | 0.00 | 8611,82784,51524,3154 |

Raw data: reports/loop_serial_20260920_102621/loop_serial.tsv
