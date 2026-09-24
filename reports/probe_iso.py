#!/usr/bin/env python3
import os, sys, time

F = "/mnt/nvme/experts.l2"
CH = 16 * 1024 * 1024
sys.stdout.reconfigure(line_buffering=True)
print("t0 dircache/stat")
t = time.time()
print("stat ok %.2fs" % (time.time() - t), flush=True)

fd = os.open(F, os.O_RDONLY)
buf = bytearray(CH)
mv = memoryview(buf)

t = time.time()
n = os.preadv(fd, [mv], 0)
print("pread1 16MiB: %.3fs (%d bytes)" % (time.time() - t, n), flush=True)

t = time.time()
n = os.preadv(fd, [mv], 12345 * CH)
print("pread2 16MiB @12e3: %.3fs" % (time.time() - t), flush=True)

print("drop_caches...", flush=True)
t = time.time()
os.system("sync; echo 3 > /proc/sys/vm/drop_caches")
print("drop_caches done %.3fs" % (time.time() - t), flush=True)

t = time.time()
n = os.preadv(fd, [mv], 999 * CH)
print("pread3 16MiB cold @999: %.3fs" % (time.time() - t), flush=True)

t0 = time.time()
for i in range(100):
    os.preadv(fd, [mv], (i * 9773) % 3000 * CH)
print("100 cold preads: %.2fs" % (time.time() - t0), flush=True)
os.close(fd)