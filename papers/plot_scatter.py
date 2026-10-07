#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Figure: the byte count is flat, the wall clock is not.

Thirty runs of one identical configuration, every one of them the same 4595 requests and
216.66 GB. The left panel is that byte count against run order: a flat line. The right panel
is the same runs' s/token: scattered from 65 to 118. BENCH_PROTO section 14.1 defines a 10%
paired-difference threshold for declaring a difference, drawn here as a band around the
median, so a reader can see at a glance which recorded comparisons fall inside it -- most of
them, including several that were earlier reported as improvements.

Greyscale only: the journal prints in black and white.
"""
import json, pathlib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

# WSL has no CJK font installed, so the labels render as tofu boxes. The Windows fonts are
# visible through the /mnt/c mount, and Microsoft YaHei covers the glyphs used here.
_CJK = []
for f in ("/mnt/c/Windows/Fonts/msyh.ttc",
          "/mnt/c/Windows/Fonts/simhei.ttf",
          "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"):
    if pathlib.Path(f).exists():
        try:
            font_manager.fontManager.addfont(f)
            _CJK.append(font_manager.FontProperties(fname=f).get_name())
        except Exception:
            pass
if not _CJK:
    raise SystemExit("找不到中文字体，图上的中文会变成方框")
plt.rcParams["font.family"] = _CJK + ["DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False
print("  用字体：%s" % ", ".join(_CJK))

d = json.loads(pathlib.Path("papers/scatter_data.json").read_text(encoding="utf-8"))
pts, allr = d["pts"], d["allruns"]
n = len(pts)
spt = sorted(p["spt"] for p in pts)
med = spt[n // 2]

fig, ax = plt.subplots(1, 2, figsize=(7.4, 2.9))

# left: bytes, flat
ax[0].plot(range(1, n + 1), [d["gb"]] * n, "o-", color="0.15", ms=4.5, lw=1.4)
ax[0].set_ylabel("每词元交付字节 (GB)")
ax[0].set_xlabel("运行次序（同配置，30 次）")
ax[0].set_ylim(d["gb"] - 2, d["gb"] + 2)
ax[0].annotate("%.2f GB，30 次运行完全一致" % d["gb"],
               xy=(n / 2, d["gb"]), xytext=(n / 2, d["gb"] + 1.4),
               ha="center", fontsize=8.5, color="0.1",
               arrowprops=dict(arrowstyle="-", lw=.7, color="0.4"))
ax[0].set_title("(a) 字节量", fontsize=9.5)
ax[0].tick_params(labelsize=8)
ax[0].grid(alpha=.3, lw=.5)

# right: wall clock, scattered
ax[1].plot(range(1, n + 1), [p["spt"] for p in pts], "o", color="0.25", ms=4.5)
ax[1].axhline(med, color="0.0", lw=1.2)
ax[1].axhspan(med * 0.9, med * 1.1, color="0.75", lw=0)
ax[1].annotate("中位数 %.1f" % med, xy=(1.5, med), xytext=(1.5, med - 4.5),
               fontsize=8, ha="left")
ax[1].annotate("10%% 判定带（规程 14.1）", xy=(2, med * 1.1),
               xytext=(2, med * 1.16), fontsize=8, color="0.25", ha="left")
ax[1].set_ylim(min(x["spt"] for x in pts) - 8, max(x["spt"] for x in pts) + 10)
ax[1].set_ylabel("输出速度 (s/词元)")
ax[1].set_xlabel("运行次序（同配置，按运行时间排列）")
ax[1].set_title("(b) 输出速度，跨度 %.0f%%" % d["span"], fontsize=9.5)
ax[1].tick_params(labelsize=8)
ax[1].grid(alpha=.3, lw=.5)

fig.tight_layout()
for out in ("docs/images/byte_vs_time_grey.png", "docs/images/byte_vs_time.png"):
    fig.savefig(out, dpi=200, bbox_inches="tight", facecolor="white")
    print("  写出 %s" % out)

print()
print("  落在 10%% 判定带内的运行：%d / %d" %
      (sum(1 for x in spt if med * 0.9 <= x <= med * 1.1), n))
print("  区间 %.2f – %.2f s/词元，跨度 %.1f%%" % (spt[0], spt[-1], d["span"]))