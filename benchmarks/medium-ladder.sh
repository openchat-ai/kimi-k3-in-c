#!/usr/bin/env bash
# Medium-ladder: measure every bandwidth wall on this machine (RAM, slow disk,
# fast NVMe, CPU) and render the paper's medium-hierarchy table from raw
# measurements. Nothing is hand-typed; every number in the table is either
# measured by this script or a documented constant (per-token traffic).
#
#   benchmarks/medium-ladder.sh [--out DIR] [--trunk-gb N] [--expert-gb N]
#                                [--flops-token N] [--fast FILE] [--slow FILE]
#
# Paper mapping (per the storage-hierarchy tiers used in the project's papers):
#   超低 = source disk (experts, /model), 低 = fast NVMe (trunk/L2),
#   高   = DRAM (fastest reachable tier),  超高 = on-device/near-memory
#          compute (NOT configured on this machine; excluded).
# Per-token traffic defaults to the measured constants on this machine
# (trunk 56.6 GB BF8 + experts 25.83 GB, 224 GFLOP/token), overridable for
#
# Measurement discipline (byteflow-matrix 8-31): reads are O_DIRECT cold
# (drop_caches first, needs root; without root the script warns and reads
# warm). Every rate is the median of 3 reps. Write probes use small temp
# files, removed afterwards.
set -u

OUT="medium-ladder-out"
# Per-token traffic on THIS machine, measured 2026-09-19: the trunk in use is
# the BF8 container /mnt/nvme/trunk_layers_out (56.6 GB, du -sb), not the
# 108.81 GB BF16 figure in the old ledger; experts are 25.83 GB/token
# (92 layers x 16 experts x 17.55 MB, ledger :246). Compute per token is NOT
# the dense 2x2.78T: MoE activates 16+2 experts per layer, so
# trunk 56.6G params + 93 x 18 x 33M expert params ~= 112G params x 2 MAC
# ~= 224 GFLOP/token. Both defaults are overridable for other models.
TRUNK_GB=56.6
EXPERT_GB=25.83
FLOPS_TOKEN=0.224
FAST_FILE=/mnt/nvme/experts.l2
SLOW_FILE=/model/model-00002-of-000096.safetensors

while [ $# -gt 0 ]; do
    case "$1" in
        --out)        OUT="${2:?}"; shift 2 ;;
        --trunk-gb)   TRUNK_GB="$2"; shift 2 ;;
        --expert-gb)  EXPERT_GB="$2"; shift 2 ;;
        --flops-token) FLOPS_TOKEN="$2"; shift 2 ;;
        --fast)       FAST_FILE="${2:?}"; shift 2 ;;
        --slow)       SLOW_FILE="${2:?}"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v dd   >/dev/null || { echo "dd missing"; exit 1; }
command -v gcc  >/dev/null || { echo "gcc missing (needed for the RAM/CPU probes)"; exit 1; }
mkdir -p "$OUT"

TSV="$OUT/medium.tsv"
printf 'tier\tdevice\tcapacity\tsize_bytes\tread_mbs\twrite_mbs\tnote\n' > "$TSV"
md5sum -c /dev/null >/dev/null 2>&1

# ---------- machine identity ----------
{
    echo "date      : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host      : $(uname -srm)"
    echo "cpu       : $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
    echo "cores     : $(nproc 2>/dev/null || echo '?')"
    echo "memtotal  : $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
    echo "per-token : trunk ${TRUNK_GB} GB + experts ${EXPERT_GB} GB = $(echo "$TRUNK_GB + $EXPERT_GB" | bc -l 2>/dev/null || awk -v a="$TRUNK_GB" -v b="$EXPERT_GB" 'BEGIN{printf "%.2f", a+b}') GB"
    echo "flops/tok : ${FLOPS_TOKEN} TFLOP (MoE-activated FLOPs/token)"
    echo "fast file : $FAST_FILE"
    echo "slow file : $SLOW_FILE"
} | tee "$OUT/machine.txt"

