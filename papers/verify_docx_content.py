#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verify the generated DOCX actually contains every fix made to the markdown.

The whole session has been editing markdown and reading the checkers' reports about it. None of
those reports say anything about what is inside the DOCX, which is the file that gets submitted.
The DOCX is produced by build_docx.py, which re-parses the markdown and rewrites parts of it, so
anything that does not survive that transform is silently absent from the submission. This
extracts the DOCX text and looks for the specific strings each fix was supposed to introduce.

Also checked: the DOCX timestamp against the markdown timestamp, because a stale DOCX would pass
every content check that looks for things the older version already had.
"""
import pathlib, re, sys, zipfile, datetime

DOCX = pathlib.Path("papers/提交稿-缓存高命中与词元低输出.docx")
MD = pathlib.Path("papers/论文-慢层只读一次原则.md")

# ---- extract ----
with zipfile.ZipFile(DOCX) as z:
    xml = z.read("word/document.xml").decode("utf-8")
# paragraph and run boundaries become separators so text does not run together
txt = re.sub(r"</w:p>", "\n", xml)
txt = re.sub(r"<w:tab[^>]*/>", "\t", txt)
txt = re.sub(r"<w:br[^>]*/>", "\n", txt)
txt = re.sub(r"<[^>]+>", "", txt)
txt = txt.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
flat = re.sub(r"\s+", "", txt)

print("  DOCX  %d 字节，提取正文 %d 字符" % (DOCX.stat().st_size, len(flat)))

mdt = datetime.datetime.fromtimestamp(MD.stat().st_mtime)
dxt = datetime.datetime.fromtimestamp(DOCX.stat().st_mtime)
print("  源文mtime %s" % mdt.strftime("%H:%M:%S"))
print("  DOCX mtime %s%s" % (dxt.strftime("%H:%M:%S"),
                            "  ← DOCX 比源文旧！" if dxt < mdt else "  ✓ 新于源文"))

# ---- every fix made this session, as a presence check ----
MUST = [
    ("题名（作者原题）", "缓存高命中与词元低输出：慢层字节下界判据"),
    ("作者地址", "福建宁德355110"),
    ("CCF 会员号", "64053M"),
    ("模型名（中文）", "Moonshot开源的KimiK3混合专家模型"),
    ("英文题名", "HighCacheHitRatewithLowTokenOutput"),
    ("模型名（英文摘要）", "KimiK3(2.8TMoE)"),
    ("原则名（第3章题名）", "慢速层只读一次原则：下界与可验证性"),
    ("小节 3.1 题名", "原则：慢速层只读一次"),
    ("无「平凡」自辩", "平凡"),
    ("四步排查回放表", "本轮八处错误的四步排查回放"),
    ("六个坏计数器表题", "六个曾产生错误结论的计数器字段"),
    ("派生量校验对表题", "派生量与其交叉校验对象"),
    ("替换策略复测表题", "替换策略在字节口径下的复测"),
    ("表1 冷启动基线", "专家段基准台账（冷启动基线）"),
    ("表5 英文题名", "Secondphase-resolvedmeasurement"),
    ("刚好只读一次", "每层刚好只读一次"),
    ("无「骨架」", "骨架"),
    ("无「某系统」", "某系统"),
    ("无「恰读一次」", "恰读一次"),
    ("无「每会话」", "每会话"),
    ("无第一人称", "我们遇到了"),
    ("语态统一用「本文」", "本文给出"),
]
print()
print("  必须出现在 DOCX 中")
bad = 0
for name, needle in MUST:
    neg = name.startswith("无")
    hit = needle in flat
    ok = (not hit) if neg else hit
    if not ok:
        bad += 1
    print("    %s %-20s %s" % ("✓" if ok else "★", name,
                              ("存在" if hit else "不存在") if not neg
                              else ("仍在！" if hit else "已清除")))

# ---- table numbering, read out of the DOCX ----
print()
print("  表号（从 DOCX 提取）")
cn = [int(m.group(1)) for l in txt.split("\n")
      for m in [re.match(r"^表\s*(\d+)\s*[　\s]", l.strip())] if m]
en = [int(m.group(1)) for l in txt.split("\n")
      for m in [re.match(r"^Table\s*(\d+)\s*[　\s]", l.strip())] if m]
print("    中文表题编号 %s" % cn)
print("    英文表题编号 %s" % en)
seq = list(dict.fromkeys(cn))
print("  去重后 %s" % seq)
print("  应为 1-8 连续：%s" % (seq == list(range(1, len(seq) + 1))))

# ---- images ----
with zipfile.ZipFile(DOCX) as z:
    media = [n for n in z.namelist() if n.startswith("word/media/")]
print()
print("  嵌入图片 %d 张：%s" % (len(media), ", ".join(m.split("/")[-1] for m in media)))

if bad:
    sys.exit("★ %d 项不符合" % bad)
print()
print("  DOCX 与源文一致")