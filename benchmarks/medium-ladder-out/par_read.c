#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>

static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec*1e-9; }
static void cold(void){
    sync();
    FILE *f = fopen("/proc/sys/vm/drop_caches", "w");
    if (f){ fputs("3", f); fclose(f); }
}
#define NEXP 1470
#define NTHR 16
#define ESZ 17547264
#define BS 17551360

static off_t offs[NEXP];
static int fd = -1;
static volatile long done = 0;

static void *worker(void *arg){
    long base = (long)arg;
    void *buf = NULL;
    if (posix_memalign(&buf, 4096, BS) != 0) return NULL;
    for (long i = base; i < NEXP; i += NTHR){
        ssize_t rv = pread(fd, buf, BS, offs[i] & ~(off_t)4095);
        if (rv < 0) { perror("pread"); return NULL; }
        __atomic_add_fetch(&done, 1, __ATOMIC_RELAXED);
    }
    free(buf);
    return NULL;
}

int main(int argc, char **argv){
    if (argc < 2) return 1;
    fd = open(argv[1], O_RDONLY | O_DIRECT);
    if (fd < 0) { perror("open"); return 1; }
    if (argc >= 3 + NEXP) {
        for (int i = 0; i < NEXP; i++) offs[i] = atoll(argv[2 + i]);
    } else {
        srand(1);
        for (int i = 0; i < NEXP; i++) offs[i] = (off_t)(rand() % 6490) * BS;
    }
    double r[3];
    for (int k = 0; k < 3; k++){
        cold();
        done = 0;
        pthread_t t[NTHR];
        double t0 = now();
        for (long th = 0; th < NTHR; th++) pthread_create(&t[th], NULL, worker, (void*)(long)th);
        for (int th = 0; th < NTHR; th++) pthread_join(t[th], NULL);
        double dt = now() - t0;
        r[k] = (double)NEXP * ESZ / dt / 1e9;
        fprintf(stderr, "pass %d: %.3f GB/s (%ld reads)\n", k, r[k], done);
    }
    double a = r[0], b = r[1], c = r[2];
    double med = a; if ((b>a)!=(c>a)) med = a; else if ((a>b)!=(c>b)) med = b; else med = c;
    printf("%.3f %.3f %.3f\n", r[0], r[1], r[2]);
    close(fd);
    return 0;
}