# Block-serial vs standard decode — 2026-09-20

Prompt: 200 synthetic tokens, gen 2, full trunk (BF8 56.6 GB),
expert L2 cache on fast NVMe. Slow layer = trunk (re-read per token in
standard, once per round in block-serial). Fast layer = expert L2.

| config | s/token | trunk binds | trunk reads | trunk GB | L2 hit% | L2 read GB | L2 write GB | out ids |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| config | s/token | trunk_binds | trunk_reads | trunk_GB | l2_hit_pct | l2_read_GB | l2_write_GB | out_ids |
| standard | 169.90 | 15.26 | 18.5 | 1.91 | 9.37 | 8611,82784 |  |  |
| loop_block4 | 103.30 | 15.26 | 100.0 | 11.27 | 0.00 | 8611,82784 |  |  |

Raw data: reports/loop_serial_20260920_101149/loop_serial.tsv
