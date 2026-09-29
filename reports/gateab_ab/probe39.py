#!/usr/bin/env python3
"""Measure the drive with its own cache deliberately full, and see if the >=2.7x gap survives.

The v38 host-side counters settled what the guest could not. The engine asked for 529.1 GB
(trunk 349.03 + expert 180.11) and the physical drive moved 265.0 GB -- half the request
never reached the NAND. The drive was also only 77.6% busy on average, and the host saw a
mean queue depth of 86.75 while the engine believed it was offering 16.

One explanation covers all three, and it is the thing O_DIRECT does not protect against:
O_DIRECT bypasses the GUEST's page cache, not the CONTROLLER's own DRAM and SLC cache. The
Micron SSD measurement brief and SSD-iq (VLDB'25) both say the same thing from the other
side -- control the initial state, reach steady state, only then believe a number -- and
neither yesterday's probe did step one. Both read 21 GB out of experts.l2 without first
overwriting the device's cache, so each measured "whatever the cache happened to hold",
which is a function of the whole session history. That is the 47% swing (v36 1786 vs v37
1214) and the 2.7x gap, and they were never two things.

So: overwrite the cache, then measure immediately, with no idle gap in between.

Arms, all O_DIRECT at the engine's exact geometry (nslot=17096, slot_bytes=17547264,
16 lanes, 21 GB per sample):

  COLD      one sample, after a long idle -- the cache holds recent experts.l2 data
  POST      5 samples, immediately after the preconditioning write -- the cache is full
            of data that is not experts.l2
  POST+1s   5 samples, same but with a 1 s pause between bursts, which is what made v37
            reproducible (IQR 0.035 against 0.26-0.48)

The COLD-to-POST drop is the measurement. If the drive's cache is worth ~2x here, POST
lands near the engine's 410 MB/s and the ">=2.7x inefficiency in the engine" is really
"the engine was reading mostly-cached data", which is a different paper section entirely.
If POST stays high, the gap is real and the next step is bisecting k3_cache.

The host sampler runs alongside, so % Idle Time, real device latency and the queue depth
the host actually saw come out of the same run -- the first time all three exist together
for a controlled device state.
"""
import mmap
import os
import statistics as st
import subprocess
import sys
import threading
import time

L2 = "/mnt/nvme/experts.l2"
NSLOT = 17096
SLOT = 17547264
LANES = 16
TARGET = int(21 * 1000 ** 3)
SLOTS_TOTAL = TARGET // SLOT

PRECOND_GB = 40
PRECOND_PATH = "/mnt/nvme/precond.tmp"
HOST_SAMPLE = "/mnt/f/kimi-k3-in-c/reports/gateab_ab/v39_hostcounters"


def buf(n):
    return mmap.mmap(-1, n)


def read_once(burst_slots, pause_s, slots_total, seed):
    """LANES readers pulling whole slots; bursts of burst_slots with an optional pause."""
    fd = os.open(L2, os.O_RDONLY | os.O_DIRECT)
    try:
        bufs = [buf(SLOT) for _ in range(LANES)]
        per_lane = slots_total // LANES
        bursts = max(1, per_lane // burst_slots) if burst_slots else 1
        step = burst_slots or per_lane
        got = [0]

        def worker(i):
            s = (seed + i * 7) % NSLOT
            for _ in range(bursts):
                for _ in range(step):
                    if s >= NSLOT:
                        s -= NSLOT
                    os.preadv(fd, [bufs[i]], s * SLOT)
                    s = (s + 89) % NSLOT
                if pause_s:
                    time.sleep(pause_s)
            got[0] += step * bursts

        th = [threading.Thread(target=worker, args=(i,)) for i in range(LANES)]
        t0 = time.monotonic()
        for t in th:
            t.start()
        for t in th:
            t.join()
        w = time.monotonic() - t0
        for b in bufs:
            b.close()
        return got[0] * SLOT / w / 1e6
    finally:
        os.close(fd)


def precondition():
    """Overwrite the controller's cache with data that is not experts.l2.

    40 GB is chosen to be comfortably larger than any SLC cache plausible on a 512 GB
    server drive, while leaving 196 GB of free space untouched. O_DIRECT so the guest's page
    cache is not what gets written, and fsync before timing starts, so the NAND write has
    actually landed rather than sitting in a buffer.
    """
    nbytes = int(PRECOND_GB * 1000 ** 3)
    chunk = 32 * 1000 * 1000 * 1000
    print("   preconditioning: writing %g GB with O_DIRECT ..." % PRECOND_GB, flush=True)
    t0 = time.monotonic()
    fd = os.open(PRECOND_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_DIRECT, 0o644)
    try:
        # A fresh anonymous mmap is already zero-filled and the block layer skips holes, so
        # the file is sparse and the drive is not written at all. Write one aligned page
        # into each 1 MB stripe instead: os.write cannot carry a memoryview whose slices
        # straddle pages, but a single 4096-byte assignment at a page offset is fine, and
        # doing that every megabyte gives 40 GB of real, non-sparse writes.
        b = buf(chunk)
        pat = bytes(bytearray((i * 7 + 13) & 0xFF for i in range(4096)))
        off = 0
        while off < chunk:
            b[off:off + 4096] = pat
            off += 1000 * 1000
        written = 0
        view = memoryview(b)
        while written < nbytes:
            # Limit each write to what is left, or os.write takes the whole 32 GB buffer
            # in one call -- which silently overran the target in the smoke test.
            take = min(len(b), nbytes - written)
            n = os.write(fd, view[:take])
            written += n
        view.release()
    finally:
        os.close(fd)
    os.sync()
    el = time.monotonic() - t0
    print("   wrote %.1f GB in %.1f s (%.0f MB/s) -- cache should now hold this, not experts.l2"
          % (written / 1e9, el, written / el / 1e6), flush=True)


def host_sampler(stop, path):
    """Best-effort host counters. Runs in its own process; failure must not kill the run."""
    ps = (
        "$p=@('\\PhysicalDisk(2)\\% Idle Time','\\PhysicalDisk(2)\\Avg. Disk sec/Read',"
        "'\\PhysicalDisk(2)\\Current Disk Queue Length','\\PhysicalDisk(2)\\Disk Read Bytes/sec');"
        "$c=Get-Counter $p -SampleInterval 1 -MaxSamples 400;"
        "$c.CounterSamples|%{ '{0},{1},{2}' -f $_.TimeStamp.ToString('HH:mm:ss'),"
        "$_.Path.Split('\\')[-1],$_.CookedValue }"
    )
    try:
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "host.csv"), "w") as fh:
            fh.write("time,counter,value\n")
            subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps],
                           stdout=fh, stderr=subprocess.STDOUT, timeout=1800)
    except Exception as e:                      # noqa: BLE001
        with open(os.path.join(path, "host.err"), "w") as fh:
            fh.write(str(e) + "\n")


