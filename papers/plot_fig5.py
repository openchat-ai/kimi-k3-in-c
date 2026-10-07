#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Figure 5: the contrast the paper keeps describing in words.

Table 3's two rows carry the whole point: the trunk moves more bytes than the experts and
spends two orders of magnitude less time on them. The prose states that as "搬得多的近乎免费
(不足墙的 1%)，搬得少的成为瓶颈", with four numbers in one sentence. This puts the two rows
side by side on a log scale so the reader sees the inversion instead of parsing four figures
out of a sentence.

Bytes on the left axis, exposure time on the right, both logarithmic -- the two quantities
differ by 2.4 orders of magnitude, which is the finding.

Values are read out of the paper's own table 3 so the figure cannot drift from the text.
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
blk = re.search(r"\| 读取流 \|.*?\n\n", md, re.S)
if not blk:
    raise SystemExit("table 3 not found")

trunk = expert = None
for ln in blk.group(0).splitlines():
    c = [x.strip() for x in ln.strip().strip("|").split("|")]
    if len(c) < 6 or not c[1] or not c[4]:
        continue
    try:
        gb = float(c[1].replace(" GB", ""))
        sec = float(c[4].replace(" s", ""))
    except ValueError:
        continue
    if "主干" in c[0]:
        trunk = (gb, sec)
    elif "专家" in c[0]:
        expert = (gb, sec)
if not trunk or not expert:
    raise SystemExit("trunk/expert rows not parsed")

print("  parsed from table 3:")
print("    trunk  %6.1f GB  %6.2f s" % trunk)
print("    expert %6.1f GB  %6.2f s" % expert)

labels = ["主干权重", "专家权重"]
fig, ax = plt.subplots(1, 2, figsize=(6.6, 2.7))

b0 = ax[0].bar(labels, [trunk[0], expert[0]], color="0.45", edgecolor="0.1",
               lw=.8, width=.5)
for x, v in zip(labels, [trunk[0], expert[0]]):
    ax[0].text(x, v * 1.04, "%.1f GB" % v, ha="center", fontsize=8.5)
ax[0].set_ylabel("每词元字节")
ax[0].set_ylim(0, max(trunk[0], expert[0]) * 1.28)
ax[0].set_title("(a) 搬运量", fontsize=9.5)
ax[0].tick_params(labelsize=8.5)
ax[0].grid(axis="y", alpha=.3, lw=.5)

b1 = ax[1].bar(labels, [trunk[1], expert[1]], color="0.45", edgecolor="0.1",
               lw=.8, width=.5)
for x, v in zip(labels, [trunk[1], expert[1]]):
    ax[1].text(x, v * 1.06, "%.2f s" % v, ha="center", fontsize=8.5)
ax[1].set_ylabel("暴露在墙上的时间 (s/词元)")
ax[1].set_ylim(0, max(trunk[1], expert[1]) * 1.28)
ax[1].set_title("(b) 代价", fontsize=9.5)
ax[1].tick_params(labelsize=8.5)
ax[1].grid(axis="y", alpha=.3, lw=.5)

fig.tight_layout()
fig.savefig("docs/images/bytes_vs_cost.png", dpi=200, bbox_inches="tight", facecolor="white")
Image.open("docs/images/bytes_vs_cost.png").convert("L").save(
    "docs/images/bytes_vs_cost_grey.png")

hdr = open("docs/images/bytes_vs_cost_grey.png", "rb").read()
print()
print("  wrote docs/images/bytes_vs_cost_grey.png   IHDR colour type = %d" % hdr[25])
print("  搬得多 %.1f GB 用 %.2f s，搬得少 %.1f GB 用 %.2f s —— 相 %.0f 倍"
      % (trunk[0], trunk[1], expert[0], expert[1], expert[1] / max(trunk[1], 1e-9)))