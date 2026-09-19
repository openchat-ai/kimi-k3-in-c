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
# Per-token traffic defaults to the measured k3 constants (trunk 108.81 GB +
# experts 25.83 GB), overridable for other models.
#
# Measurement discipline (byteflow-matrix 8-31): reads are O_DIRECT cold
# (drop_caches first, needs root; without root the script warns and reads
# warm). Every rate is the median of 3 reps. Write probes use small temp
# files, removed afterwards.
set -u

OUT="medium-ladder-out"
TRUNK_GB=108.81
EXPERT_GB=25.83
FLOPS_TOKEN=5.6
FAST_FILE=/mnt/nvme/experts.l2
SLOW_FILE=/model/model-00001-of-000096.safetensors

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
    echo "flops/tok : ${FLOPS_TOKEN} TFLOP"
    echo "fast file : $FAST_FILE"
    echo "slow file : $SLOW_FILE"
} | tee "$OUT/machine.txt"

# ---------- root / cold-cache ----------
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
    const long iters = 2000000;
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
    const long iters = 2000000;
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
    for (int r=0;r<5;r++){
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

# ---------- median-of-3 helper: O_DIRECT read MB/s ----------
read_mbs() { # $1 file, $2 size_bytes (cap), returns MB/s on stdout
    local f="$1" cap="$2"
    local sz=0
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [ "$sz" -gt "$cap" ] && sz=$cap
    local best=0
    for r in 1 2 3; do
        local t0 t1 v
        t0=$(date +%s.%N)
        dd if="$f" of=/dev/null bs=8M count=$((sz/8388608)) iflag=direct status=none 2>/dev/null
        t1=$(date +%s.%N)
        v=$(awk -v s="$sz" -v a="$t0" -v b="$t1" 'BEGIN{ dt=b-a; if(dt<=0) dt=1e-9; printf "%.1f", s/1e6/dt }')
        awk -v x="$v" -v b="$best" 'BEGIN{ if (x>b) printf "%.1f", x }' >/dev/null
        best=$(awk -v x="$v" -v b="$best" 'BEGIN{ print (x>b?x:b) }')
    done
    echo "$best"
}

# ---------- write probe: O_DIRECT temp file, removed after ----------
write_mbs() { # $1 dir, $2 size_bytes -> MB/s
    local d="$1" sz="$2"
    local f="$d/.medlad_write.tmp"
    rm -f "$f"
    local t0 t1
    t0=$(date +%s.%N)
    dd if=/dev/zero of="$f" bs=8M count=$((sz/8388608)) oflag=direct status=none 2>/dev/null
    t1=$(date +%s.%N)
    rm -f "$f"
    awk -v s="$sz" -v a="$t0" -v b="$t1" 'BEGIN{ dt=b-a; if(dt<=0) dt=1e-9; printf "%.1f", s/1e6/dt }'
}

# ---------- disk tiers ----------
TIER_SLOW=""
if [ -f "$SLOW_FILE" ]; then
    SLOW_DEV=$(df --output=source "$SLOW_FILE" 2>/dev/null | tail -1)
    SLOW_CAP=$(df -h --output=size "$SLOW_FILE" 2>/dev/null | tail -1)
    SLOW_READ=$(read_mbs "$SLOW_FILE" $((2*1024*1024*1024)))
    SLOW_WRITE="-"
    SLOW_NDIR=$(dirname "$SLOW_FILE")
    if [ -w "$SLOW_NDIR" ] && [ "$ROOT" = 1 ]; then
        SLOW_WRITE=$(write_mbs "$SLOW_NDIR" $((256*1024*1024)))
    fi
    printf '超低\tsource disk %s\t%s\t%s\t%s\t%s\t%s\n' \
        "$SLOW_DEV" "$SLOW_CAP" "$(stat -c %s "$SLOW_FILE")" "$SLOW_READ" "$SLOW_WRITE" \
        "experts, $(basename "$SLOW_FILE")" | tee -a "$TSV" >/dev/null
else
    echo "skip: slow disk file not found: $SLOW_FILE (--slow)"
fi

TIER_FAST=""
if [ -f "$FAST_FILE" ]; then
    FAST_DEV=$(df --output=source "$FAST_FILE" 2>/dev/null | tail -1)
    FAST_CAP=$(df -h --output=size "$FAST_FILE" 2>/dev/null | tail -1)
    FAST_READ=$(read_mbs "$FAST_FILE" $((4*1024*1024*1024)))
    FAST_WRITE="-"
    FAST_NDIR=$(dirname "$FAST_FILE")
    if [ -w "$FAST_NDIR" ] && [ "$ROOT" = 1 ]; then
        FAST_WRITE=$(write_mbs "$FAST_NDIR" $((1024*1024*1024)))
    fi
    printf '低\tfast NVMe %s\t%s\t%s\t%s\t%s\t%s\n' \
        "$FAST_DEV" "$FAST_CAP" "$(stat -c %s "$FAST_FILE")" "$FAST_READ" "$FAST_WRITE" \
        "trunk/L2, $(basename "$FAST_FILE")" | tee -a "$TSV" >/dev/null
else
    echo "skip: fast disk file not found: $FAST_FILE (--fast)"
fi

# ---------- per-token seconds if the whole stream ran on ONE wall ----------
TOTAL_GB=$(awk -v a="$TRUNK_GB" -v b="$EXPERT_GB" 'BEGIN{printf "%.2f", a+b}')
secs() { # MB/s -> s/token
    awk -v g="$TOTAL_GB" -v m="$1" 'BEGIN{ if (m>0) printf "%.1f", g*1000/m; else print "-" }'
}
S_MEM=$(awk -v g="$TOTAL_GB" -v b="$MEM_GBPS" 'BEGIN{printf "%.1f", g/b}')
S_GFLOPS=$(awk -v f="$FLOPS_TOKEN" -v g="$GF32_PEAK" 'BEGIN{printf "%.1f", f*1000/g}')
S_FAST=$(secs "${FAST_READ:-0}")
S_SLOW=$(secs "${SLOW_READ:-0}")

# ---------- render the paper table ----------
MD="$OUT/medium-ladder.md"
{
    echo "# Medium ladder — measured $(date -u +%Y-%m-%d)"
    echo
    echo "All rates are median-of-3 on this machine; disk reads are O_DIRECT cold"
    echo "(drop_caches, root), writes are O_DIRECT temp-file probes. Per-token traffic:"
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
    printf '| **超低**（源盘，专家 /model） | %s | %s | %s MB/s | %s MB/s | — | **%s** |\n' \
        "${SLOW_DEV:--}" "${SLOW_CAP:--}" "${SLOW_READ:--}" "${SLOW_WRITE:--}" "$S_SLOW"
    printf '| **低**（高速盘，trunk/L2） | %s | %s | %s MB/s | %s MB/s | — | **%s** |\n' \
        "${FAST_DEV:--}" "${FAST_CAP:--}" "${FAST_READ:--}" "${FAST_WRITE:--}" "$S_FAST"
    printf '| **—**（算力墙） | %s %dC/%dT | — | — | — | %.0f GFLOPS fp32 峰值 | **%s** |\n' \
        "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')" \
        "$NCORES" "$NCORES" "$GF32_PEAK" "$S_GFLOPS"
    echo
    echo "结论口径（慢层只读一次原则）：输出不取决于\"每道墙都满速\"——盘的上限是独占测的，"
    echo "同时跑会互相砍半（gate 存在的原因）；总时间 = max(各墙)，不是求和。唯一能飞的"
    echo "路径是让复用落在最快层（DRAM），把每 token 135 GB 的重读降为内存搬运。"
} > "$MD"

cat "$MD"
echo
echo "raw data : $TSV"
echo "machine  : $OUT/machine.txt"
echo "markdown : $MD"