#!/bin/bash
# PEP 668 blocks the install into the system Python. Use a venv rather than
# --break-system-packages: this is the build environment, not something to mutate.
set -u
cd /root
python3 -m venv /root/docxenv 2>&1 | tail -2
/root/docxenv/bin/pip install -q python-docx 2>&1 | tail -3
/root/docxenv/bin/python - <<'PY'
import docx
print("python-docx ready in venv")
PY