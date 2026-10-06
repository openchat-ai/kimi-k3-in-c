#!/bin/bash
# What can produce a Word file here? No pandoc, no LibreOffice, and Word COM fails with
# TYPE_E_CANTLOADLIBRARY on this host. Check python-docx before deciding on RTF.
set -u
cd /mnt/f/kimi-k3-in-c
echo "== python-docx"
python3 - <<'PY'
try:
    import docx
    print("  可用")
except ImportError as e:
    print("  不可用:", e)
PY
echo
echo "== pip 里与文档生成相关的包"
pip3 list 2>/dev/null | grep -iE 'docx|openpyxl|reportlab|pandoc|odf|weasyprint|fpdf' || echo "  无"
echo
echo "== 能否 pip 装（离线会失败，只为判断）"
timeout 20 pip3 download python-docx -d /tmp/pdx --no-deps -q 2>&1 | tail -2 | sed 's/^/  /' || echo "  下载失败（可能无外网）"
ls /tmp/pdx 2>/dev/null | sed 's/^/  已下载: /' || echo "  /tmp/pdx 为空"