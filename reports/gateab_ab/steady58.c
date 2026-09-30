/* steady58.c -- the mixed-workload ceiling: trunk and experts, concurrently, sustained.
 *
 * Why this exists. steady47 (run as v49_paired/dev1-3) measured the engine's expert read
 * shape alone and held 2463-2797 MB/s for 210 s, against the engine's own 439 MB/s hit-I/O
 * ledger. That 6x is not an engine-versus-device gap, because the engine never runs the
 * expert stream by itself: k3_run streams the trunk on its reader thread while the expert
 * getmany runs on the main thread, so the device always serves both. v49 alternated a device
 * arm that had the drive to itself with an engine arm that shared it with the trunk stream,
 * which is the same mismatch steady47's own header complained about, one level up.
 *
 * probe_coldc did run both arms together, but over a 55 s cold window, short enough that the
 * burst-versus-steady-state objection applies to it too. So the mixed ceiling has never been
 * measured over a window the engine's own run length.
 *
 * Design. Two arms on one device, both O_DIRECT, both continuous, no pauses and no
 * per-segment interleaving:
 *
 *   expert arm: NTH lanes walking random 17547264-byte slots of the L2 file by a stride
 *               coprime with the slot count -- byte-identical to what steady47 did, so the
 *               two stay comparable.
 *   trunk arm:  one lane reading whole trunk layer files in order, the way the engine's
 *               reader thread does (it takes each layer as <=2 huge preads).
 *
 * Reported per segment: each arm's rate and the aggregate, plus the cumulative aggregate.
 * The engine reference is configurable because it differs between runs; the point is the
 * aggregate against the engine's aggregate, both measured with the trunk stream present.
 *
 * Unlike steady47's reporter, the cumulative column is bytes-so-far over seconds-so-far.
 * steady47 printed the last segment's bytes over cumulative time, so its "running MB/s"
 * column decayed while the real trajectory held; reading that column as a decay was reading
 * a display bug.
 *
 * Self-test: --selftest builds a small geometry under $TMPDIR, runs both arms against it
 * through this same code path, and checks that both arms advanced, that no read came up
 * short, that the rates are positive, and that the stride-coprime validator rejects a
 * non-coprime geometry. The runner tees the output, so a failure keeps its evidence.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static const char *L2 = "/mnt/nvme/experts.l2";
static const char *TRUNK_DIR = "/mnt/nvme/trunk_layers_out";
static long SLOT = 17547264;
static long NSLOT = 14589;
static int NTH = 11;
static int NLAYER = 93;
static long STRIDE = 89;
static double SEG_S = 20.0;
static double ENG_MBPS = 0.0;          /* engine aggregate to compare against, 0 = none */
static int g_odirect = 1;

static volatile int g_stop;
static volatile int g_short_exp, g_short_trunk;
static long g_counts[16];              /* expert slots completed per lane */
static long g_trunk_bytes;             /* trunk bytes completed */

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static long gcd(long a, long b) { while (b) { long t = a % b; a = b; b = t; } return a; }
static long page_size(void) { long p = sysconf(_SC_PAGESIZE); return p > 0 ? p : 4096; }
static long round_up(long v, long m) { return (v + m - 1) / m * m; }

static void die(const char *what)
{
    fprintf(stderr, "%s: %s\n", what, strerror(errno));
    exit(1);
}

static void *xmalloc(size_t n)
{
    void *p = malloc(n);
    if (!p) die("malloc");
    return p;
}

static void *xmmap_anon(size_t n)
{
    void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) die("mmap");
    return p;
}

/* O_DIRECT where the filesystem supports it (every real run here is NVMe). tmpfs and sdcardfs
 * refuse it, which is what the self-test runs on, so fall back to buffered and say so rather
 * than reporting a number from a different access mode than it claims. */
static int open_rd(const char *path)
{
    int fd = open(path, O_RDONLY | (g_odirect ? O_DIRECT : 0));
    if (fd < 0 && g_odirect && (errno == EINVAL || errno == ENOTSUP)) {
        fprintf(stderr, "note: %s does not support O_DIRECT, using buffered reads\n", path);
        g_odirect = 0;
        fd = open(path, O_RDONLY);
    }
    return fd;
}

/* Returns 0 if the geometry can produce meaningful numbers, -1 with a reason otherwise.
 * Does not exit, so the self-test can assert on the rejection path. */
