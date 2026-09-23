# Block-serial vs standard decode — 2026-09-20

Prompt: 30 synthetic tokens, gen 4, 12 layers, trunk BF8.
Each arm runs warmup-then-measure so both start with a hot expert L2;
slow layer = trunk (read once per token in standard, once per round in
block-serial), fast layer = expert L2 cache.

| config | s/token | trunk binds | trunk reads | trunk GB | L2 hit% | L2 read GB | L2 write GB | out ids |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| standard | 45.69 | 24 | 23 | 15.26 | 78.9 | 10.62 | 3.39 | 8611,82784,82784,82784 |
| loop_block4 | 32.38 | 24 | 23 | 15.26 | 100.0 | 13.99 | 0.00 | 8611,82784,82784,82784 |

Raw data: reports/loop_serial_20260920_113634/loop_serial.tsv
