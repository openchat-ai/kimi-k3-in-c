#!/usr/bin/env python3
# probe_duallane.py — isolate trunk-lane vs expert-lane vs concurrent aggregate
# Device: same SINKER NVMe (sdd7) that trunks+experts both live on.
# Q: does the engine's "~1.6 GB/s aggregate" premise hold, and does a flat packed
#    trunk (1682 MB/s single-lane in the old expert-starved era) matter today?
# Patterns:
#   trunk-lane  : 1 thread, O_DIRECT-style aligned preadv whole layer_%03d.bin in order
#                 (engine reads each layer as <=2 huge preads, chunk 2GB-4k),
#                 one full pass over 93 layers = ~56.6 GB.
#   expert-lane : 16 threads, random 17.55 MB pread spans (aligned 4096) across experts.l2,
#                 736 reads ~ 12.9 GB, the token-equivalent working set.
# Runs (each cold): trunk alone, expert alone, trunk+expert concurrent.
import mmap, os, random, sys, time

sys.stdout.reconfigure(line_buffering=True)

EXP_L2 = "/mnt/nvme/experts.l2"
TRUNK_DIR = "/mnt/nvme/trunk_layers_out"
ESZ = 17547264
BS = ((ESZ + 4095) // 4096) * 4096   # 17551360, O_DIRECT-safe span
NEXP = 736
NTHR = 16
ALIGN = 4096

def now(): return time.monotonic()

def cold():
    os.system("sync")
    with open("/proc/sys/vm/drop_caches", "w") as f: f.write("3")

def aligned(size):
    buf = mmap.mmap(-1, (size + ALIGN - 1) & ~(ALIGN - 1))
    return buf

def expert_offsets(n, filesize):
    random.seed(7)
    span = filesize // BS
    return [((random.randrange(span)) * BS) for _ in range(n)]

def run_expert_par(off, fd, mvb):
    import threading
    done = []
    def w(base):
        for i in range(base, len(off), NTHR):
            os.preadv(fd, [mvb[:BS]], off[i])
        done.append(1)
    ts = [threading.Thread(target=w, args=(t,)) for t in range(NTHR)]
    for t in ts: t.start()
    for t in ts: t.join()

def run_trunk(sizes, mvb):
    for (path, sz) in sizes:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
        try:
            os.preadv(fd, [mvb[:sz]], 0)
        finally:
            os.close(fd)

def report(tag, gb, dt):
    print(f"  {tag:24s} {gb:7.2f} GB  {dt:7.2f} s  {gb*1000.0/dt:7.0f} MB/s", flush=True)

# layout
tl = [(f"{TRUNK_DIR}/layer_{i:03d}.bin", os.path.getsize(f"{TRUNK_DIR}/layer_{i:03d}.bin")) for i in range(93)]
exfs = os.path.getsize(EXP_L2)
off = expert_offsets(NEXP, exfs)
xfd = os.open(EXP_L2, os.O_RDONLY | os.O_DIRECT)
eval_buf = aligned(BS)
maxsz = max(sz for _, sz in tl)
buf = aligned(maxsz)
mvb_t = memoryview(buf)
mvb_e = memoryview(eval_buf)

print(f"shape probe on {EXP_L2} + {TRUNK_DIR} (trunk {sum(sz for _,sz in tl)/1e9:.1f} GB, expert lane {NEXP*ESZ/1e9:.1f} GB, both O_DIRECT, buffers warmed)", flush=True)

print("warming buffers ...", end=" ", flush=True)
run_trunk(tl, mvb_t)
run_expert_par(off, xfd, mvb_e)
print("done", flush=True)

t0 = now(); run_trunk(tl, mvb_t); report("trunk-lane alone", sum(sz for _, sz in tl)/1e9, now()-t0)

t0 = now(); run_expert_par(off, xfd, mvb_e); report("expert-lane alone (16thr)", NEXP*ESZ/1e9, now()-t0)

import threading
t0 = now()
tt = threading.Thread(target=run_trunk, args=(tl, mvb_t))
te = threading.Thread(target=run_expert_par, args=(off, xfd, mvb_e))
tt.start(); te.start(); tt.join(); te.join()
report("concurrent trunk+expert", (sum(sz for _, sz in tl) + NEXP*ESZ)/1e9, now()-t0)

os.close(xfd)
print("done", flush=True)