static int validate_geometry(char *err, size_t errn)
{
    struct stat s;
    long page = page_size();
    if (NTH < 1 || NTH > 16) { snprintf(err, errn, "bad lane count %d", NTH); return -1; }
    if (SLOT <= 0 || SLOT % page) { snprintf(err, errn, "slot %ld not page aligned", SLOT); return -1; }
    if (NSLOT <= 0) { snprintf(err, errn, "bad slot count %ld", NSLOT); return -1; }
    if (stat(L2, &s) != 0) { snprintf(err, errn, "stat %s: %s", L2, strerror(errno)); return -1; }
    long n = (long)s.st_size / SLOT;
    if (n != NSLOT) { snprintf(err, errn, "%s holds %ld slots, want %ld", L2, n, NSLOT); return -1; }
    if (gcd(STRIDE, NSLOT) != 1) {
        snprintf(err, errn, "stride %ld is not coprime with slot count %ld", STRIDE, NSLOT);
        return -1;
    }
    /* A stride that walks past the last slot makes every later read return 0, which is what
     * killed the first run of the predecessor probe after one thread's worth of reads. */
    {
        long p = 0;
        for (long i = 0; i < NSLOT; i++) { p += STRIDE; while (p >= NSLOT) p -= NSLOT; }
        if (p != 0) { snprintf(err, errn, "stride orbit does not close (%ld)", p); return -1; }
    }
    if (NLAYER <= 0) { snprintf(err, errn, "bad layer count %d", NLAYER); return -1; }
    for (int i = 0; i < NLAYER; i++) {
        char path[1024];
        snprintf(path, sizeof path, "%s/layer_%03d.bin", TRUNK_DIR, i);
        if (stat(path, &s) != 0) { snprintf(err, errn, "stat %s: %s", path, strerror(errno)); return -1; }
        if ((long)s.st_size <= 0 || (long)s.st_size % page) {
            snprintf(err, errn, "layer %d is %lld bytes, not a page multiple", i, (long long)s.st_size);
            return -1;
        }
    }
    return 0;
}

static void check_geometry_or_die(void)
{
    char err[512];
    if (validate_geometry(err, sizeof err) != 0) {
        fprintf(stderr, "geometry: %s\n", err);
        exit(1);
    }
}

/* ---------------- expert arm: scattered slots, NTH lanes ---------------- */

typedef struct { int fd; long base; void *buf; int idx; } EArg;

static void *exp_lane(void *p)
{
    EArg *a = (EArg *)p;
    long s = a->base, done = 0;
    while (!g_stop) {
        ssize_t n = pread(a->fd, a->buf, (size_t)SLOT, (off_t)s * SLOT);
        if (n != SLOT) {
            if (g_short_exp < 5)
                fprintf(stderr, "SHORT exp lane=%d done=%ld slot=%ld n=%zd errno=%d %s\n",
                        a->idx, done, s, n, errno, n < 0 ? strerror(errno) : "(no error: past EOF)");
            g_short_exp++;
            break;
        }
        s += STRIDE;
        while (s >= NSLOT) s -= NSLOT;
        done++;
        if ((done & 0x3F) == 0)
            __atomic_store_n(&g_counts[a->idx], done, __ATOMIC_RELAXED);
    }
    __atomic_store_n(&g_counts[a->idx], done, __ATOMIC_RELAXED);
    return NULL;
}

/* ---------------- trunk arm: whole layers in order, one lane ---------------- */

typedef struct { const char *dir; void *buf; size_t cap; } TArg;

static void *trunk_lane(void *p)
{
    TArg *a = (TArg *)p;
    char path[1024];
    while (!g_stop) {
        for (int i = 0; i < NLAYER && !g_stop; i++) {
            snprintf(path, sizeof path, "%s/layer_%03d.bin", a->dir, i);
            int fd = open_rd(path);
            if (fd < 0) {
                if (g_short_trunk < 5)
                    fprintf(stderr, "SHORT trunk open %s: %s\n", path, strerror(errno));
                g_short_trunk++;
                continue;
            }
            struct stat s;
            if (fstat(fd, &s) != 0 || (size_t)s.st_size > a->cap) {
                if (g_short_trunk < 5) fprintf(stderr, "SHORT trunk stat %s\n", path);
                g_short_trunk++;
                close(fd);
                continue;
            }
            ssize_t n = pread(fd, a->buf, (size_t)s.st_size, 0);
            close(fd);
            if (n != s.st_size) {
                if (g_short_trunk < 5)
                    fprintf(stderr, "SHORT trunk %s n=%zd want=%lld\n", path, n, (long long)s.st_size);
                g_short_trunk++;
                continue;
            }
            __atomic_add_fetch(&g_trunk_bytes, (long)n, __ATOMIC_RELAXED);
        }
    }
    return NULL;
}

