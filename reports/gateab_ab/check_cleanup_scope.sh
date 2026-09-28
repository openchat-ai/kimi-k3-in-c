#!/bin/bash
# Did the cleanup touch the code path that produced 73.96 s/token?
#
# Claim to check: the removed mechanism was already 100% dead on the kio path, so the
# committed baseline is unaffected and does not need re-measuring. The chain:
#
#   1. trunk_phase2_hold was mounted only as  (w.trunk && !trunk.kio) ? shim : NULL
#      -> with kio ON (the default, and what every gateAB run used), cache.phase2_hold
#         was NULL, so k3_cache.c's two phase2_hold() calls were no-ops.
#   2. The trunk reader's gate wait was guarded by  if (io && !trunk.kio)
#      -> with kio ON, that branch was never taken, so io->gate was never read.
#   3. io->gate was written ONLY by k3_trunk_expert_hold, whose only caller was the
#      shim from (1), itself mounted only when kio was OFF.
#
# So on the kio path: zero of the deleted statements executed. Check it rather than
# assert it.
set -u
cd /mnt/f/kimi-k3-in-c

echo "=== A. the mount condition, as it was before this cleanup (git HEAD)"
git show HEAD:src/cli/k3_run.c | grep -n "phase2_hold = " | sed 's/^/   /'

echo
echo "=== B. the gate-wait guard, as it was before this cleanup (git HEAD)"
git show HEAD:src/io/k3_trunk.c | grep -n "io && !tr->kio" | sed 's/^/   /'

echo
echo "=== C. did the measurement runs disable kio? (unset K3_NOKIO = kio ON)"
for f in reports/gateab_ab/ab30.sh reports/gateab_ab/ab31.sh; do
  printf '   %-28s ' "$f"
  if [ -f "$f" ] && grep -q "unset K3_NOKIO" "$f"; then
    echo "kio ON (K3_NOKIO unset)"
  else
    echo "CHECK: no explicit unset found"
  fi
done

echo
echo "=== D. surviving calls to the deleted cache hook (must be 0)"
grep -rn "phase2_hold" src include --include=*.c --include=*.h \
  | grep -v "^\S*: *\*" | grep -v "^\S*: */\*" | sed 's/^/   /' || true
n=$(grep -rn "phase2_hold(" src include --include=*.c --include=*.h | wc -l)
echo "   live call sites: $n (want 0)"