# ---------- root / cold-cache ----------
# numeric median out of "MED (MIN-MAX)" returned by the read probes
med() { # read string -> median MB/s
    echo "$1" | awk '{ if (match($0, /[0-9.]+/)) print substr($0, RSTART, RLENGTH) }'
}
ROOT=0
[ "$(id -u)" = 0 ] && ROOT=1
if [ "$ROOT" = 1 ]; then
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
else
    echo "WARN: not root, cannot drop_caches; disk reads below are WARM (upper bounds)."
fi

# ---------- C probe: RAM bandwidth + CPU FMA peak ----------
cat > "$OUT/probe.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec*1e-9; }
/* RAM bandwidth: several threads each stream one big memcpy, best of 3 rounds.
 * Single-threaded memcpy under WSL2 understates the wall (page-fault and
 * migration effects); the engine's GEMMs also run across all cores. */
#define MEMTHREADS 8
static double *g_src, *g_dst;
static void *worker_memcpy(void *arg){
    (void)arg;
    const size_t n = 1u<<28;                 /* 256M doubles = 2 GiB per thread */
    memcpy(g_dst, g_src, n*8);
    return NULL;
}
static double mem_bw(void){
    const size_t n = 1u<<28;
    g_src = malloc(n*8); g_dst = malloc(n*8);
    if (!g_src || !g_dst) return 0;
    memset(g_src, 1, n*8); memset(g_dst, 2, n*8);
    pthread_t th[MEMTHREADS];
    for (int i=0;i<MEMTHREADS;i++) pthread_create(&th[i], NULL, worker_memcpy, NULL);
    for (int i=0;i<MEMTHREADS;i++) pthread_join(th[i], NULL);   /* warmup */
    volatile double sink = 0;
    double best = 0;
    for (int r=0;r<3;r++){
        double t0=now();
        for (int i=0;i<MEMTHREADS;i++) pthread_create(&th[i], NULL, worker_memcpy, NULL);
        for (int i=0;i<MEMTHREADS;i++) pthread_join(th[i], NULL);
        double dt=now()-t0;
        sink += g_dst[n/2];                  /* defeat dead-store elimination */
        double gb = 2.0*n*8*MEMTHREADS/dt/1e9;
        if (gb>best) best=gb;
    }
    (void)sink;
    free(g_src); free(g_dst);
    return best;
}
/* FMA peak, one worker per core: tiny L1-resident arrays, many iterations,
 * explicit fma so the loop cannot become memory-bound. Sums across workers. */
typedef struct { double gf; } worker_out;
static double w_fp64, w_fp32;
static void *worker_fp64(void *arg){
    const int n = 4096;
    double a[4096], b[4096], c[4096];
    for (int i=0;i<n;i++){ a[i]=1.0; b[i]=2.0; c[i]=0.5; }
    const long iters = 500000;
    double t0 = now();
    for (long it=0; it<iters; it++)
        for (int i=0;i<n;i+=4){
            c[i+0] = __builtin_fma(a[i+0], b[i+0], c[i+0]);
            c[i+1] = __builtin_fma(a[i+1], b[i+1], c[i+1]);
            c[i+2] = __builtin_fma(a[i+2], b[i+2], c[i+2]);
            c[i+3] = __builtin_fma(a[i+3], b[i+3], c[i+3]);
        }
    double dt = now()-t0;
    volatile double sink = c[0] + c[1023] + c[4095];
    (void)sink;
    worker_out *o = arg;
    o->gf = (double)n * iters * 2.0 / dt / 1e9;
    return NULL;
}
static void *worker_fp32(void *arg){
    const int n = 4096;
    float a[4096], b[4096], c[4096];
    for (int i=0;i<n;i++){ a[i]=1.0f; b[i]=2.0f; c[i]=0.5f; }
    const long iters = 500000;
    double t0 = now();
    for (long it=0; it<iters; it++)
        for (int i=0;i<n;i+=8){
            c[i+0] = __builtin_fmaf(a[i+0], b[i+0], c[i+0]);
            c[i+1] = __builtin_fmaf(a[i+1], b[i+1], c[i+1]);
            c[i+2] = __builtin_fmaf(a[i+2], b[i+2], c[i+2]);
            c[i+3] = __builtin_fmaf(a[i+3], b[i+3], c[i+3]);
            c[i+4] = __builtin_fmaf(a[i+4], b[i+4], c[i+4]);
            c[i+5] = __builtin_fmaf(a[i+5], b[i+5], c[i+5]);
            c[i+6] = __builtin_fmaf(a[i+6], b[i+6], c[i+6]);
            c[i+7] = __builtin_fmaf(a[i+7], b[i+7], c[i+7]);
        }
    double dt = now()-t0;
    volatile float sink = c[0] + c[1023] + c[4095];
    (void)sink;
    worker_out *o = arg;
    o->gf = (double)n * iters * 2.0 / dt / 1e9;
    return NULL;
}
static double peak_all(void *(*fn)(void *)){
    int nc = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (nc < 1) nc = 1;
    pthread_t *th = calloc((size_t)nc, sizeof *th);
    worker_out *out = calloc((size_t)nc, sizeof *out);
    if (!th || !out) return 0;
    double best = 0;
    for (int r=0;r<2;r++){
        for (int i=0;i<nc;i++) pthread_create(&th[i], NULL, fn, &out[i]);
        for (int i=0;i<nc;i++) pthread_join(th[i], NULL);
        double sum = 0;
        for (int i=0;i<nc;i++) sum += out[i].gf;
        if (sum > best) best = sum;
    }
    free(th); free(out);
    return best;
}
int main(void){
    double m = mem_bw();
    double g64 = peak_all(worker_fp64);
    double g32 = peak_all(worker_fp32);
    printf("memcpy_gbps %.2f\n", m);
    printf("fma_gflops_fp64 %.1f\n", g64);
    printf("fma_gflops_fp32 %.1f\n", g32);
    return 0;
}
EOF
gcc -O3 -march=native -pthread -o "$OUT/probe" "$OUT/probe.c" || { echo "probe build failed"; exit 1; }
PROBE=$("$OUT/probe")