/* ---------------- the mixed run, shared by production and the self-test ---------------- */

typedef struct {
    double wall;
    long exp_slots;
    long exp_bytes;
    long trunk_bytes;
    int short_exp, short_trunk;
} MixedResult;

static MixedResult run_mix(double run_s)
{
    check_geometry_or_die();

    int xfd = open_rd(L2);
    if (xfd < 0) die("open L2");

    size_t ecap = round_up(SLOT, page_size());
    size_t tcap = 0;
    long tmax = 0;
    for (int i = 0; i < NLAYER; i++) {
        char path[1024];
        snprintf(path, sizeof path, "%s/layer_%03d.bin", TRUNK_DIR, i);
        struct stat s;
        if (stat(path, &s) != 0) die("stat trunk layer");
        if ((long)s.st_size > tmax) tmax = (long)s.st_size;
    }
    tcap = round_up(tmax ? tmax : 1, page_size());

    pthread_t eth[16], tth;
    EArg eargs[16];
    for (int i = 0; i < NTH; i++) {
        eargs[i].fd = xfd;
        eargs[i].base = (long)((i * 137) % NSLOT);
        eargs[i].buf = xmmap_anon(ecap);
        eargs[i].idx = i;
    }
    TArg targ = { TRUNK_DIR, xmmap_anon(tcap), tcap };

    for (int i = 0; i < NTH; i++) pthread_create(&eth[i], NULL, exp_lane, &eargs[i]);
    pthread_create(&tth, NULL, trunk_lane, &targ);

    printf("geometry: nslot=%ld slot=%ld, %d expert lanes + 1 trunk lane, both continuous,"
           " target %.0f s, O_DIRECT=%d\n", NSLOT, SLOT, NTH, run_s, g_odirect);
    if (ENG_MBPS > 0) printf("engine aggregate for comparison: %.0f MB/s\n", ENG_MBPS);
    printf("  %6s %12s %12s %12s %12s\n", "t(s)", "trunk MB/s", "expert MB/s", "agg MB/s", "cum agg");
    fflush(stdout);

    long prev_slots = 0, prev_trunk = 0;
    double t0 = now_s(), seg0 = t0;
    for (;;) {
        sleep(1);
        double t = now_s() - t0;
        if (t >= run_s || g_short_exp || g_short_trunk) break;
        if (t - (seg0 - t0) >= SEG_S) {
            long slots = 0;
            for (int i = 0; i < NTH; i++) slots += __atomic_load_n(&g_counts[i], __ATOMIC_RELAXED);
            long tb = __atomic_load_n(&g_trunk_bytes, __ATOMIC_RELAXED);
            double dt = t - (seg0 - t0);
            double eseg = (double)(slots - prev_slots) * SLOT / 1e6;
            double tseg = (double)(tb - prev_trunk) / 1e6;
            double cum = ((double)slots * SLOT + (double)tb) / 1e6 / t;
            printf("  %6.0f %12.0f %12.0f %12.0f %12.0f\n",
                   t, tseg / dt, eseg / dt, (tseg + eseg) / dt, cum);
            fflush(stdout);
            prev_slots = slots;
            prev_trunk = tb;
            seg0 = now_s();
        }
    }
    g_stop = 1;
    for (int i = 0; i < NTH; i++) pthread_join(eth[i], NULL);
    pthread_join(tth, NULL);

    MixedResult r;
    r.wall = now_s() - t0;
    r.exp_slots = 0;
    for (int i = 0; i < NTH; i++) r.exp_slots += __atomic_load_n(&g_counts[i], __ATOMIC_RELAXED);
    r.exp_bytes = r.exp_slots * SLOT;
    r.trunk_bytes = __atomic_load_n(&g_trunk_bytes, __ATOMIC_RELAXED);
    r.short_exp = g_short_exp;
    r.short_trunk = g_short_trunk;

    double agg = (r.exp_bytes + (double)r.trunk_bytes) / 1e6 / r.wall;
    printf("\n=== whole run\n");
    printf("   expert  %ld slots, %.1f GB in %.1f s = %.0f MB/s\n",
           r.exp_slots, r.exp_bytes / 1e9, r.wall, (double)r.exp_bytes / 1e6 / r.wall);
    printf("   trunk   %.1f GB in %.1f s = %.0f MB/s\n",
           r.trunk_bytes / 1e9, r.wall, (double)r.trunk_bytes / 1e6 / r.wall);
    printf("   aggregate %.1f GB = %.0f MB/s\n", (r.exp_bytes + (double)r.trunk_bytes) / 1e9, agg);
    if (ENG_MBPS > 0) printf("   engine %.0f MB/s -> ratio %.2fx\n", ENG_MBPS, agg / ENG_MBPS);
    if (r.short_exp || r.short_trunk)
        printf("   ABORTED: short reads (expert %d, trunk %d)\n", r.short_exp, r.short_trunk);

    for (int i = 0; i < NTH; i++) munmap(eargs[i].buf, ecap);
    munmap(targ.buf, tcap);
    close(xfd);
    return r;
}

