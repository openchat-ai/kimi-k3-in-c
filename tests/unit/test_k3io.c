#include "k3_io.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>

#define NFAIL_MAX 32
static int nfail = 0;
static void check(int cond, const char *what)
{
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        if (nfail < NFAIL_MAX) nfail++;
    }
}

/* 1. basic cross-tier read, chunked span, short span */
static void test_basic(int *fd, unsigned char *data)
{
    K3IO io;
    const int workers[2] = { 4, 1 };
    k3_io_init(&io, 2, workers);

    unsigned char buf[8192];
    memset(buf, 0, sizeof buf);
    /* chunked: read 0..4096 in 1024-byte chunks, one completion */
    K3IOReq *q = k3_io_submit(&io, 0, fd[0], 0, 4096, 1024, buf);
    check(q != NULL, "submit basic");
    ssize_t r = k3_io_wait(q);
    check(r == 4096, "chunked span returns full length");
    check(memcmp(buf, data, 4096) == 0, "chunked span bytes");

    /* single pread on tier 1 */
    q = k3_io_submit(&io, 1, fd[0], 4096, 1024, 0, buf);
    check(q != NULL, "submit tier1");
    r = k3_io_wait(q);
    check(r == 1024, "tier1 read length");
    check(memcmp(buf, data + 4096, 1024) == 0, "tier1 bytes");

    k3_io_free(&io);
}

/* 2. write path: pwrite through the scheduler, then read it back */
static void test_write(void)
{
    const char *p = "/tmp/k3io_w.bin";
    int fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0600);
    check(fd >= 0, "write file open");

    K3IO io;
    const int workers[2] = { 4, 1 };
    k3_io_init(&io, 2, workers);

    unsigned char src[2048], back[2048];
    for (int i = 0; i < 2048; i++) src[i] = (unsigned char)(i * 7);
    K3IOReq *q = k3_io_submit_write(&io, 0, fd, 0, 2048, src);
    check(q != NULL, "submit write");
    ssize_t r = k3_io_wait(q);
    check(r == 2048, "write length");

    q = k3_io_submit(&io, 0, fd, 0, 2048, 0, back);
    check(q != NULL, "read back");
    r = k3_io_wait(q);
    check(r == 2048, "read back length");
    check(memcmp(back, src, 2048) == 0, "write/read roundtrip");

    k3_io_free(&io);
    close(fd);
    unlink(p);
}

/* 3. many threads submit concurrently, engine-style (16 getmany threads) */
#define NCONC 16
static K3IO *g_io;
static int  g_fd;
static int  g_fail;
static void *conc_main(void *arg)
{
    long i = (long)arg;
    unsigned char buf[1024];
    /* staggered offsets so each thread reads a distinct region */
    K3IOReq *q = k3_io_submit(g_io, i % 2, g_fd, i * 1024, 1024, 0, buf);
    if (!q) { g_fail = 1; return NULL; }
    ssize_t r = k3_io_wait(q);
    if (r != 1024) g_fail = 1;
    if (buf[0] != (unsigned char)(i * 1024 & 0xFF)) g_fail = 1;
    return NULL;
}
static void test_concurrent(int *fd, unsigned char *data)
{
    K3IO io;
    const int workers[2] = { 16, 1 };
    k3_io_init(&io, 2, workers);
    g_io = &io; g_fd = fd[0]; g_fail = 0;

    pthread_t th[NCONC];
    for (long i = 0; i < NCONC; i++) pthread_create(&th[i], NULL, conc_main, (void *)i);
    for (int i = 0; i < NCONC; i++) pthread_join(th[i], NULL);
    check(g_fail == 0, "concurrent submits all correct");
    (void)data;
    k3_io_free(&io);
}

/* 4. worker count clamped to [1, K3_IO_MAX_WORKERS] without overflow */
static void test_clamp(void)
{
    K3IO io;
    const int workers[2] = { 0, 9999 };
    k3_io_init(&io, 2, workers);
    check(io.nworkers[0] == 1, "clamp low");
    check(io.nworkers[1] == K3_IO_MAX_WORKERS, "clamp high");
    k3_io_free(&io);
}

/* 5. group scheduling: workers drain every non-empty group round-robin, so no group
 *    starves while another owns the queue. k3_io_set_active/active_group[] are gone;
 *    the old rule that parked group 0 while group 1 was active was the v5_l2g1
 *    deadlock (group-1 requests queued behind a group nobody selected) and the
 *    no-overlap bug (a single active group serialised trunk vs L2). */
static void test_groups(int *fd, unsigned char *data)
{
    K3IO io;
    const int workers[2] = { 2, 1 };
    k3_io_init(&io, 2, workers);

    /* pure group-1 burst: this is the v5 deadlock shape -- only group 1 has work. */
    enum { NT = 4 };
    unsigned char *buf1[NT];
    K3IOReq *q1[NT];
    for (int i = 0; i < NT; i++) {
        buf1[i] = malloc(1024);
        memset(buf1[i], 0, 1024);
        q1[i] = k3_io_submit_g(&io, 0, 1, fd[0], (off_t)i * 1024, 1024, 0, buf1[i]);
        check(q1[i] != NULL, "submit group1 only");
    }
    for (int i = 0; i < NT; i++) {
        ssize_t r = k3_io_wait(q1[i]);
        check(r == 1024, "group1-only read length");
        check(memcmp(buf1[i], data + i * 1024, 1024) == 0, "group1-only bytes");
        free(buf1[i]);
    }

    /* mixed group-0 + group-1: both streams must be served, neither may starve. */
    unsigned char *buf[2][NT];
    K3IOReq *q[2][NT];
    for (int g = 0; g < 2; g++)
        for (int i = 0; i < NT; i++) {
            buf[g][i] = malloc(1024);
            memset(buf[g][i], 0, 1024);
            /* all group-0 requests first, then all group-1: the round-robin scan
             * must still reach group 1 while group 0 stays non-empty. */
            q[g][i] = k3_io_submit_g(&io, 0, g, fd[0], (off_t)(i * 1024), 1024, 0, buf[g][i]);
            check(q[g][i] != NULL, "mixed submit");
        }
    for (int g = 0; g < 2; g++)
        for (int i = 0; i < NT; i++) {
            ssize_t r = k3_io_wait(q[g][i]);
            check(r == 1024, "mixed read length");
            check(memcmp(buf[g][i], data + i * 1024, 1024) == 0, "mixed bytes");
            free(buf[g][i]);
        }

    k3_io_free(&io);
}

int main(void)
{
    const char *p = "/tmp/k3io_test.bin";
    enum { FSIZE = NCONC * 1024 };
    unsigned char *data = malloc(FSIZE);
    for (int i = 0; i < FSIZE; i++) data[i] = (unsigned char)(i & 0xFF);
    int fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { perror("open"); return 1; }
    check(write(fd, data, FSIZE) == FSIZE, "seed file");
    close(fd);
    fd = open(p, O_RDONLY);
    if (fd < 0) { perror("reopen"); return 1; }
    int fds[1] = { fd };

    test_basic(fds, data);
    test_write();
    test_concurrent(fds, data);
    test_clamp();
    test_groups(fds, data);

    close(fd);
    unlink(p);
    free(data);
    if (nfail) { fprintf(stderr, "%d FAILURES\n", nfail); return 1; }
    printf("k3_io: basic+write+concurrent+clamp+groups OK\n");
    return 0;
}