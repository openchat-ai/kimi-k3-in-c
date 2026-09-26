#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>

#ifndef O_DIRECT
#define O_DIRECT 040000
#endif

#define TRUNK_DIR "/mnt/nvme/trunk_layers_out"
#define EXPERT_L2 "/mnt/nvme/experts.l2"
#define N_SLOTS   14589
#define CHUNK     (1u << 20)

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static long long fsize(const char *p)
{
    struct stat st;
    if (stat(p, &st)) return -1;
    return st.st_size;
}

static void shuffle(long *a, int n)
{
    for (int i = n - 1; i > 0; i--) {
        int j = rand() % (i + 1);
        long t = a[i]; a[i] = a[j]; a[j] = t;
    }
}

/* ---------- S1/S2: sequential trunk read, buffered or O_DIRECT ---------- */
static void run_seq(int direct, long long target)
{
    char *buf = NULL;
    if (posix_memalign((void **)&buf, 4096, CHUNK)) { puts("malloc fail"); return; }
    long long got = 0;
    double t0 = now_s();
    DIR *d = opendir(TRUNK_DIR);
    if (!d) { puts("opendir fail"); return; }
    struct dirent *e;
    while (got < target && (e = readdir(d))) {
        if (strncmp(e->d_name, "layer_", 6) || !strstr(e->d_name, ".bin"))
            continue;
        char path[512];
        snprintf(path, sizeof path, "%s/%s", TRUNK_DIR, e->d_name);
        int fd = open(path, O_RDONLY | (direct ? O_DIRECT : 0));
        if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); continue; }
        long long remain = target - got, done = 0;
        while (done < remain) {
            size_t want = (remain - done) < CHUNK ? (size_t)(remain - done) : CHUNK;
            want &= ~(size_t)511u; /* O_DIRECT alignment */
            if (!want) break;
            ssize_t n = read(fd, buf, want);
            if (n <= 0) break;
            done += n;
        }
        got += done;
        close(fd);
    }
    closedir(d);
    double dt = now_s() - t0;
    printf("RESULT seq direct=%d bytes=%lld dt=%.2fs mbps=%.1f\n",
           direct, got, dt, (dt > 0 ? got / 1048576.0 / dt : 0));
    free(buf);
}

/* ---------- S3: random 17.5MB slot pread across experts.l2 ---------- */
static long g_slotseq[N_SLOTS];
static int g_slotcount, g_slotidx, g_slot_direct;
static long g_slotlen;

static void *slot_worker(void *arg)
{
    long long *bytes = (long long *)arg;
    char *buf = NULL;
    posix_memalign((void **)&buf, 4096, g_slotlen);
    int fd = open(EXPERT_L2, O_RDONLY | (g_slot_direct ? O_DIRECT : 0));
    if (fd < 0) { fprintf(stderr, "open l2: %s\n", strerror(errno)); return NULL; }
    for (;;) {
        int idx = __atomic_fetch_add(&g_slotidx, 1, __ATOMIC_RELAXED);
        if (idx >= g_slotcount) break;
        off_t off = (off_t)g_slotseq[idx] * g_slotlen;
        ssize_t n = pread(fd, buf, g_slotlen, off);
        if (n <= 0) { fprintf(stderr, "pread off=%lld: %s\n", (long long)off, strerror(errno)); break; }
        *bytes += n;
    }
    close(fd);
    free(buf);
    return NULL;
}

static void run_rndslot(int direct, int total_slots, int nthr)
{
    long long file = fsize(EXPERT_L2);
    if (file < 0) { puts("no experts.l2"); return; }
    long sl = file / N_SLOTS;
    sl &= ~511L;
    g_slotlen = sl;
    g_slot_direct = direct;
    for (int i = 0; i < N_SLOTS; i++) g_slotseq[i] = i;
    shuffle(g_slotseq, N_SLOTS);
    g_slotcount = total_slots;
    g_slotidx = 0;
    pthread_t th[64];
    long long bytes[64] = {0};
    double t0 = now_s();
    for (int i = 0; i < nthr; i++) pthread_create(&th[i], NULL, slot_worker, &bytes[i]);
    for (int i = 0; i < nthr; i++) pthread_join(th[i], NULL);
    double dt = now_s() - t0;
    long long tot = 0;
    for (int i = 0; i < nthr; i++) tot += bytes[i];
    printf("RESULT rndslot direct=%d slots=%d nthr=%d bytes=%lld dt=%.2fs mbps=%.1f\n",
           direct, total_slots, nthr, tot, dt, (dt > 0 ? tot / 1048576.0 / dt : 0));
}

