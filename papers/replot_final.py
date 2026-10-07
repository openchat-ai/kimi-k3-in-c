#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Regenerate all five figures with font sizes corrected for the placement scale.

The template fixes the caption at 6 号 (7.5 pt) and the body at 小五 (9 pt); it says nothing
about text inside a figure, only that the figure be clear and no wider than 8 cm. Those two
together create a trap: figures were generated at 16 cm and placed at 8 cm, so an 8.5 pt label
lands on paper at 4.2 pt -- smaller than the caption beside it and less than half the body text.
Every figure was unreadable at print size.

Fix: keep the large canvas, which is what gives the resolution, and scale the fonts by the
reciprocal of the placement ratio so that what arrives on paper is the intended size. In-figure
text is set to 7.5 pt on paper, matching the caption; axis labels and tick labels slightly
smaller; the value on each mark at caption size.

Also: 300 dpi rather than 200, since the journal asks for clear figures and the canvas is now
being scaled down anyway.
"""
import json, pathlib, re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from PIL import Image

PLACE_CM = 8.0          # the width the builder uses in the docx
DPI = 300

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

MD = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")


class Fig:
    """A figure that knows how big it will be on paper, and scales its own fonts to match."""

    def __init__(self, w_in, h_in, ncols=1):
        self.w_in, self.h_in = w_in, h_in
        # canvas cm / paper cm. A font of size S set on the canvas prints at S * scale, so the
        # size to set is size / scale.
        self.scale = PLACE_CM / (w_in * 2.54)
        self.fig, axes = plt.subplots(ncols=ncols, figsize=(w_in, h_in),
                                      squeeze=False)
        self.axes = list(axes.ravel())
        self._fix()

    def _fix(self):
        for a in self.axes:
            a.xaxis.label.set_fontsize(7.0 / self.scale)
            a.yaxis.label.set_fontsize(7.0 / self.scale)
            a.title.set_fontsize(8.0 / self.scale)
            a.tick_params(labelsize=6.5 / self.scale)

    def f(self, size):
        """A font size that will print at `size` points."""
        return size / self.scale

    def save(self, stem):
        self.fig.tight_layout()
        self.fig.savefig("docs/images/%s.png" % stem, dpi=DPI, bbox_inches="tight",
                         facecolor="white")
        Image.open("docs/images/%s.png" % stem).convert("L").save(
            "docs/images/%s_grey.png" % stem)
        ct = open("docs/images/%s_grey.png" % stem, "rb").read()[25]
        print("  %-14s canvas %.1fcm -> paper %.1fcm  放大×%.2f  灰度=%s"
              % (stem, self.w_in * 2.54, PLACE_CM, 1.0 / self.scale, ct == 0))
        plt.close(self.fig)


def style(ax, grid=True):
    ax.grid(alpha=.3, lw=.5)
    if grid:
        ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)


# ------------------------------------------------------------------ fig 2
plt.rcParams["font.family"] = CJK + ["DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False
fig = Fig(6.4, 2.9)
ax = fig.axes[0]
SLOW, FAST, DRAM, TOTAL = [25.83, 6.7, 0.0], [0.0, 19.1, 0.0], [0.0, 0.0, 25.83], [25.83] * 3
ax.plot([0, 1, 2], SLOW, "o-", color="0.10", lw=1.6, ms=6, label="slow")
ax.plot([0, 1, 2], FAST, "s-", color="0.45", lw=1.6, ms=6, label="fast")
ax.plot([0, 1, 2], DRAM, "^--", color="0.68", lw=1.3, ms=6, mfc="white",
        label="DRAM (target)")
ax.plot([0, 1, 2], TOTAL, ":", color="0.0", lw=1.7, label="total")
for x, v in zip([0, 1, 2], SLOW):
    if v:
        ax.annotate("%.2f" % v, (x, v), textcoords="offset points",
                    xytext=(0, -14), ha="center", fontsize=fig.f(6.0))
for x, v in zip([0, 1, 2], FAST):
    if v:
        ax.annotate("%.1f" % v, (x, v), textcoords="offset points",
                    xytext=(10, 1), ha="left", fontsize=fig.f(6.0))
ax.annotate("%.2f" % DRAM[2], (2, DRAM[2]), textcoords="offset points",
            xytext=(-8, 6), ha="right", fontsize=fig.f(6.0))
ax.annotate("%.2f" % TOTAL[1], (1, TOTAL[1]), textcoords="offset points",
            xytext=(4, -13), ha="left", fontsize=fig.f(6.0))
ax.set_xticks([0, 1, 2])
ax.set_xticklabels(["A", "B", "C"], fontsize=fig.f(7.5))
ax.set_xlim(-0.2, 2.25)
ax.set_ylim(0, 34)                      # headroom so the legend cannot touch the total line
ax.set_xlabel("landing tier", fontsize=fig.f(6.5))
ax.set_ylabel("GB / token", fontsize=fig.f(6.5))
lg = ax.legend(loc="upper center", ncol=4, fontsize=fig.f(5.6),
               bbox_to_anchor=(0.5, 1.10), columnspacing=1.2, handlelength=2.0)
style(ax)
fig._fix()
fig.save("tier_shift")

# ------------------------------------------------------------------ fig 3
d = json.loads(pathlib.Path("papers/scatter_data.json").read_text(encoding="utf-8"))
pts, n = d["pts"], len(d["pts"])
spt = sorted(p["spt"] for p in pts)
med = spt[n // 2]
fig = Fig(6.8, 2.5, ncols=2)
a0, a1 = fig.axes
a0.plot(range(1, n + 1), [d["gb"]] * n, "o-", color="0.15", ms=3.5, lw=1.3)
a0.set_ylabel("GB / token", fontsize=fig.f(7.0))
a0.set_xlabel("run", fontsize=fig.f(7.0))
a0.set_ylim(d["gb"] - 2, d["gb"] + 2)
a0.set_title("(a)", fontsize=fig.f(8.5))
a1.plot(range(1, n + 1), [p["spt"] for p in pts], "o", color="0.25", ms=3.5)
a1.axhspan(med * 0.9, med * 1.1, color="0.78", lw=0)
a1.axhline(med, color="0.0", lw=1.1)
a1.set_ylabel("s / token", fontsize=fig.f(7.0))
a1.set_xlabel("run", fontsize=fig.f(7.0))
a1.set_ylim(min(spt) - 8, max(spt) + 10)
a1.set_title("(b)", fontsize=fig.f(8.5))
for a in (a0, a1):
    style(a)
    a.tick_params(labelsize=fig.f(6.5))
fig._fix()
fig.save("byte_vs_time")

# ------------------------------------------------------------------ fig 4
blk = re.search(r"### 4\.6.*?\n(\|.*?)\n\n", MD, re.S)
ratios = [float([c.strip() for c in l.strip().strip("|").split("|")][5])
          for l in blk.group(1).splitlines()[2:]
          if len([c.strip() for c in l.strip().strip("|").split("|")]) == 6]
fig = Fig(6.8, 2.5, ncols=2)
a0, a1 = fig.axes
a0.bar(range(4), ratios, color="0.45", edgecolor="0.1", lw=.8, width=.6)
a0.axhline(1.0, color="0.0", lw=1.0, ls="--")
for x, v in enumerate(ratios):
    a0.annotate("%.2f" % v, (x, v), textcoords="offset points", xytext=(0, 3),
                ha="center", fontsize=fig.f(7.5))
a0.set_xticks(range(4))
a0.set_xticklabels(list("ABCD"), fontsize=fig.f(8.5))
a0.set_ylabel("measured / bound", fontsize=fig.f(7.0))
a0.set_ylim(0, max(ratios) * 1.2)
a0.set_title("(a)", fontsize=fig.f(8.5))
rp = [1.00, 1.06]
a1.bar([0, 1], rp, color="0.45", edgecolor="0.1", lw=.8, width=.4)
a1.axhspan(0.9, 1.1, color="0.78", lw=0)
for x, v in zip([0, 1], rp):
    a1.annotate("%.2f" % v, (x, v), textcoords="offset points", xytext=(0, 3),
                ha="center", fontsize=fig.f(7.5))
a1.set_xticks([0, 1])
a1.set_xticklabels(["A", "D"], fontsize=fig.f(8.5))
a1.set_ylabel("measured / bound", fontsize=fig.f(7.0))
a1.set_ylim(0, 1.35)
a1.set_title("(b)", fontsize=fig.f(8.5))
for a in (a0, a1):
    style(a)
    a.tick_params(labelsize=fig.f(6.5))
fig._fix()
fig.save("table4_ratio")

# ------------------------------------------------------------------ fig 5
blk3 = re.search(r"\| 读取流 \|.*?\n\n", MD, re.S)
trunk = expert = None
for l in blk3.group(0).splitlines():
    c = [x.strip() for x in l.strip().strip("|").split("|")]
    if len(c) < 6 or not c[1] or not c[4]:
        continue
    try:
        gb, sec = float(c[1].replace(" GB", "")), float(c[4].replace(" s", ""))
    except ValueError:
        continue
    if "主干" in c[0]:
        trunk = (gb, sec)
    elif "专家" in c[0]:
        expert = (gb, sec)
fig = Fig(6.2, 2.4, ncols=2)
for k, (vals, ylab) in enumerate([([trunk[0], expert[0]], "GB / token"),
                                  ([trunk[1], expert[1]], "s / token")]):
    a = fig.axes[k]
    a.bar([0, 1], vals, color="0.45", edgecolor="0.1", lw=.8, width=.45)
    for x, v in zip([0, 1], vals):
        a.annotate("%.4g" % v, (x, v), textcoords="offset points", xytext=(0, 3),
                   ha="center", fontsize=fig.f(7.5))
    a.set_xticks([0, 1])
    a.set_xticklabels(["trunk", "expert"], fontsize=fig.f(8.0))
    a.set_ylabel(ylab, fontsize=fig.f(7.0))
    a.set_ylim(0, max(vals) * 1.25)
    a.set_title("(%s)" % "ab"[k], fontsize=fig.f(8.5))
    style(a)
    a.tick_params(labelsize=fig.f(6.5))
fig._fix()
fig.save("bytes_vs_cost")
print("  all figures regenerated at %d dpi" % DPI)