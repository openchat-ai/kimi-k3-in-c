#!/bin/bash
# Append 13.5 to BENCH_PROTO.md. Written from bash rather than through the write tool
# because PowerShell's Get-Content reads this file as GBK and mangles the Chinese text;
# that is a display problem, not a file problem, but appending from here avoids touching it.
set -u
P=/mnt/f/kimi-k3-in-c/reports/gateab_ab/BENCH_PROTO.md
if grep -q "13.5" "$P"; then echo "13.5 already present, not appending again"; exit 0; fi

cat >> "$P" <<'EOF'

#### 13.5 烟测必须调用被测的那段代码

今天 v55 连续栽在同一件事上两次，两次都是"烟测通过了，长跑全灭"：

1. 解析函数在独立脚本里跑通（4 流正确加出 1642 MB/s），长跑 11 组全部报 0 流。
   原因是长跑把 `dd 2>&1 &` 嵌在 `$( { ... } 2>&1 )` 里，每流输出被重定向到子 shell，
   awk 根本看不到。**能单独跑 ≠ 在真实调用位置能跑。**
2. 烟测把块大小写成字面 `4194304`，脚本里用的是变量 `4M`，
   于是 `$((per/bs))` 报 `4M: value too great for base`，11 组全灭。
   **烟测跑的是和实跑不同的代码路径。**

这两条与 13.1–13.4 是同一个病：探针的失败模式与真实故障长度一致，而探针本身不自检。
13.5 是它的正解——

```规则：烟测必须调用被测函数本身，不得复制其逻辑或改写其参数。
      变量、字段、重定向层次三者任一与长跑不同，烟测即无效。
      宁可让长跑的前 1 组在脚本内自检并中止，也不要靠外部预检放行。```

长跑的硬中止同样重要：v55 加了 `mismatch 即 exit` 之后，第二次失败没有产出十一个空行，
也没有汇总出一个"设备天花板 = 0"之类的假数。**失败要停，不能继续输出看起来像数据的表格。**
EOF
echo "appended 13.5; file is now $(wc -l < "$P") lines"