/* ---------- S2MT: multi-thread sequential read (queue depth) ---------- */
static long long g_seqmt_target;
static int g_seqmt_nthr, g_seqmt_direct;
static long long g_seqmt_bytes[64];

static void *seqmt_worker(void *arg)
{
    long long *bytes = &g_seqmt_bytes[(intptr_t)arg];
    long long mid = g_seqmt_target / g_seqmt_nthr;
    long long start = (long long)(intptr_t)arg * mid;
    long long file = fsize(EXPERT_L2);
    if (start >= file) return NULL;
    long long end = start + mid;
    if (end > file) end = file;
    char *buf = NULL;
    posix_memalign((void **)&buf, 4096, CHUNK);
    int fd = open(EXPERT_L2, O_RDONLY | (g_seqmt_direct ? O_DIRECT : 0));
    if (fd < 0) return NULL;
    long long off = start, done = 0;
    while (off + done < end) {
        long long want = end - (off + done);
        size_t w = want < CHUNK ? (size_t)want : CHUNK;
        w &= ~(size_t)511u;
        if (!w) break;
        ssize_t n = pread(fd, buf, w, off + done);
        if (n <= 0) break;
        done += n;
    }
    *bytes = done;
    close(fd);
    free(buf);
    return NULL;
}

static void run_seqmt(int direct, long long target, int nthr)
{
    g_seqmt_target = target;
    g_seqmt_nthr = nthr;
    g_seqmt_direct = direct;
    pthread_t th[64];
    double t0 = now_s();
    for (int i = 0; i < nthr; i++) {
        g_seqmt_bytes[i] = 0;
        pthread_create(&th[i], NULL, seqmt_worker, (void *)(intptr_t)i);
    }
    for (int i = 0; i < nthr; i++) pthread_join(th[i], NULL);
    double dt = now_s() - t0;
    long long tot = 0;
    for (int i = 0; i < nthr; i++) tot += g_seqmt_bytes[i];
    if (*g_seqmt_bytes + 1 == 0) tot = 0; /* unreachable; keep parser flow */
    printf("RESULT seqmt direct=%d nthr=%d bytes=%lld dt=%.2fs mbps=%.1f\n",
           direct, nthr, tot, dt, (dt > 0 ? tot / 1048576.0 / dt : 0));
}

/* ---------- S4: random 4KB preads ---------- */
static int g_n4k, g_nthr4k, g_4kidx;
static long long g_4klimit;

static void *rnd4k_worker(void *arg)
{
    long long *bytes = (long long *)arg;
    char *buf[4];
    for (int i = 0; i < 4; i++) if (posix_memalign((void **)&buf[i], 4096, 4096)) return NULL;
    int fds[4];
    for (int i = 0; i < 4; i++) fds[i] = open(EXPERT_L2, O_RDONLY | O_DIRECT);
    unsigned int seed = time(NULL) ^ (unsigned long)arg;
    for (;;) {
        int idx = __atomic_fetch_add(&g_4kidx, 1, __ATOMIC_RELAXED);
        if (idx >= g_n4k) break;
        long long r = (long long)rand_r(&seed);
        off_t off = (off_t)((g_4klimit - 4096) * ((double)r / (RAND_MAX + 1.0)));
        off &= ~4095LL;
        ssize_t n = pread(fds[idx & 3], buf[idx & 3], 4096, off);
        if (n <= 0) break;
        *bytes += n;
    }
    for (int i = 0; i < 4; i++) close(fds[i]);
    return NULL;
}

static void run_rnd4k(int nreads, int nthr)
{
    long long file = fsize(EXPERT_L2);
    g_4klimit = file;
    g_n4k = nreads;
    g_nthr4k = nthr;
    g_4kidx = 0;
    pthread_t th[64];
    long long bytes[64] = {0};
    double t0 = now_s();
    for (int i = 0; i < nthr; i++) pthread_create(&th[i], NULL, rnd4k_worker, &bytes[i]);
    for (int i = 0; i < nthr; i++) pthread_join(th[i], NULL);
    double dt = now_s() - t0;
    long long tot = 0;
    for (int i = 0; i < nthr; i++) tot += bytes[i];
    printf("RESULT rnd4k reads=%d nthr=%d bytes=%lld dt=%.2fs iops=%.0f mbps=%.1f\n",
           nreads, nthr, tot, dt, (dt > 0 ? nreads / dt : 0),
           (dt > 0 ? tot / 1048576.0 / dt : 0));
}

