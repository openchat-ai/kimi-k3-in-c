#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Find body passages that restate established results a citation could carry instead.

Compression by citation is legitimate: where the paper re-derives or re-explains something
the literature already establishes, a citation replaces the restatement. What cannot be
compressed this way is the author's own measurements, so §4 is excluded by construction.
"""
import re, pathlib

lines = pathlib.Path("papers/论文-慢层只读一次原则.md").read_text(
    encoding="utf-8").splitlines()

secs, cur = {}, None
for ln in lines:
    s = ln.strip()
    mm = re.match(r"^## (\d)\s+(\S.*)$", s)
    if mm:
        cur = "§" + mm.group(1)
        secs[cur] = []
    elif cur and s:
        secs[cur].append(s)

# signals that a paragraph is exposition the literature already owns
THEORY = [
    (r"排队论|Little|Zahorjan|Denning", "排队论已有结论"),
    (r"Roofline|Eyeriss|算术强度|roofline", "Roofline 类既有模型"),
    (r"稀疏门控|Switch|Mixtral|DeepSeekMoE|专家路由", "MoE 架构背景"),
    (r"Cache hit|命中率|替换策略|LRU", "缓存与替换策略既有结论"),
    (r"Amdahl|瓶颈设备|加速比", "Amdahl 类既有定律"),
    (r"局部性原理|时间局部性|空间局部性", "局部性原理教科书结论"),
]
SELF = [
    (r"台账\s*:|本次实测|本平台|v\d\d|reports/|rebuilt|重建|撤回|修正", "本实验自有数据"),
    (r"表\s*[0-9A]|图\s*[0-9]", "指向本稿图表"),
]

print("  可压缩池（排除 §4，那 10428 字符全是自有实测）")
pool = 0
for k in ("§1", "§2", "§3", "§5", "§6"):
    n = sum(len(x) for x in secs.get(k, []))
    pool += n
    print("    %-4s %5d 字符" % (k, n))
print("    %-4s %5d 字符  ≈ %d 元" % ("池合计", pool, pool * 0.2))
print()

for k in ("§1", "§2", "§3", "§5", "§6"):
    print("  %s 中『可由引用替代的铺陈』候选" % k)
    found = 0
    for x in secs.get(k, []):
        if x.startswith(("|", "图", "表", "注：")) or len(x) < 60:
            continue
        if any(re.search(p, x) for p, _ in SELF):
            continue                       # author\'s own data: never compressible
        hit = [lab for p, lab in THEORY if re.search(p, x)]
        if hit:
            cited = re.findall(r"\[\d+(?:-\d+)?\]", x)
            found += 1
            print("      %3d 字 [%s] 引用现为 %s"
                  % (len(x), "/".join(hit), ",".join(cited) if cited else "无"))
            print("         %s" % x[:74])
    if not found:
        print("      无")
    print()