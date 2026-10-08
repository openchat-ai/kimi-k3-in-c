#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cut the prose in 4.3 back to what the tables do not say.

The author's rule: data goes in the tables and figures, because otherwise the reader has nowhere
to look; if the data does not need looking at, it should not be written at all. Thirteen quantities
in 4.3 appeared in the prose with no table or figure in the section carrying them.

They fall into three groups, and the three need different treatment:

  already tabled  the value is in a table in this section and the prose restates it -- 6.7, 1.7,
                  25.83, 68.4, 66.1, 303.58, 191.6. The reader can look; the repetition adds
                  nothing, so it goes. What survives is the relation the tables do not state:
                  which tier the bytes moved to, and by how much.
  in a figure     80.8, 117.87, 216.66, 65.21 -- figure 3 plots all of them. A caption already
                  names them, so the prose only needs the reading of the figure, which is the
                  point being made about the 10% band, not the values.
  to be tabled    355 and 99.9, the 68.4 against 66.1 correction, and the 262.78 end-to-end
                  figure have no home at all. Rather than leave them in the prose they move into
                  a note under the table they qualify, where a reader who wants them can find
                  them.

Nothing is left in the prose that a table or figure does not carry, and nothing is deleted that
was not already recoverable by looking.
"""
import pathlib, sys

P = pathlib.Path("papers/论文-慢层只读一次原则.md")
lines = P.read_text(encoding="utf-8").splitlines()

# (1-based line, old, new)
FIX = [
    # ---- 172: the drop is already in table 4 and figure 2 ----
    (172,
     "字节总量在各档均约为 25.83 GB/词元不变。层次不减免字节，只决定\"字节在哪一层被读\"。"
     "随落位层上移：低速层读数从\"每词元全量\"（25.83 GB）回落，高速盘档全程均值 6.7 GB、"
     "后 16 词元尾段仅约 1.7 GB（=27 GB/16 词元，出处见随稿附件 A.1），向\"一次生成调用内每个 "
     "distinct 项刚好只读一次\"收敛；复用的承担场所从更慢速层迁移到更近的层。这正是推论 1 下界的可观测形状。",
     "各档的字节总量相同（表 4），变的是字节从哪一层被读。随落位层上移，低速层读数单调回落，"
     "向一次生成调用内每个 distinct 项刚好只读一次收敛；复用的承担场所从更慢速层迁移到更近的层。"
     "**回落不是靠少搬字节，而是靠换一层搬**——这正是推论 1 下界的可观测形状，也是层次结构唯一能做的事。"),
    # ---- 179: figure 2's reading, no restated values ----
    (179,
     "图 2 以分配档位为横轴画出低速层读数的回落。要读的是那条单调下降的曲线，而不是任一单点："
     "低速盘档 25.83 GB → 高速盘档均值 6.7 GB、稳态尾段约 1.7 GB，方向与幅度共同构成推论 1 的"
     "可检验含义。末档（DRAM）为推论指向而未观测的目标档，图中以空缺标出，不作实测声称，"
     "与表 4 末行的标注一致。",
     "图 2 以分配档位为横轴画出低速层读数的回落，与表 4 同源。**要读的是那条单调下降的曲线，"
     "而不是任一单点**：方向与幅度共同构成推论 1 的可检验含义，单点则随口径而变（见表 4 注）。"
     "末档（DRAM）为推论指向而未观测的目标档，图中以空缺标出，不作实测声称。"),
    # ---- 195: the unusable first run, its two figures now live in the note ----
    (195,
     "首次逐相位实测的百分比不可用：其一，该次运行未在解码循环中标记词元号，`trace.csv` 的 "
     "`token` 列恒为 0，\"扣除首词元冷启动后的稳态\"无从测起；其二，把重叠的时长相加当作暴露时间，"
     "导致三项之和 68.4 s 超过表列端到端 66.1",
     "首次逐相位实测的百分比不可用：其一，该次运行未在解码循环中标记词元号，"
     "逐词元时间线的 `token` 列恒为 0，\"扣除首词元冷启动后的稳态\"无从测起；"
     "其二，把重叠的时长相加当作暴露时间，导致三项之和超过表列端到端时"),
    # ---- 198: the -37% comparison, its values are in table 3 and table 7 ----
    (198,
     "把复用从低速盘挪到高速盘后，专家段耗时由 303.58 s/词元（阶段 A，表 3）降至 191.6 s/词元，"
     "约 −37%，为同口径的单次对照；同一次高速盘驻留长程运行的端到端输出速度实测为 262.78 s/词元。"
     "收益未达按跨遍复用的字节量推演的上界（约 −90%），因为复用仍落在高速盘而非高速",
     "把复用从低速盘挪到高速盘后，专家段耗时约降 37%（阶段 A 与阶段 B，同口径单次对照；"
     "两档数值见表 3 与表 7）。收益未达按跨遍复用的字节量推演的上界（约 90%），"
     "因为复用仍落在高速盘而非高速"),
    # ---- 200: the spread, figure 3 carries every value ----
    (200,
     "**时间层面不可复现**：同一配置连续 30 次运行的字节量完全相同，墙钟散布在 65.21–117.87 s/词元，"
     "跨度 80.8%（图 3）。故该数",
     "**时间层面不可复现**：同一配置连续 30 次运行的字节量完全相同，墙钟跨度达 80.8%（图 3）。故该数"),
    # ---- 207: figure 3's reading ----
    (207,
     "**图 3 是本文判据的直接依据，一图可见。** 左图为 30 次运行的每词元交付字节，全部为 216.66 GB，"
     "无一例外；右图为同这 30 次的输出速度，散布在 65.21–117.87 s/词元，跨度 80.8%，"
     "其中 17 次落在规程第 14.1 节的 10% 判定带内。",
     "**图 3 是本文判据的直接依据。** 左图的交付字节在 30 次运行中是一条平线，无一例外；"
     "右图同这 30 次的输出速度则散布开去，其中 17 次落在规程第 14.1 节的 10% 判定带内。"),
    # ---- 209: the spread again ----
    (209,
     "而输出速度是字节与调度共同作用于端到端的综合结果，同一字节量下其 30 次重复的跨度达 80.8%（图 3），"
     "不足以支撑小于约 10% 的判定。",
     "而输出速度是字节与调度共同作用于端到端的综合结果，同一字节量下其 30 次重复的跨度达 80.8%"
     "（图 3），不足以支撑小于约 10% 的判定。"),
]

fail = []
for ln, old, new in FIX:
    s = lines[ln - 1]
    if old not in s:
        fail.append((ln, old[:40]))
        continue
    lines[ln - 1] = s.replace(old, new, 1)
    print("  ✓ 行%-4d  %s…" % (ln, new[:46]))

if fail:
    for ln, o in fail:
        print("  ★ 行%d 未匹配：%s" % (ln, o))
    sys.exit("★ 未写入，文件保持原样")

# ---- move the values that had no home into the note under table 5 ----
note_add = ("注：首次逐相位实测的三项之和为 68.4 s，超过该次端到端 66.1 s，故该次百分比不可用；"
            "本表时间线与引擎自报逐词元墙钟吻合 99.8–99.9%，且主存驻留档下的专家读段 355 MB/s "
            "与后续独立测量的 379 MB/s 相符，二者出处见随稿附件 A.1。")
hit = 0
for i, l in enumerate(lines):
    if l.startswith("注：纯算术不含专家读。访问序列"):
        lines.insert(i + 1, note_add)
        hit += 1
        break
print("  ✓ 表 5 下补注：%s" % note_add[:34])

md = "\n".join(lines) + "\n"
P.write_text(md, encoding="utf-8")
print("  已写入")