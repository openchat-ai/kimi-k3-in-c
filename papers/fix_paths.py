#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Remove repository paths from the body and point them at the attachment instead.

Seven places in the body cite files inside the author's own working tree -- reports/gateab_ab/
..., FINDINGS.md, BENCH_PROTO.md, v64_schedstat/ -- and one reference cites a project file. None
of it travels with a submission: the editor and the reviewer receive a DOCX, a PDF attachment and
nothing else, so every one of those paths is a dead end in print, and together they make the paper
read as an internal engineering log rather than a journal article. Guideline item 17 is what makes
the attachment the right destination -- the author is asked to upload the reproduction material
precisely so that the body can refer to evidence the reader cannot see.

Each citation is rewritten to name the attachment section that carries the same material. The
attachment's own internal paths stay, because the attachment is submitted alongside the paper and
the reader has it in hand; the paper's do not go.
"""
import pathlib, re, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
md = P.read_text(encoding="utf-8")
orig = md

REPL = [
    # ---- 4.6, mechanism measured inside the engine ----
    ("其机制在引擎内直接测得（`reports/gateab_ab/FINDINGS.md`，10 轮、跨两版代码，每词元请求数与字节数逐位一致）",
     "其机制在引擎内直接测得（随稿附件 A.4.2，10 轮、跨两版代码，每词元请求数与字节数逐位一致）"),
    # ---- method caveat, first probe failed ----
    ("> （`reports/gateab_ab/v64_schedstat/`、`v64_probe_attempt1.out`），判定按绝对量重做。",
     "> （随稿附件 A.4.3），判定按绝对量重做。"),
    # ---- upper bound not given ----
    ("该问题在本平台的测量重复性下无法判定（见本节方法学限度段与 `BENCH_PROTO.md` 第 14 节）",
     "该问题在本平台的测量重复性下无法判定（见本节方法学限度段与随稿附件第 3 章）"),
    # ---- ten stable rounds ----
    ("本节亦不据此主张任何参数调优方向。相比之下第二节的推论验证（4.2、4.3）以**字节**而非时间核算，不受此限度影响。上列十轮稳定量见 `reports/gateab_ab/FINDINGS.md`。",
     "本节亦不据此主张任何参数调优方向。相比之下第二节的推论验证（4.2、4.3）以**字节**而非时间核算，不受此限度影响。上列十轮稳定量见随稿附件 A.4.2。"),
    # ---- 5.2.1, engine aggregate vs independent measurement ----
    ("而**同盘、同单元、同 O_DIRECT、同 16 并发的独立测量给出 1100–1800 MB/s**（`reports/gateab_ab/v36_devrate/`、`v37_burst/`）",
     "而**同盘、同单元、同 O_DIRECT、同 16 并发的独立测量给出 1100–1800 MB/s**（随稿附件 A.4.2）"),
    # ---- same, the paired measurement ----
    ("3 对交错配对测得（`reports/gateab_ab/v58_mix/ratios.txt`）：",
     "3 对交错配对测得（随稿附件 A.4.2）："),
    # ---- appendix A pointer, the 1.30-1.58 figure ----
    ("两条之间的差距为 1.30–1.58 倍（三对交错配对，`reports/gateab_ab/v58_mix/ratios.txt`），机制已定位为算术与 I/O 的串行化",
     "两条之间的差距为 1.30–1.58 倍（三对交错配对，随稿附件 A.4.2），机制已定位为算术与 I/O 的串行化"),
    # ---- reference 10 ----
    ("[10] 作者自建真机字节流台账（k3 x86 冷启动，2026-08），项目内文件 papers/byteflow-matrix.md [Author-built machine byte-stream ledger, k3 x86 cold start, 2026-08, project file papers/byteflow-matrix.md].",
     "[10] 作者自建真机字节流台账（k3 x86 冷启动，2026-08），随稿附件 A.1 [Author-built machine byte-stream ledger, k3 x86 cold start, 2026-08, attachment A.1]."),
]

miss = []
for a, b in REPL:
    if a not in md:
        miss.append(a[:56])
        continue
    md = md.replace(a, b, 1)
    print("  ✓ %s…" % a[:52].replace("\n", " "))

P.write_text(md, encoding="utf-8")
print("  替换 %d/%d 处，篇幅变化 %+d 字符" % (len(REPL) - len(miss), len(REPL),
                                       len(md) - len(orig)))
for m in miss:
    print("  ★ 未匹配：%s" % m)

# ---- verify no repository path survives in the body ----
md2 = P.read_text(encoding="utf-8")
lines = md2.splitlines()
END = next((i for i, l in enumerate(lines) if l.startswith("# 英文题名")), len(lines))
body = "\n".join(lines[:END])
PAT = re.compile(r"reports/|papers/byteflow|FINDINGS|BENCH_PROTO|\bv[0-9]+_[a-z]|\.txt\b")
left = []
for i, l in enumerate(lines[:END], 1):
    if PAT.search(l):
        left.append((i, l.strip()[:96]))
if left:
    print()
    print("  ★ 正文仍含仓库路径：")
    for i, s in left:
        print("    行%d  %s" % (i, s))
else:
    print("  ✓ 正文已无仓库路径")
if miss or left:
    sys.exit("★ 失败项 %d，残留 %d" % (len(miss), len(left)))