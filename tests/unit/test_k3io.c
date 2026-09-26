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

/* 5. group scheduling: with group 1 active, group-0 requests queue; toggling back
 *    drains them. Each group's requests land in distinct FIFOs, so the L2 burst
 *    (group 1) can own the device while the trunk stream (group 0) parks. */
static void test_groups(int *fd, unsigned char *data)
{
    K3IO io;
    const int workers[2] = { 2, 1 };
    k3_io_init(&io, 2, workers);

    unsigned char buf0[1024], buf1[1024];
    memset(buf0, 0, sizeof buf0);
    memset(buf1, 0, sizeof buf1);

    /* park trunk: switch to group 1 first, then submit a group-0 request that must
     * wait until we switch back */
    k3_io_set_active(&io, 0, 1);
    K3IOReq *q0 = k3_io_submit_g(&io, 0, 0, fd[0], 0, 1024, 0, buf0);
    check(q0 != NULL, "submit group0 while group1 active");

    /* let the worker drain its tail briefly, then prove q0 did NOT complete yet */
    struct timespec ts = { 0, 30 * 1000 * 1000 };
    nanosleep(&ts, NULL);
    pthread_mutex_lock(&q0->mu);
    int done0 = q0->done;
    pthread_mutex_unlock(&q0->mu);
    check(done0 == 0, "group0 request queued while group1 active");

    /* group1 request completes while group0 waits */
    K3IOReq *q1 = k3_io_submit_g(&io, 0, 1, fd[0], 0, 1024, 0, buf1);
    check(q1 != NULL, "submit group1");
    ssize_t r1 = k3_io_wait(q1);
    check(r1 == 1024, "group1 read length");
    check(memcmp(buf1, data, 1024) == 0, "group1 bytes");

    /* switch back to group 0: now q0 drains and completes */
    k3_io_set_active(&io, 0, 0);
    ssize_t r0 = k3_io_wait(q0);
    check(r0 == 1024, "group0 read after switch-back");
    check(memcmp(buf0, data, 1024) == 0, "group0 bytes");

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