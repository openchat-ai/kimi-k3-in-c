#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Regenerate figures 3, 4 and 5 with the annotations moved out.

The rule: inside a figure there should be symbols, units and numbers. Anything that needs a
sentence belongs under the figure, where the caption already is. The previous versions of
these three put their findings in the plot area -- "字节÷带宽即定律", "10% 判定带: 两档均落入",
"216.66 GB，30 次运行完全一致" -- which means every one of them has to be read before the
shape of the data is legible, and every one of them has to be re-typed when the data changes.

So: axis labels become units only, panel titles become (a) and (b), the explanatory text moves
to the paper's captions. What stays inside is the value on top of each bar, the unit on each
axis, and the band or reference line drawn where it belongs.

Data is read from papers/scatter_data.json and from the paper's own tables, as before.
"""
import json, pathlib, re
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


def save(fig, stem):
    fig.savefig("docs/images/%s.png" % stem, dpi=200, bbox_inches="tight",
                facecolor="white")
    Image.open("docs/images/%s.png" % stem).convert("L").save(
        "docs/images/%s_grey.png" % stem)
    ct = open("docs/images/%s_grey.png" % stem, "rb").read()[25]
    print("  %-22s greyscale=%s" % (stem, ct == 0))


# ---------------------------------------------------------------- figure 3
d = json.loads(pathlib.Path("papers/scatter_data.json").read_text(encoding="utf-8"))
pts = d["pts"]
n = len(pts)
spt = sorted(p["spt"] for p in pts)
med = spt[n // 2]

fig, ax = plt.subplots(1, 2, figsize=(7.4, 2.5))
ax[0].plot(range(1, n + 1), [d["gb"]] * n, "o-", color="0.15", ms=4, lw=1.3)
ax[0].set_ylabel("GB / token")
ax[0].set_xlabel("run")
ax[0].set_ylim(d["gb"] - 2, d["gb"] + 2)
ax[0].set_title("(a)", fontsize=10)
ax[0].tick_params(labelsize=8)
ax[0].grid(alpha=.3, lw=.5)

ax[1].plot(range(1, n + 1), [p["spt"] for p in pts], "o", color="0.25", ms=4)
ax[1].axhspan(med * 0.9, med * 1.1, color="0.78", lw=0)
ax[1].axhline(med, color="0.0", lw=1.1)
ax[1].set_ylabel("s / token")
ax[1].set_xlabel("run")
ax[1].set_ylim(min(spt) - 8, max(spt) + 10)
ax[1].set_title("(b)", fontsize=10)
ax[1].tick_params(labelsize=8)
ax[1].grid(alpha=.3, lw=.5)
fig.tight_layout()
save(fig, "byte_vs_time")
print("    fig3: n=%d  bytes=%s GB  s/token %.2f-%.2f  median %.2f  span %.1f%%"
      % (n, d["gb"], spt[0], spt[-1], med, d["span"]))

# ---------------------------------------------------------------- figure 4
md = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(encoding="utf-8")
blk = re.search(r"### 4\.6.*?\n(\|.*?)\n\n", md, re.S)
ratios = []
for ln in blk.group(1).splitlines()[2:]:
    c = [x.strip() for x in ln.strip().strip("|").split("|")]
    if len(c) == 6:
        ratios.append(float(c[5]))
if len(ratios) != 4:
    raise SystemExit("table 4: expected 4 rows, got %d" % len(ratios))

fig, ax = plt.subplots(1, 2, figsize=(7.4, 2.5))
xs = list(range(4))
ax[0].bar(xs, ratios, color="0.45", edgecolor="0.1", lw=.8, width=.6)
ax[0].axhline(1.0, color="0.0", lw=1.0, ls="--")
for x, v in zip(xs, ratios):
    ax[0].text(x, v + .08, "%.2f" % v, ha="center", fontsize=8.5)
ax[0].set_xticks(xs)
ax[0].set_xticklabels(["A", "B", "C", "D"], fontsize=9)
ax[0].set_ylabel("measured / bound")
ax[0].set_ylim(0, max(ratios) * 1.2)
ax[0].set_title("(a)", fontsize=10)
ax[0].tick_params(labelsize=8)
ax[0].grid(axis="y", alpha=.3, lw=.5)

rp = [1.00, 1.06]
ax[1].bar([0, 1], rp, color="0.45", edgecolor="0.1", lw=.8, width=.4)
ax[1].axhspan(0.9, 1.1, color="0.78", lw=0)
for x, v in zip([0, 1], rp):
    ax[1].text(x, v + .04, "%.2f" % v, ha="center", fontsize=8.5)
ax[1].set_xticks([0, 1])
ax[1].set_xticklabels(["A", "D"], fontsize=9)
ax[1].set_ylabel("measured / bound")
ax[1].set_ylim(0, 1.35)
ax[1].set_title("(b)", fontsize=10)
ax[1].tick_params(labelsize=8)
ax[1].grid(axis="y", alpha=.3, lw=.5)
fig.tight_layout()
save(fig, "table4_ratio")
print("    fig4: raw %s  re-priced %s" % (ratios, rp))

# ---------------------------------------------------------------- figure 5
blk3 = re.search(r"\| 读取流 \|.*?\n\n", md, re.S)
trunk = expert = None
for ln in blk3.group(0).splitlines():
    c = [x.strip() for x in ln.strip().strip("|").split("|")]
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
if not trunk or not expert:
    raise SystemExit("table 3 rows not parsed")

fig, ax = plt.subplots(1, 2, figsize=(6.4, 2.4))
for k, (vals, ylab, title) in enumerate(
        [([trunk[0], expert[0]], "GB / token", "(a)"),
         ([trunk[1], expert[1]], "s / token", "(b)")]):
    b = ax[k].bar([0, 1], vals, color="0.45", edgecolor="0.1", lw=.8, width=.45)
    for x, v in zip([0, 1], vals):
        ax[k].text(x, v * 1.05, "%.2g" % v, ha="center", fontsize=8.5)
    ax[k].set_xticks([0, 1])
    ax[k].set_xticklabels(["trunk", "expert"], fontsize=8.5)
    ax[k].set_ylabel(ylab)
    ax[k].set_ylim(0, max(vals) * 1.25)
    ax[k].set_title(title, fontsize=10)
    ax[k].tick_params(labelsize=8)
    ax[k].grid(axis="y", alpha=.3, lw=.5)
fig.tight_layout()
save(fig, "bytes_vs_cost")
print("    fig5: trunk %.1f GB / %.2f s   expert %.1f GB / %.2f s"
      % (trunk[0], trunk[1], expert[0], expert[1]))