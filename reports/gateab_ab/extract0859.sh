#!/bin/bash
cd /mnt/f/kimi-k3-in-c
git cat-file -p 'stash@{0}:bin/k3' > /root/k3_0859 2>/dev/null
echo "extracted: $(stat -c%s /root/k3_0859) bytes"
echo "current  : $(stat -c%s bin/k3) bytes"
echo "== md5:"; md5sum /root/k3_0859 bin/k3
echo "== does the 08:59 binary contain the group-1 L2 submit? (objdump of k3_l2_load_direct)"
objdump -d /root/k3_0859 --no-show-raw-insn 2>/dev/null | awk '/<k3_l2_load_direct>:/,/ret/' | grep -E "k3_io_submit" | head -3
echo "== and the current one:"
objdump -d bin/k3 --no-show-raw-insn 2>/dev/null | awk '/<k3_l2_load_direct>:/,/ret/' | grep -E "k3_io_submit" | head -3