/* ---------- S5: mix - 1 sequential trunk reader + 16 rndslot readers ---------- */
static pthread_mutex_t g_mixshuf_mu = PTHREAD_MUTEX_INITIALIZER;
static long g_mixseq[1024];
static int g_mixseqn;

typedef struct {
    int kind; /* 0=seq,1=slot */
    long long target;
    long long bytes;
} mix_job;

static int g_mix_seq_direct, g_mix_rnd_direct;

static void *mix_worker(void *arg)
{
    mix_job *j = (mix_job *)arg;
    j->bytes = 0;
    if (j->kind == 0) {
        char *buf = NULL;
        posix_memalign((void **)&buf, 4096, CHUNK);
        long long got = 0, target = j->target;
        DIR *d = opendir(TRUNK_DIR);
        struct dirent *e;
        while (got < target && (e = readdir(d))) {
            if (strncmp(e->d_name, "layer_", 6) || !strstr(e->d_name, ".bin")) continue;
            char path[512];
            snprintf(path, sizeof path, "%s/%s", TRUNK_DIR, e->d_name);
            int fd = open(path, O_RDONLY | (g_mix_seq_direct ? O_DIRECT : 0));
            if (fd < 0) continue;
            long long remain = target - got, done = 0;
            while (done < remain) {
                size_t want = (remain - done) < CHUNK ? (size_t)(remain - done) : CHUNK;
                want &= ~(size_t)511u;
                if (!want) break;
                ssize_t n = read(fd, buf, want);
                if (n <= 0) break;
                done += n;
            }
            got += done;
            close(fd);
        }
        closedir(d);
        j->bytes = got;
    }
    return NULL;
}

static void *mix_slot_worker(void *arg)
{
    long long *bytes = (long long *)arg;
    char *buf = NULL;
    posix_memalign((void **)&buf, 4096, g_slotlen);
    int fd = open(EXPERT_L2, O_RDONLY | (g_slot_direct ? O_DIRECT : 0));
    if (fd < 0) return NULL;
    for (;;) {
        int idx = __atomic_fetch_add(&g_slotidx, 1, __ATOMIC_RELAXED);
        if (idx >= g_slotcount) break;
        off_t off = (off_t)g_slotseq[idx] * g_slotlen;
        ssize_t n = pread(fd, buf, g_slotlen, off);
        if (n <= 0) break;
        *bytes += n;
    }
    close(fd);
    free(buf);
    return NULL;
}

static void run_mix(long long seq_target, int seq_direct, int total_slots, int rnd_direct)
{
    long long file = fsize(EXPERT_L2);
    long sl = file / N_SLOTS;
    sl &= ~511L;
    g_slotlen = sl;
    g_slot_direct = rnd_direct;
    g_mix_seq_direct = seq_direct;
    for (int i = 0; i < N_SLOTS; i++) g_slotseq[i] = i;
    shuffle(g_slotseq, N_SLOTS);
    g_slotcount = total_slots;
    g_slotidx = 0;

    pthread_t ts, tr[16];
    long long slotbytes[16] = {0};
    double t0 = now_s();
    mix_job sj = {0, seq_target, 0};
    pthread_create(&ts, NULL, mix_worker, &sj);
    for (int i = 0; i < 16; i++) pthread_create(&tr[i], NULL, mix_slot_worker, &slotbytes[i]);
    pthread_join(ts, NULL);
    for (int i = 0; i < 16; i++) pthread_join(tr[i], NULL);
    double dt = now_s() - t0;
    long long st = sj.bytes, rt = 0;
    for (int i = 0; i < 16; i++) rt += slotbytes[i];
    printf("RESULT mix seq_bytes=%lld rnd_bytes=%lld dt=%.2fs seq_mbps=%.1f rnd_mbps=%.1f agg_mbps=%.1f\n",
           st, rt, dt,
           (dt > 0 ? st / 1048576.0 / dt : 0),
           (dt > 0 ? rt / 1048576.0 / dt : 0),
           (dt > 0 ? (st + rt) / 1048576.0 / dt : 0));
}

