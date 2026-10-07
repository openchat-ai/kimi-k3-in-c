#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Figure 4: the two-step reading of table 4, as a chart rather than a paragraph.

Table 4 has four rows and one column that matters -- measured / bound -- reading 1.00, 3.11,
1.60, 1.06. Section 4.6 spends two paragraphs explaining that 1.00 means the formula is the law,
that anything above 1 must first be re-priced per stream, and that what remains above 1 is
serialisation rather than bytes. A bar chart with the decision band drawn on it carries that
without the paragraphs.

Left panel: the raw ratios. Right panel: the same two rows after per-stream re-pricing, so the
reader sees 3.11 collapse to 1.06 once trunk and expert use their own bandwidths.

Greyscale only, since the journal prints in black and white. The four ratios are parsed out of
the paper's own table 4 rather than retyped, so the figure cannot drift from the text.
"""
import re, pathlib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from PIL import Image

CJK = []
for f in ("/mnt/c/Windows/Fonts/msyh.ttc", "/mnt/c/Windows/Fonts/simhei.ttf"):
    if pathlib.Path(f).exists():
        try:
            font_manager.fontManager.addfont(f)
            CJK.append(font_manager.FontProperties(fname=f).get_name())
        except Exception:
            pass
if not CJK:
    raise SystemExit("no CJK font available")
plt.rcParams["font.family"] = CJK + ["DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
blk = re.search(r"### 4\.6.*?\n(\|.*?)\n\n", md, re.S)
if not blk:
    raise SystemExit("table 4 not found in the paper")
rows = []
for ln in blk.group(1).splitlines()[2:]:
    c = [x.strip() for x in ln.strip().strip("|").split("|")]
    if len(c) == 6:
        rows.append((c[0], float(c[5])))
if len(rows) != 4:
    raise SystemExit("expected 4 rows, got %d" % len(rows))
print("  parsed from the paper's table 4:")
for name, r in rows:
    print("    %-36s %5.2f" % (name, r))

LABEL = ["慢盘读\n(阶段 A)", "高速盘驻留\n(阶段 B)", "当日最优配置\n(首轮扫描)",
         "分相位实测\n(第二次)"]

fig, ax = plt.subplots(1, 2, figsize=(7.4, 2.9))

vals = [r for _, r in rows]
xs = list(range(len(rows)))
ax[0].bar(xs, vals, color="0.45", edgecolor="0.1", lw=.8, width=.62)
ax[0].axhline(1.0, color="0.0", lw=1.1, ls="--")
ax[0].annotate("1.00: 字节÷带宽即定律", xy=(0.08, 1.0), xytext=(0.08, 3.42),
               fontsize=8, ha="left")
for x, v in zip(xs, vals):
    ax[0].text(x, v + .09, "%.2f" % v, ha="center", fontsize=8.5)
ax[0].set_xticks(xs)
ax[0].set_xticklabels(LABEL, fontsize=7.6)
ax[0].set_ylabel("实测 ÷ 公式下限")
ax[0].set_ylim(0, max(vals) * 1.22)
ax[0].set_title("(a) 原始比值", fontsize=9.5)
ax[0].tick_params(labelsize=8)
ax[0].grid(axis="y", alpha=.3, lw=.5)

rp = [1.00, 1.06]
ax[1].bar([0, 1], rp, color="0.45", edgecolor="0.1", lw=.8, width=.42)
ax[1].axhspan(0.9, 1.1, color="0.75", lw=0)
ax[1].text(0.5, 1.30, "10% 判定带: 两档均落入", fontsize=8, color="0.25", ha="center")
for x, v in zip([0, 1], rp):
    ax[1].text(x, v + .05, "%.2f" % v, ha="center", fontsize=8.5)
ax[1].set_xticks([0, 1])
ax[1].set_xticklabels(["阶段 A\n单一顺序流", "分相位实测\n主干/专家分流计价"], fontsize=7.6)
ax[1].set_ylabel("实测 ÷ 公式下限")
ax[1].set_ylim(0, 1.62)
ax[1].set_title("(b) 分流计价后", fontsize=9.5)
ax[1].tick_params(labelsize=8)
ax[1].grid(axis="y", alpha=.3, lw=.5)

fig.tight_layout()
fig.savefig("docs/images/table4_ratio.png", dpi=200, bbox_inches="tight", facecolor="white")
Image.open("docs/images/table4_ratio.png").convert("L").save(
    "docs/images/table4_ratio_grey.png")

hdr = open("docs/images/table4_ratio_grey.png", "rb").read()
print()
print("  wrote docs/images/table4_ratio_grey.png   IHDR colour type = %d" % hdr[25])
print("  re-priced ratios: %.2f and %.2f" % (rp[0], rp[1]))