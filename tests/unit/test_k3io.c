#include "k3_io.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

int main(void)
{
    const char *p = "/tmp/k3io_test.bin";
    FILE *f = fopen(p, "wb");
    unsigned char data[4096];
    for (int i = 0; i < 4096; i++) data[i] = (unsigned char)(i & 0xFF);
    fwrite(data, 1, 4096, f);
    fclose(f);
    int fd = open(p, O_RDONLY);

    K3IO io;
    const int workers[2] = { 4, 1 };
    k3_io_init(&io, 2, workers);
    fprintf(stderr, "init done\n");

    unsigned char buf0[1024], buf1[1024], buf2[2048], buf3[512];
    K3IOReq *r0 = k3_io_submit(&io, 0, fd, 0, 1024, buf0);
    fprintf(stderr, "submit r0 done\n");
    K3IOReq *r1 = k3_io_submit(&io, 1, fd, 1024, 1024, buf1);
    fprintf(stderr, "submit r1 done\n");
    K3IOReq *r2 = k3_io_submit(&io, 0, fd, 2048, 2048, buf2);
    fprintf(stderr, "submit r2 done\n");
    K3IOReq *r3 = k3_io_submit(&io, 1, fd, 3584, 512, buf3);
    fprintf(stderr, "submit r3 done, waiting r0\n");
    fflush(stderr);

    int rc0 = k3_io_wait(r0);
    fprintf(stderr, "r0 done rc=%d\n", rc0);
    int rc1 = k3_io_wait(r1);
    fprintf(stderr, "r1 done rc=%d\n", rc1);
    int rc2 = k3_io_wait(r2);
    fprintf(stderr, "r2 done rc=%d\n", rc2);
    int rc3 = k3_io_wait(r3);
    fprintf(stderr, "r3 done rc=%d\n", rc3);

    printf("rc: %d %d %d %d\n", rc0, rc1, rc2, rc3);
    k3_io_free(&io);
    close(fd);
    unlink(p);
    return 0;
}