/* ---------- S6: engwave - engine-shaped wave reads with compute-gap pauses ----------
 * The engine reads expert L2 in per-layer waves (spw slots, nthr parallel preads) and
 * then COMPUTES the layer with no I/O in flight. This probe replays that shape so we can
 * quantify how much bandwidth the inter-wave gap destroys (gap_ms). mbps_wall includes
 * the gaps (the engine's effective expert rate); mbps_read is the busy-phase rate only. */
static long long g_eng_bytes[64];

static void *eng_wave_worker(void *arg)
{
    long long *bytes = (long long *)arg;
    char *buf = NULL;
    if (posix_memalign((void **)&buf, 4096, g_slotlen)) return NULL;
    int fd = open(EXPERT_L2, O_RDONLY | O_DIRECT);
    if (fd < 0) { fprintf(stderr, "open l2: %s\n", strerror(errno)); return NULL; }
    long long done = 0;
    for (;;) {
        int idx = __atomic_fetch_add(&g_slotidx, 1, __ATOMIC_RELAXED);
        if (idx >= g_slotcount) break;
        off_t off = (off_t)g_slotseq[idx] * g_slotlen;
        ssize_t n = pread(fd, buf, g_slotlen, off);
        if (n <= 0) { fprintf(stderr, "pread off=%lld: %s\n", (long long)off, strerror(errno)); break; }
        done += n;
    }
    close(fd);
    free(buf);
    *bytes = done;
    return NULL;
}

static void run_engwave(int nthr, int spw, int gap_ms, int nwaves)
{
    long long file = fsize(EXPERT_L2);
    if (file < 0) { puts("no experts.l2"); return; }
    long sl = file / N_SLOTS;
    sl &= ~511L;
    g_slotlen = sl;
    g_slot_direct = 1;
    for (int i = 0; i < N_SLOTS; i++) g_slotseq[i] = i;
    shuffle(g_slotseq, N_SLOTS);
    pthread_t th[64];
    double t0 = now_s(), t_read = 0.0;
    long long tot = 0;
    for (int w = 0; w < nwaves; w++) {
        g_slotidx = w * spw;
        g_slotcount = g_slotidx + spw;
        double tw = now_s();
        for (int i = 0; i < nthr; i++) {
            g_eng_bytes[i] = 0;
            pthread_create(&th[i], NULL, eng_wave_worker, &g_eng_bytes[i]);
        }
        for (int i = 0; i < nthr; i++) pthread_join(th[i], NULL);
        t_read += now_s() - tw;
        for (int i = 0; i < nthr; i++) tot += g_eng_bytes[i];
        if (w + 1 < nwaves && gap_ms > 0) usleep((useconds_t)gap_ms * 1000);
    }
    double dt = now_s() - t0;
    printf("RESULT engwave nthr=%d spw=%d gap_ms=%d nwaves=%d bytes=%lld dt=%.2fs mbps_wall=%.1f mbps_read=%.1f\n",
           nthr, spw, gap_ms, nwaves, tot, dt,
           (dt > 0 ? tot / 1048576.0 / dt : 0),
           (t_read > 0 ? tot / 1048576.0 / t_read : 0));
}

int main(int argc, char **argv)
{
    srand(12345);
    if (argc >= 3 && !strcmp(argv[1], "seq")) {
        run_seq(atoi(argv[2]), atoll(argv[3]));
    } else if (argc >= 5 && !strcmp(argv[1], "seqmt")) {
        run_seqmt(atoi(argv[2]), atoll(argv[3]), atoi(argv[4]));
    } else if (argc >= 5 && !strcmp(argv[1], "rndslot")) {
        run_rndslot(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    } else if (argc >= 5 && !strcmp(argv[1], "rnd4k")) {
        run_rnd4k(atoi(argv[3]), atoi(argv[4]));
    } else if (argc >= 6 && !strcmp(argv[1], "mix")) {
        run_mix(atoll(argv[2]), atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
    } else if (argc >= 6 && !strcmp(argv[1], "engwave")) {
        run_engwave(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
    } else {
        printf("usage:\n  %s seq <direct> <target_bytes>\n  %s seqmt <direct> <target_bytes> <nthr>\n  %s rndslot <direct> <nslots> <nthr>\n  %s rnd4k <ignored> <nreads> <nthr>\n  %s mix <seq_bytes> <seq_direct> <nslots> <rnd_direct>\n  %s engwave <nthr> <spw> <gap_ms> <nwaves>\n", argv[0], argv[0], argv[0], argv[0], argv[0], argv[0]);
        return 1;
    }
    return 0;
}