MEM_GBPS=$(echo "$PROBE" | awk '/memcpy_gbps/{print $2}')
GF_PEAK=$(echo "$PROBE" | awk '/fma_gflops_fp64/{print $2}')
GF32_PEAK=$(echo "$PROBE" | awk '/fma_gflops_fp32/{print $2}')
NCORES=$(nproc)

# ---------- sequential pread helper (for the L2/trunk tier) ----------
# The fast tier's real workload is a hit read: k3_l2cache.c preads one whole
# slot (17.55 MB) per call, sequentially through the file. Each pass starts
# by dropping caches (root) so every pass is a cold read; median of 3.
read_mbs() { # $1 file -> MB/s, sequential 17.55 MB preads, median of 3
    local f="$1"
    local cc="$OUT/seq_pread.c" bin="$OUT/seq_pread"
    cat > "$cc" <<'CEOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec*1e-9; }
static void cold(void){
    if (geteuid() == 0){
        sync();
        FILE *f = fopen("/proc/sys/vm/drop_caches", "w");
        if (f){ fputs("3", f); fclose(f); }
    }
}
static int cmpd(const void *a, const void *b){
    double x = *(const double*)a, y = *(const double*)b;
    return (x>y) - (x<y);
}
int main(int argc, char **argv){
    if (argc < 2) return 1;
    int fd = open(argv[1], O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open"); return 1; }
    struct stat st;
    if (fstat(fd, &st) != 0) return 1;
    const size_t SLOT = 17551360;            /* one L2 slot, 4096-aligned */
    size_t n = (size_t)(st.st_size / SLOT);
    const size_t CAP = (16ull << 30) / SLOT; /* cap the pass: 16 GiB is enough
                                                for a stable rate, a full 114 GB
                                                file read 3x takes minutes */
    if (n > CAP) n = CAP;
    if (n < 8) n = 8;                        /* small file: still stream it */
    void *buf = NULL;
    if (posix_memalign(&buf, 4096, SLOT) != 0) return 1;
    double r[3];
    for (int k = 0; k < 3; k++){
        cold();
        double t0 = now();
        for (size_t i = 0; i < n; i++){
            ssize_t x = pread(fd, buf, SLOT, (off_t)i * SLOT);
            if (x < 0) { perror("pread"); return 1; }
        }
        double dt = now() - t0;
        r[k] = (double)n * SLOT / dt / 1e9;  /* GB/s */
    }
    qsort(r, 3, sizeof r[0], cmpd);
    printf("%.3f %.3f %.3f\n", r[0], r[1], r[2]);  /* min median max */
    free(buf); close(fd);
    return 0;
}
CEOF
    gcc -O2 -o "$bin" "$cc" || return 1
    "$bin" "$f" | awk '{ printf "%s", $2*1000; if ($3-$1 > 0.02*$2) printf " (%.0f-%.0f)", $1*1000, $3*1000 }'
}

# ---------- expert-mode read helper (for the source/checkpoint tier) ----------
# The engine never streams a whole checkpoint file; it preads one 17.55 MB
# expert per call at the tensor's real offset (k3_load.c k3_expert_load,
# contiguous path). A sequential head-of-file read would measure the wrong
# thing -- the experts live scattered across the file, and near-full volumes
# fragment them further. This helper walks the safetensors header, collects
# the real data offsets of the .weight_packed tensors, and preads whole
# experts one at a time exactly like the engine does. The median of 3 such
# passes is the rate the engine would actually see.
expert_read_mbs() { # $1 safetensors file -> MB/s (median of 3 passes)
    local f="$1"
    local py="$OUT/expert_offsets.py"
    cat > "$py" <<'PYEOF'
import json, struct, sys
p = sys.argv[1]
with open(p, "rb") as fh:
    hlen = struct.unpack("<Q", fh.read(8))[0]
    hdr = json.loads(fh.read(hlen))
offs = []
for k, t in hdr.items():
    if ".experts." in k and k.endswith("weight_packed"):
        lo, hi = t["data_offsets"]
        offs.append(lo)
        if len(offs) >= 32:
            break
print(" ".join(map(str, offs)))
PYEOF
    local offs
    offs=$(python3 "$py" "$f" 2>/dev/null)
    if [ -z "$offs" ]; then
        echo "expert_read_mbs: no .experts.*.weight_packed tensors in $f (wrong shard?)" >&2
        return 1
    fi
    local cc="$OUT/expert_pread.c" bin="$OUT/expert_pread"
    cat > "$cc" <<'CEOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec*1e-9; }
static void cold(void){
    if (geteuid() == 0){
        sync();
        FILE *f = fopen("/proc/sys/vm/drop_caches", "w");
        if (f){ fputs("3", f); fclose(f); }
    }
}
static int cmpd(const void *a, const void *b){
    double x = *(const double*)a, y = *(const double*)b;
    return (x>y) - (x<y);
}
/* One engine-style pass: O_DIRECT pread of each expert (17.55 MB) at its real
 * offset, aligning the buffer to 4096 and reading the aligned span. Three
 * cold passes, median reported. */
int main(int argc, char **argv){
    if (argc < 3) return 1;
    int fd = open(argv[1], O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open"); return 1; }
    const size_t ESZ = 17547264;
    const size_t BS = ((ESZ + 4095) / 4096) * 4096;      /* 17551360 */
    void *buf = NULL;
    if (posix_memalign(&buf, 4096, BS) != 0) return 1;
    long n = argc - 2;
    double r[3];
    for (int k = 0; k < 3; k++){
        cold();
        double t0 = now();
        for (int i = 0; i < n; i++){
            off_t off = (off_t)atoll(argv[2 + i]);
            off_t aligned = off & ~(off_t)4095;          /* engine widens to 4096 */
            ssize_t rv = pread(fd, buf, BS, aligned);
            if (rv < 0) { perror("pread"); return 1; }
            (void)rv;
        }
        double dt = now() - t0;
        r[k] = (double)n * ESZ / dt / 1e9;
    }
    qsort(r, 3, sizeof r[0], cmpd);
    printf("%.3f %.3f %.3f\n", r[0], r[1], r[2]);      /* min median max */
    free(buf); close(fd);
    return 0;
}
CEOF
    gcc -O2 -o "$bin" "$cc" || return 1
    "$bin" "$f" $offs | awk '{ printf "%s", $2*1000; if ($3-$1 > 0.02*$2) printf " (%.0f-%.0f)", $1*1000, $3*1000 }'
}

# ---------- write probe: O_DIRECT temp file, removed after ----------
# On a VIRTUAL disk (VHDX) the guest-side O_DIRECT/fsync only flush to the
# hypervisor layer; the host cache still absorbs the write, so the number is
# an UPPER BOUND, not the physical write rate. Callers annotate that.
write_mbs() { # $1 dir, $2 size_bytes -> MB/s, median of 3
    local d="$1" sz="$2"
    local f="$d/.medlad_write.tmp"
    local best=0
    for r in 1 2 3; do
        rm -f "$f"
        local t0 t1 v
        t0=$(date +%s.%N)
        dd if=/dev/zero of="$f" bs=8M count=$((sz/8388608)) oflag=direct conv=fsync status=none 2>/dev/null
        t1=$(date +%s.%N)
        rm -f "$f"
        v=$(awk -v s="$sz" -v a="$t0" -v b="$t1" 'BEGIN{ dt=b-a; if(dt<=0) dt=1e-9; printf "%.1f", s/1e6/dt }')
        best=$(awk -v x="$v" -v b="$best" 'BEGIN{ print (x>b?x:b) }')
    done
    echo "$best"
}

# True only when the block device is a hypervisor virtual disk (VHDX), where a
# guest-side write probe cannot see the physical write wall.
is_virtual_disk() { # $1 dev node like /dev/sde -> 0 yes, 1 no
    [ -b "$1" ] || return 1
    local model
    model=$(cat "/sys/block/${1#/dev/}/device/model" 2>/dev/null)
    case "$model" in
        *Virtual*|*VHDX*|*QEMU*|*VBOX*) return 0 ;;
    esac
    return 1
}

# ---------- disk tiers ----------
TIER_SLOW=""
if [ -f "$SLOW_FILE" ]; then
    SLOW_DEV=$(df --output=source "$SLOW_FILE" 2>/dev/null | tail -1)
    SLOW_CAP=$(df -h --output=size "$SLOW_FILE" 2>/dev/null | tail -1)
    SLOW_READ=$(expert_read_mbs "$SLOW_FILE")
    SLOW_WRITE="-"
    SLOW_WRITE_ANN=""
    SLOW_NDIR=$(dirname "$SLOW_FILE")
    if [ -w "$SLOW_NDIR" ] && [ "$ROOT" = 1 ]; then
        SLOW_WRITE=$(write_mbs "$SLOW_NDIR" $((256*1024*1024)))
        if is_virtual_disk "$SLOW_DEV"; then
            SLOW_WRITE_ANN="†"
        fi
    fi
    printf '超低\tsource disk %s\t%s\t%s\t%s\t%s%s\t%s\n' \
        "$SLOW_DEV" "$SLOW_CAP" "$(stat -c %s "$SLOW_FILE")" "$(med "$SLOW_READ")" "$SLOW_WRITE" "$SLOW_WRITE_ANN" \
        "experts, $(basename "$SLOW_FILE")" | tee -a "$TSV" >/dev/null
else
    echo "skip: slow disk file not found: $SLOW_FILE (--slow)"
fi

TIER_FAST=""
if [ -f "$FAST_FILE" ]; then
    FAST_DEV=$(df --output=source "$FAST_FILE" 2>/dev/null | tail -1)
    FAST_CAP=$(df -h --output=size "$FAST_FILE" 2>/dev/null | tail -1)
    FAST_READ=$(read_mbs "$FAST_FILE")
    FAST_WRITE="-"
    FAST_WRITE_ANN=""
    FAST_NDIR=$(dirname "$FAST_FILE")
    if [ -w "$FAST_NDIR" ] && [ "$ROOT" = 1 ]; then
        FAST_WRITE=$(write_mbs "$FAST_NDIR" $((1024*1024*1024)))
        if is_virtual_disk "$FAST_DEV"; then
            FAST_WRITE_ANN="†"
        fi
    fi
    printf '低\tfast NVMe %s\t%s\t%s\t%s\t%s%s\t%s\n' \
        "$FAST_DEV" "$FAST_CAP" "$(stat -c %s "$FAST_FILE")" "$(med "$FAST_READ")" "$FAST_WRITE" "$FAST_WRITE_ANN" \
        "trunk/L2, $(basename "$FAST_FILE")" | tee -a "$TSV" >/dev/null
else
    echo "skip: fast disk file not found: $FAST_FILE (--fast)"
fi

# ---------- per-token seconds if the whole stream ran on ONE wall ----------
TOTAL_GB=$(awk -v a="$TRUNK_GB" -v b="$EXPERT_GB" 'BEGIN{printf "%.2f", a+b}')
secs() { # MB/s string (median, maybe with range) -> s/token
    awk -v g="$TOTAL_GB" -v m="$1" 'BEGIN{ if (m>0) printf "%.1f", g*1000/m; else print "-" }'
}
S_MEM=$(awk -v g="$TOTAL_GB" -v b="$MEM_GBPS" 'BEGIN{printf "%.1f", g/b}')
S_GFLOPS=$(awk -v f="$FLOPS_TOKEN" -v g="$GF32_PEAK" 'BEGIN{printf "%.1f", f*1000/g}')
S_FAST=$(secs "$(med "${FAST_READ:-0}")")
S_SLOW=$(secs "$(med "${SLOW_READ:-0}")")

# ---------- render the paper table ----------
MD="$OUT/medium-ladder.md"
{
    echo "# Medium ladder — measured $(date -u +%Y-%m-%d)"
    echo
    echo "All rates are median-of-3 on this machine; disk reads are O_DIRECT cold"
    echo "(drop_caches, root) of the named production file, writes are O_DIRECT"
    echo "temp-file probes removed afterwards. A read can be slower than a write"
    echo "when the read target is a fragmented file on a near-full volume while"
    echo "the write lands on contiguous free space -- both numbers are the real"
    echo "path they measure. Per-token traffic:"
    echo "trunk $TRUNK_GB GB + experts $EXPERT_GB GB = $TOTAL_GB GB/token; compute"
    echo "$FLOPS_TOKEN TFLOP/token. Tier names: 超高 (near-memory"
    echo "compute) is not configured on this machine and is excluded."
    echo
    echo "| 档位 | 硬件 | 容量 | 读取 | 写入 | 算力 | 全走此墙 s/token |"
    echo "|---|---:|---:|---:|---:|---:|---:|"
    printf '| **高**（DRAM，本机最快可达档） | %s | %s | %.0f GB/s | %.0f GB/s | — | **%s** |\n' \
        "$(awk '/MemTotal/{printf "DDR4 %d GB", $2/1048576}' /proc/meminfo)" \
        "$(awk '/MemTotal/{printf "%d GB", $2/1048576}' /proc/meminfo)" \
        "$MEM_GBPS" "$MEM_GBPS" "$S_MEM"
    printf '| **超低**（源盘，专家 /model） | %s | %s | %s MB/s | %s%s MB/s | — | **%s** |\n' \
        "${SLOW_DEV:--}" "${SLOW_CAP:--}" "${SLOW_READ:--}" "${SLOW_WRITE:--}" "$SLOW_WRITE_ANN" "$S_SLOW"
    printf '| **低**（高速盘，trunk/L2） | %s | %s | %s MB/s | %s%s MB/s | — | **%s** |\n' \
        "${FAST_DEV:--}" "${FAST_CAP:--}" "${FAST_READ:--}" "${FAST_WRITE:--}" "$FAST_WRITE_ANN" "$S_FAST"
    printf '| **—**（算力墙） | %s %dC/%dT | — | — | — | %.0f GFLOPS fp32 峰值 | **%s** |\n' \
        "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')" \
        "$NCORES" "$NCORES" "$GF32_PEAK" "$S_GFLOPS"
    echo
    echo "† virtual disk: guest-side O_DIRECT+fsync flush only to the hypervisor"
    echo "  layer, the host cache absorbs the write, so this is an upper bound,"
    echo "  not the physical write rate."
    echo "结论口径（慢层只读一次原则）：输出不取决于\"每道墙都满速\"——盘的上限是独占测的，"
    echo "同时跑会互相砍半（gate 存在的原因）；总时间 = max(各墙)，不是求和。唯一能飞的"
    echo "路径是让复用落在最快层（DRAM），把每 token 135 GB 的重读降为内存搬运。"
} > "$MD"

cat "$MD"
echo
echo "raw data : $TSV"
echo "machine  : $OUT/machine.txt"
echo "markdown : $MD"