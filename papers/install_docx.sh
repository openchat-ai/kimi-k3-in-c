#!/bin/bash
set -u
pip3 install python-docx -q 2>&1 | tail -3
python3 - <<'PY'
try:
    import docx
    print("python-docx ready")
except ImportError as e:
    print("still unavailable:", e)
PY