/* ---------------- self-test ---------------- */

static int failures;

static void check(int cond, const char *what)
{
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    } else {
        fprintf(stdout, "  ok    %s\n", what);
    }
}

static void build_selftest_geometry(void)
{
    L2 = "experts.l2";
    TRUNK_DIR = "trunk";
    SLOT = 1 << 20;      /* 1 MB slots, page aligned */
    NSLOT = 64;
    NTH = 4;
    NLAYER = 3;
    STRIDE = 17;         /* coprime with 64 */
    SEG_S = 1.0;

    int fd = open(L2, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) die("create L2");
    char *buf = xmalloc((size_t)SLOT);
    for (long i = 0; i < SLOT; i++) buf[i] = (char)(i * 7 + 1);
    for (long s = 0; s < NSLOT; s++)
        if (write(fd, buf, (size_t)SLOT) != SLOT) die("write L2 slot");
    close(fd);

    mkdir(TRUNK_DIR, 0700);
    for (int i = 0; i < NLAYER; i++) {
        char path[256];
        snprintf(path, sizeof path, "%s/layer_%03d.bin", TRUNK_DIR, i);
        fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) die("create trunk layer");
        for (int j = 0; j < 4; j++)
            if (write(fd, buf, (size_t)SLOT) != SLOT) die("write trunk layer");
        close(fd);
    }
    free(buf);
}

int main(int argc, char **argv)
{
    int selftest = 0;
    const char *env;
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--selftest")) selftest = 1;
    if ((env = getenv("K3P_L2"))) L2 = env;
    if ((env = getenv("K3P_TRUNK"))) TRUNK_DIR = env;
    if ((env = getenv("K3P_SLOT"))) SLOT = atol(env);
    if ((env = getenv("K3P_NSLOT"))) NSLOT = atol(env);
    if ((env = getenv("K3P_NTH"))) NTH = atoi(env);
    if ((env = getenv("K3P_NLAYER"))) NLAYER = atoi(env);
    if ((env = getenv("K3P_STRIDE"))) STRIDE = atol(env);
    if ((env = getenv("K3P_SEG"))) SEG_S = atof(env);
    if ((env = getenv("K3P_ENGINE_MBPS"))) ENG_MBPS = atof(env);

    if (selftest) {
        const char *tmp = getenv("TMPDIR");
        char dir[512];
        snprintf(dir, sizeof dir, "%s/steady58_selftest", (tmp && *tmp) ? tmp : ".");
        mkdir(dir, 0700);
        if (chdir(dir) != 0) die("chdir selftest dir");
        build_selftest_geometry();

        printf("== steady58 self-test: both arms through the production code path\n");
        MixedResult r = run_mix(3.0);
        check(r.short_exp == 0, "no short expert reads");
        check(r.short_trunk == 0, "no short trunk reads");
        check(r.exp_slots > 0, "expert arm advanced");
        check(r.trunk_bytes > 0, "trunk arm advanced");
        check((double)r.exp_bytes / 1e6 / r.wall > 0.0, "expert rate positive");
        check((double)r.trunk_bytes / 1e6 / r.wall > 0.0, "trunk rate positive");
        check(r.wall >= 3.0, "ran the requested window");

        /* The validator must reject a non-coprime stride: production would otherwise walk off
         * the end of the file and read zeros forever. */
        {
            char err[256];
            long good = STRIDE;
            STRIDE = 2;                       /* gcd(2, 64) = 2 */
            int rc = validate_geometry(err, sizeof err);
            check(rc != 0 && strstr(err, "coprime") != NULL,
                  "geometry validator rejects a non-coprime stride");
            STRIDE = good;
            rc = validate_geometry(err, sizeof err);
            check(rc == 0, "geometry validator accepts the real stride again");
        }

        printf("\n%s (%d failures)\n", failures ? "SELFTEST FAILED" : "SELFTEST OK", failures);
        return failures ? 1 : 0;
    }

    double run_s = (argc > 1) ? atof(argv[1]) : 210.0;
    MixedResult r = run_mix(run_s);
    return (r.short_exp || r.short_trunk) ? 1 : 0;
}