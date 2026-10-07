#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Figure 2, rebuilt: three tier-read curves plus the flat total, in one plot.

The previous figure 2 drew a single line -- the slow tier's read as the landing tier moves up --
and the surrounding text had to supply the other half of the argument ("总字节量在各档并不
下降，变化的只是这些字节被读在哪一层"). Table 2 already holds all of it: three tiers of reads
across three landing configurations.

One figure, four series:

  slow tier    the line that collapses, 25.83 GB -> 6.7 -> 0
  fast tier    the line that rises to absorb it
  DRAM         the unobserved target tier, marked as such
  total        flat at 25.83 GB throughout

The total being flat while the others move is the paper's central claim, so it belongs in the
same frame rather than in a sentence. In-figure text is symbols and units only; the reading
instruction is under the figure.

The target tier is drawn as an open marker on a dashed line because it was never observed --
marking it as measured would be the one thing the paper must not do.
"""
import pathlib
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

# table 2: rows are landing tiers A/B/C, columns are the three read tiers
X = [0, 1, 2]
SLOW = [25.83, 6.7, 0.0]        # A: 25.83   B: mean 6.7 (tail 1.7)   C: ~0
FAST = [0.0, 19.1, 0.0]        # A: 0       B: ~19.1                C: ~0
DRAM = [0.0, 0.0, 25.83]       # target tier, never observed
TOTAL = [25.83, 25.83, 25.83]  # constant by construction

fig, ax = plt.subplots(figsize=(6.4, 2.9))
ax.plot(X, SLOW, "o-", color="0.10", lw=1.6, ms=6, label="slow")
ax.plot(X, FAST, "s-", color="0.45", lw=1.6, ms=6, label="fast")
ax.plot(X, DRAM, "^--", color="0.70", lw=1.3, ms=6, mfc="white", label="DRAM (target)")
ax.plot(X, TOTAL, ":", color="0.0", lw=1.6)

for x, v in zip(X, SLOW):
    if v:
        ax.annotate("%.2g" % v, (x, v), textcoords="offset points",
                    xytext=(0, -14), ha="center", fontsize=8)
for x, v in zip(X, FAST):
    if v:
        ax.annotate("%.2g" % v, (x, v), textcoords="offset points",
                    xytext=(10, 2), ha="left", fontsize=8)
ax.annotate("%.2f" % DRAM[2], (2, DRAM[2]), textcoords="offset points",
            xytext=(-6, 8), ha="right", fontsize=8)
ax.annotate("%.2f" % TOTAL[1], (1, TOTAL[1]), textcoords="offset points",
            xytext=(2, -12), ha="left", fontsize=8)

ax.set_xticks(X)
ax.set_xticklabels(["A", "B", "C"], fontsize=9.5)
ax.set_xlim(-0.25, 2.3)
ax.set_ylim(0, 30)
ax.set_ylabel("GB / token")
ax.legend(loc="upper center", ncol=4, fontsize=8, frameon=False,
          bbox_to_anchor=(0.5, 1.16))
ax.grid(alpha=.3, lw=.5)
ax.tick_params(labelsize=8)
fig.tight_layout()
fig.savefig("docs/images/tier_shift.png", dpi=200, bbox_inches="tight", facecolor="white")
Image.open("docs/images/tier_shift.png").convert("L").save(
    "docs/images/tier_shift_grey.png")
ct = open("docs/images/tier_shift_grey.png", "rb").read()[25]
print("  wrote docs/images/tier_shift_grey.png   greyscale=%s" % (ct == 0))
print("  slow %s  fast %s  DRAM %s  total %s" % (SLOW, FAST, DRAM, TOTAL))