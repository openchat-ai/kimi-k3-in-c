#!/bin/bash
echo "== / top level:"
ls / | head -25
echo "== trunk/experts dirs (depth 3):"
find / -maxdepth 3 -name "trunk_layers_out" -o -maxdepth 3 -name "experts.l2" -o -maxdepth 3 -name "embed" 2>/dev/null | head -10
echo "== du of / (top dirs):"
du -sh /* 2>/dev/null | sort -rh | head -6