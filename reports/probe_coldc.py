#!/usr/bin/env python3
# probe_coldc.py — cold concurrent: same session, drop_caches between, all O_DIRECT, buffers warmed.
# Orders: trunk single cold -> expert single cold -> trunk+expert concurrent cold.
# Same-session ordering removes the inter-session device-state drift (trunk 0.90 vs 1.44) that
# broke cross-run comparison; this decides whether the ~1.6 GB/s aggregate premise survives cold.
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

def aligned(size):
    return mmap.mmap(-1, (size + ALIGN - 1) & ~(ALIGN - 1))

def cold():
    os.system("sync")
    with open("/proc/sys/vm/drop_caches", "w") as f: f.write("3")

def report(tag, gb, dt):
    print(f"  {tag:28s} {gb:7.2f} GB  {dt:7.2f} s  {gb*1000.0/dt:7.0f} MB/s", flush=True)

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

def concurrent(sizes, mvb_t, off, fd, mvb_e):
    import threading
    tt = threading.Thread(target=trunk_seq, args=(sizes, mvb_t))
    te = threading.Thread(target=expert_par, args=(off, fd, mvb_e))
    t0 = now()
    tt.start(); te.start(); tt.join(); te.join()
    dt = now() - t0
    report("concurrent trunk+expert (cold)", (sum(sz for _, sz in sizes) + NEXP*ESZ)/1e9, dt)

tl = [(f"{TRUNK_DIR}/layer_{i:03d}.bin", os.path.getsize(f"{TRUNK_DIR}/layer_{i:03d}.bin")) for i in range(93)]
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
    t0 = now(); trunk_seq(tl, mvb_t); report("trunk single (cold)", sum(sz for _, sz in tl)/1e9, now()-t0)

    cold()
    t0 = now(); expert_par(off, xfd, mvb_e); report("expert single (cold)", NEXP*ESZ/1e9, now()-t0)

    cold()
    concurrent(tl, mvb_t, off, xfd, mvb_e)
finally:
    os.close(xfd)
print("done2", flush=True)