def main():
    print("geometry: nslot=%d slot_bytes=%d lanes=%d, %.2f GB per sample"
          % (NSLOT, SLOT, LANES, SLOTS_TOTAL * SLOT / 1e9))
    print("engine for comparison: 410 MB/s (phase-2, O_DIRECT, same unit)\n", flush=True)

    # --- COLD: after a long idle, the cache holds recent experts.l2 data ---
    print("[1/4] COLD sample (cache holds recent experts.l2 reads) ...", flush=True)
    cold = read_once(0, 0, SLOTS_TOTAL, 11)

    # --- precondition, then measure with NO idle gap ---
    print("[2/4] preconditioning the device cache ...", flush=True)
    precondition()

    stop = threading.Event()
    hs = threading.Thread(target=host_sampler, args=(stop, HOST_SAMPLE), daemon=True)
    hs.start()

    print("[3/4] POST samples, starting immediately after the write ...", flush=True)
    post, postp = [], []
    for k in range(5):
        post.append(read_once(0, 0, SLOTS_TOTAL, 211 * (k + 1)))
        postp.append(read_once(12, 1.0, SLOTS_TOTAL, 307 * (k + 1)))
        print("      sample %d/5: POST %6.0f   POST+1s %6.0f" % (k + 1, post[-1], postp[-1]),
              flush=True)

    stop.set()

    print("\n[4/4] results (MB/s)")
    def show(name, v):
        if not v:
            return
        med = st.median(v)
        q = st.quantiles(v, n=4) if len(v) > 1 else [med, med, med]
        iqr = (q[2] - q[0]) / med
        print("   %-14s n=%d  median %6.0f  min %6.0f  max %6.0f  IQR/med %.3f  %s"
              % (name, len(v), med, min(v), max(v), iqr, "NOISY" if iqr > 0.15 else "usable"))

    show("COLD", [cold])
    show("POST", post)
    show("POST+1s", postp)

    mp, mp1 = st.median(post), st.median(postp)
    print()
    print("   cache effect: COLD %.0f -> POST %.0f  (%.2fx)" % (cold, mp, cold / mp if mp else 0))
    print("   engine 410 MB/s is %.2fx the POST figure, %.2fx the POST+1s figure"
          % (mp / 410.0, mp1 / 410.0))
    print()
    if mp < 700:
        print("   -> the drive gives about what the engine gets once its cache is full.")
        print("      The >=2.7x gap is therefore NOT engine inefficiency: the engine was")
        print("      reading largely cache-resident data and the comparison was between")
        print("      two different physical processes.")
    else:
        print("   -> the drive still sustains well above the engine's 410 MB/s with a")
        print("      full cache, so the gap is real and lives in k3_cache / k3_l2cache.")
    print()
    print("   host counters: %s" % os.path.join(HOST_SAMPLE, "host.csv"))

    try:
        os.unlink(PRECOND_PATH)
        print("   removed %s" % PRECOND_PATH)
    except OSError:
        pass


if __name__ == "__main__":
    main()
