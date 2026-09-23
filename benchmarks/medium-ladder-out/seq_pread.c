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
