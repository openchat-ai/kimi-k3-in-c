#!/bin/bash
set -u
cd /mnt/f/kimi-k3-in-c || exit 1
ls -la bin/k3
echo "--- symbol/string presence (expect >= 3 and both print formats) ---"
echo "prefetch-symbol strings: $(strings bin/k3 | grep -cE 'prefetch_ahead|prefetch_depth|prefetch_issued')"
echo "dbg-reader-tag: $(strings bin/k3 | grep -cF '[reader]')"
echo "survival-fmt:   $(strings bin/k3 | grep -cF 'survival %.1f%%')"
echo "issued-fmt:     $(strings bin/k3 | grep -cF 'issued %llu')"
echo "--- fine ---"