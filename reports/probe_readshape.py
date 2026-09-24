#!/usr/bin/env python3
import os, random, sys, time, threading

sys.stdout.reconfigure(line_buffering=True)
F = "/mnt/nvme/experts.l2"
CH = 16 * 1024 * 1024          # 16 MiB read unit (expert slot is ~17.5MB; shape gate)
NCH = os.path.getsize(F) // CH  # ~15258 chunk slots over 256GB

def run_pattern(name, offs):
    fd = os.open(F, os.O_RDONLY)
    buf = bytearray(CH)
    mv = memoryview(buf)
    n = len(offs)
    done = [0]
    t0 = time.perf_counter()
    def worker(idxs):
        for i in idxs:
            os.preadv(fd, [mv], offs[i] * CH)
            done[0] += 1
    if name == "16thr-rand":          # simulate current phase2 dynamic schedule
        work = [off for off in offs]  # arrival order
        nw = 16
        idxs = [[] for _ in range(nw)]
        for k, o in enumerate(work):
            idxs[k % nw].append(k)    # round-robin similar to dynamic schedule
        threads = [threading.Thread(target=worker, args=(idxs[w],)) for w in range(nw)]
    elif name == "1thr-sorted":        # lever hypothesis: single thread, offset-sorted
        threads = [threading.Thread(target=worker, args=([k for k in range(n)],))]
    else:                              # name == "seq"
        threads = [threading.Thread(target=worker, args=([k for k in range(n)],))]
    for t in threads: t.start()
    for t in threads: t.join()
    dt = time.perf_counter() - t0
    gb = done[0] * CH / 1e9
    os.close(fd)
    print("  %-14s %6d chunks  %8.2f GB  %7.2f s  %6.0f MB/s" % (name, done[0], gb, dt, gb / dt * 1000))
    return gb, dt

def main():
    n = 1800                                       # ~28.1GB per dataset
    random.seed(7)
    a = random.sample(range(0,      NCH // 2), n)  # A: spans first half (0..128GB)
    b = random.sample(range(NCH // 2, NCH), n)     # B: spans second half (128..256GB)
    b.sort()
    print("shape probe on %s (%d chunks of %d MiB) cold page cache" % (F, n, CH//(1024*1024)))
    res = {}
    os.system("sync; echo 3 > /proc/sys/vm/drop_caches")
    res["16thr-rand"] = run_pattern("16thr-rand", a)
    os.system("sync; echo 3 > /proc/sys/vm/drop_caches")
    res["1thr-sorted"] = run_pattern("1thr-sorted", b)
    os.system("sync; echo 3 > /proc/sys/vm/drop_caches")
    res["seq"] = run_pattern("seq", list(range(96 * 1024 * 1024 * 1024 // CH, (96 + 28) * 1024 * 1024 * 1024 // CH)))
    base = res["16thr-rand"][0] / res["16thr-rand"][1]
    for k, (gb, dt) in res.items():
        r = gb / dt
        print("  %-14s -> %6.0f MB/s   %+.2fx vs 16thr-rand" % (k, r * 1000, r / base))
    return 0

main()