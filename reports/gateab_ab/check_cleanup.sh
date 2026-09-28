#!/bin/bash
# Verify the falsified-mechanism cleanup. Confirms the symbols are GONE from the
# binary (not just from the source), that nothing new regressed, and that the
# matmul is still on AVX2 rather than a stale-objectfile SSE build.
set -u
cd /mnt/f/kimi-k3-in-c

echo "=== 1. clean rebuild (mandatory: stale .o silently degrades matmul to SSE)"
make clean >/dev/null 2>&1
make -j8 2>&1 | grep -iE '\berror\b|warning:' | head -20
echo "   (no error/warning lines above = clean)"

echo
echo "=== 2. binary timestamp"
ls -l --time-style=+%H:%M bin/k3

echo
echo "=== 3. removed symbols must NOT appear anywhere in the binary"
for s in K3_L2_NATIVE k3_io_set_active k3_trunk_expert_hold phase2_hold active_group; do
  n=$(strings bin/k3 | grep -c -- "$s")
  if [ "$n" -eq 0 ]; then
    printf '   OK   %-22s absent\n' "$s"
  else
    printf '   FAIL %-22s still present (%s)\n' "$s" "$n"
  fi
done

echo
echo "=== 4. K3_NOKIO must SURVIVE (it is a supported knob, not a falsified one)"
n=$(strings bin/k3 | grep -c -- K3_NOKIO)
printf '   K3_NOKIO occurrences: %s\n' "$n"

echo
echo "=== 5. matmul vector width: ymm must be > 400 (SSE build shows ~323)"
y=$(objdump -d bin/k3 | grep -c ymm)
x=$(objdump -d bin/k3 | grep -c 'xmm.*mulss\|xmm.*mulps')
printf '   ymm=%s  (want >400)\n' "$y"

echo
echo "=== 6. dynamic symbols: the three removals must not be exported"
nm -D bin/k3 2>/dev/null | grep -E 'set_active|expert_hold' || echo "   OK   none exported"
