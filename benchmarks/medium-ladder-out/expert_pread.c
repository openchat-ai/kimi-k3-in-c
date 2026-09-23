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
