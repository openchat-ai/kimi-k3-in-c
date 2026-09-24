#!/usr/bin/env python3
# probe_cold2.py — cold re-measure of both single lanes (drop_caches between), O_DIRECT, buffers warmed.
# Settles whether the earlier 2593 MB/s "expert alone" was page-cache contamination.
import mmap, os, random, sys, time

sys.stdout.reconfigure(line_buffering=True)

EXP_L2 = "/mnt/nvme/experts.l2"
TRUNK_DIR = "/mnt/nvme/trunk_layers_out"
ESZ = 17547264
BS = ((ESZ + 4095) // 4096) * 4096
NEXP = 736
NTHR = 16
ALIGN = 4096

def now(): return time.monotonic()

def cold():
    os.system("sync")
    with open("/proc/sys/vm/drop_caches", "w") as f: f.write("3")

def report(tag, gb, dt):
    print(f"  {tag:26s} {gb:7.2f} GB  {dt:7.2f} s  {gb*1000.0/dt:7.0f} MB/s", flush=True)

def expert_par(off, fd, mvb):
    import threading
    done = []
    def w(base):
        for i in range(base, len(off), NTHR):
            os.preadv(fd, [mvb[:BS]], off[i])
        done.append(1)
    ts = [threading.Thread(target=w, args=(t,)) for t in range(NTHR)]
    for t in ts: t.start()
    for t in ts: t.join()

def trunk_seq(sizes, mvb):
    for (path, sz) in sizes:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
        try:
            os.preadv(fd, [mvb[:sz]], 0)
        finally:
            os.close(fd)

tl = [(f"{TRUNK_DIR}/layer_{i:03d}.bin", os.path.getsize(f"{TRUNK_DIR}/layer_{i:03d}.bin")) for i in range(93)]
off = None
random.seed(7)
span = os.path.getsize(EXP_L2) // BS
off = [random.randrange(span) * BS for _ in range(NEXP)]

xfd = os.open(EXP_L2, os.O_RDONLY | os.O_DIRECT)
try:
    mvb_e = memoryview(aligned(BS))
    mvb_t = memoryview(aligned(max(sz for _, sz in tl)))
    print("warm ...", end=" ", flush=True)
    trunk_seq(tl, mvb_t)
    expert_par(off, xfd, mvb_e)
    print("done", flush=True)

    cold()
    t0 = now(); trunk_seq(tl, mvb_t); report("trunk cold", sum(sz for _, sz in tl)/1e9, now()-t0)

    cold()
    t0 = now(); expert_par(off, xfd, mvb_e); report("expert cold (16thr)", NEXP*ESZ/1e9, now()-t0)
finally:
    os.close(xfd)
print("done2", flush=True)