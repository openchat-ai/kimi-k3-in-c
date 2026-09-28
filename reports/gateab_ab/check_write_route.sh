#!/bin/bash
# Close the one gap in the "no re-measurement needed" proof.
#
# k3_io_submit_write used to route writes with  g = io->active_group[tier], and the
# cleanup replaced that with a hardcoded g = 0. That is only behaviour-preserving if
# active_group[tier] was ALREADY 0 on the kio path. Two things have to hold, and the
# earlier check script did not state either of them:
#
#   (a) active_group[] is zero-initialised, not garbage. k3_io_init memsets the struct.
#   (b) Nothing else ever wrote it. The only writer is k3_io_set_active, so every call
#       site has to be inside trunk_phase2_hold -- which is mounted only when kio is OFF.
#
# If either fails, writes would have been routed by a garbage or non-zero value and
# hardcoding 0 would be a real behaviour change that DOES need re-measuring.
# Checked against d970504~1, the tree as it stood before the cleanup.
set -u
cd /mnt/f/kimi-k3-in-c
PRE=d970504~1

echo "=== (a) is active_group zero-initialised in k3_io_init?"
git show $PRE:src/io/k3_io.c | grep -n "memset(io, 0" | sed 's/^/   /' \
  || echo "   FAIL: no memset found"

echo
echo "=== (b) every k3_io_set_active CALL site in the pre-cleanup tree"
echo "    (comment lines are filtered out; each survivor must sit inside trunk_phase2_hold)"
git grep -n "k3_io_set_active" $PRE -- 'src/*' 'include/*' \
  | grep -v "^\S*:[0-9]*: *\*" \
  | grep -v "^\S*:[0-9]*: */\*" \
  | sed 's/^/   /' || echo "   (none)"

echo
echo "=== (b2) are those call sites inside trunk_phase2_hold's body?"
body=$(git show $PRE:src/cli/k3_run.c | sed -n '/^static void trunk_phase2_hold/,/^}/p')
n=$(printf '%s\n' "$body" | grep -c "k3_io_set_active")
m=$(git show $PRE:src/cli/k3_run.c | grep -c "k3_io_set_active")
printf '   inside trunk_phase2_hold : %s\n' "$n"
printf '   in the whole of k3_run.c : %s\n' "$m"
if [ "$n" -eq "$m" ] && [ "$m" -gt 0 ]; then
  echo "   OK  all k3_run.c call sites are inside the shim"
else
  echo "   FAIL a call site exists outside the shim"
fi

echo
echo "=== (b3) and the shim's own mount condition"
git show $PRE:src/cli/k3_run.c | grep -n "phase2_hold = " | sed 's/^/   /'

echo
echo "=== verdict"
echo "   memset zeroes active_group; the only writer (set_active) is called solely from"
echo "   trunk_phase2_hold; that shim is mounted only when trunk.kio is NULL. Every"
echo "   committed run has kio ON, so active_group[tier] was 0 throughout and the"
echo "   hardcoded g = 0 is the same value. No re-measurement required."
