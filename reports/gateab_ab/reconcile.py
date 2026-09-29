#!/usr/bin/env python3
"""Reconcile every number the engine and the host have produced today, in one place.

Most of today's confusion came from quoting one ledger at a time. Each is internally
consistent and they disagree, because each measures a different thing. This puts them
side by side and states, for each pair, whether the difference is a definitional artefact
or a real gap.

The one that matters: v40 measured the same device, same O_DIRECT, same geometry, cache
preconditioned, at the engine's own ~11 outstanding reads, and got 2723 MB/s with IQR 0.039.
The engine's own hit-I/O ledger says 439 MB/s over the same file. That is 6.2x.
"""
import glob
import os
import re

def grab(path, pat, cast=float):
    try:
        t = open(path, errors="replace").read()
    except OSError:
        return None
    m = re.search(pat, t)
    return cast(m.group(1)) if m else None

v41 = sorted(glob.glob("reports/gateab_ab/v41_phase1/rep*"))[0]
lg = os.path.join(v41, "ctrl.log")

print("=" * 74)
print("WHAT THE ENGINE SAYS (v41, %s)" % os.path.basename(v41))
print("=" * 74)

hit_gb = grab(lg, r"read  from sdd7: ([0-9.]+) GB")
hit_wall = grab(lg, r"hit I/O   : [0-9.]+ GB in ([0-9.]+) s \(wall\)")
hit_rate = grab(lg, r"hit I/O   : [0-9.]+ GB in [0-9.]+ s \(wall\) = ([0-9.]+) MB/s")
pread_thr = grab(lg, r"pread ([0-9.]+) s")
per_thr = grab(lg, r"([0-9.]+) MB/s per-thread")
misses = grab(lg, r"misses ([0-9]+)\n", int)
written = grab(lg, r"written ([0-9.]+) GB")
disk_gb = grab(lg, r"read from disk: ([0-9.]+) GB")
disk_s = grab(lg, r"read from disk: [0-9.]+ GB in ([0-9.]+) s")
disk_rate = grab(lg, r"read from disk: [0-9.]+ GB in [0-9.]+ s \(([0-9.]+) MB/s")
trunk_gb = grab(lg, r"read ([0-9.]+) GB in [0-9.]+ s \([0-9.]+ MB/s pread\)")
trunk_rate = grab(lg, r"read [0-9.]+ GB in [0-9.]+ s \(([0-9.]+) MB/s pread\)")
spt = grab(lg, r"([0-9.]+) s/token average")

print("  hit I/O      : %7.2f GB in %7.2f s  = %6.0f MB/s   (experts.l2, O_DIRECT, via kio)"
      % (hit_gb, hit_wall, hit_rate))
print("  per-thread   : pread %8.2f s cumulative, %5.0f MB/s per thread" % (pread_thr, per_thr))
print("  concurrency  : %6.2fx  (cumulative pread / wall)" % (pread_thr / hit_wall))
print("  misses       : %d      slots written: %s GB" % (misses or 0, written))
print("  cold read    : %7.2f GB in %7.2f s  = %6.0f MB/s   (trunk_layers_out, buffered)"
      % (disk_gb, disk_s, disk_rate))
print("  trunk stream : %7.2f GB               = %6.0f MB/s" % (trunk_gb, trunk_rate))
print("  s/token      : %6.2f" % spt)

print()
print("=" * 74)
print("WHAT THE DEVICE SAYS (v40, cache preconditioned, O_DIRECT, same geometry)")
print("=" * 74)
print("  R=11 (the engine's own outstanding-read count) : 2723 MB/s   IQR 0.039  usable")
print("  R=16                                           : 2806 MB/s   IQR 0.063  usable")
print("  R=4                                            : 2551 MB/s   IQR 0.075  usable")
print("  continuous 21 GB, cache full (v39)             : 1377 MB/s   IQR 0.203  NOISY")

print()
print("=" * 74)
print("RECONCILIATION")
print("=" * 74)
print("  engine hit I/O      %6.0f MB/s" % hit_rate)
print("  device at R=11      %6.0f MB/s" % 2723)
print("  device at R=11 is %6.2fx the engine's hit I/O" % (2723 / hit_rate))
print()
print("  engine concurrency from its own ledger: %.1fx" % (pread_thr / hit_wall))
print("  v40's best usable arm sits at          16x")
print("  -> the engine is NOT under-provisioning the device with concurrency. It already")
print("     sustains 11.4x. v40's curve is flat from R=4, so there is nothing to win there.")
print()
print("  the difference is therefore NOT: cache (v39), burst size (v40), concurrency")
print("  (v40), phase-1 serialisation (v41, 0.13 s), refill writes (v41, 0 writes),")
print("  or page cache (the engine uses O_DIRECT throughout).")
print()
print("  what is left, and it is one thing: v40's reads are O_DIRECT at a 17547264-byte")
print("  stride, one slot per read. The engine's hit path also reads a whole slot per")
print("  read -- but it does so through k3_io_submit_g and 16 kio workers, i.e. the")
print("  requests queue on a user-space pool rather than being issued by the thread that")
print("  needs them. That hop is the one component never benchmarked in isolation:")
print("  v27 (K3_L2_NATIVE, which bypassed it) measured 408 against a 418 control, inside")
print("  an 11.6% band, so it was never actually resolved either way.")
