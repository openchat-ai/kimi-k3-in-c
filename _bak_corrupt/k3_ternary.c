/* k3_ternary.c - weights that are -1, 0 or +1, packed at two bits per element.
 *
 * The MXFP4 path (k3_matmul_mxfp4) never materialises its matrix, which is what lets a
 * streamed expert stay at 17.55 MB instead of 132 MB. Ternary quantisation carries the
 * same idea to a harder limit: a [-1,0,1] expert costs 0.25 bits per element, i.e.
 * 1/128 of the fp32 size, at the price of giving up every scale bit. The 33,030,144
 * parameter expert becomes 33,030,144 / 4 = 8,257,536 bytes (7.88 MB), and the matmul
 * over it is memory-bound on x rather than on W.
 *
 * ON-DISK FORMAT. One element is one two-bit code, low pair of each byte first: element
 * i of a row sits at byte i/4 in bits (i%4)*2. The codes are
 *
 *     0 -> +0     1 -> +1     2 -> -1     3 -> INVALID
 *
 * code 0 doubling as the natural zero is what makes a zero-filled tail read as zero
 * weight, which is exactly what padding beyond the true width is written as. code 3 is
 * rejected by the loader; a code 3 that nevertheless reaches a kernel reads as NaN and
 * poisons the whole output row, so a missed check cannot silently turn one weight into
 * a different one - the row dies loudly instead.
 *
 * ROW-MAJOR, like every other matrix in this engine: row r element i lives at
 * packed[r * pcols + i/4] with pcols = (in + 3) / 4.
 *
 * BIT IDENTITY. k3_ternary_matmul is a strict rewrite of k3_matmul with the weight read
 * from the packed byte instead of from a float: the same sixteen double accumulators,
 * the same fma() calls in the same order, the same reduction tree, the same OpenMP
 * split over output rows. The dequantised weights are exactly -1.0 / 0.0 / +1.0, so
 * both kernels take identical operands in identical order and return bit-identical
 * results. The op test asserts that equality rather than a tolerance, which is what
 * catches a wrong stride, a dropped tail element or a mis-shifted pair.
 *
 * THE AVX2 PATH IS BIT-IDENTICAL TO THE SCALAR PATH. A __m256d holds four doubles, and
 * a sixteen-element block with element i placed in lane i%4 of accumulator i/4
 * reproduces the scalar partition with the same sequential order inside each lane. A
 * lane's weight is exactly one of the four LUT entries widened to double, so
 * _mm256_fmadd_pd is the same IEEE operation as the scalar fma() and the two paths
 * agree to the bit, code-3 NaN rows included. The reduction (v0+v1)+(v2+v3) lanewise,
 * then (bb[0]+bb[1])+(bb[2]+bb[3]), is lane-for-lane the scalar tree. The scalar tail
 * loop is reused verbatim for the i % 16 remainder. The op test's bit-identity check
 * therefore exercises the AVX2 path on any AVX2 build.
 */
#include "k3.h"

#include <math.h>

#if defined(__AVX2__)
#include <immintrin.h>
#endif

/* code 3 is NaN on purpose, see the header comment above. */
static const float K3_TERNARY_LUT[4] = { 0.0f, 1.0f, -1.0f, NAN };

void k3_ternary_dequant(float *out, const unsigned char *packed, int rows, int in)
{
    const int pcols = (in + 3) / 4;
    for (int r = 0; r < rows; r++) {
        const unsigned char *row = packed + (size_t)r * pcols;
        float *o = out + (size_t)r * in;
        for (int i = 0; i < in; i++) {
            const unsigned c = (row[i / 4] >> (2 * (i % 4))) & 0x3u;
            o[i] = K3_TERNARY_LUT[c];
        }
    }
}

void k3_ternary_matmul(float *y, const float *x, const unsigned char *packed,
                       int in, int out)
{
    const int pcols = (in + 3) / 4;
#ifdef _OPENMP
#pragma omp parallel for schedule(static) if (out > 64)
#endif
    for (int o = 0; o < out; o++) {
        const unsigned char *row = packed + (size_t)o * pcols;
        int i = 0;
        double acc;
#if defined(__AVX2__)
        {
            __m256d v0 = _mm256_setzero_pd(), v1 = _mm256_setzero_pd();
            __m256d v2 = _mm256_setzero_pd(), v3 = _mm256_setzero_pd();
            for (; i + 15 < in; i += 16) {
                /* byte k holds elements i+4k .. i+4k+3, low pair first, so each byte
                 * widens to one __m256d of weights, lane j = element i+4k+j. */
                const unsigned b0 = row[i / 4];
                const unsigned b1 = row[i / 4 + 1];
                const unsigned b2 = row[i / 4 + 2];
                const unsigned b3 = row[i / 4 + 3];
                v0 = _mm256_fmadd_pd(
                    _mm256_set_pd((double)K3_TERNARY_LUT[(b0 >> 6) & 3],
                                  (double)K3_TERNARY_LUT[(b0 >> 4) & 3],
                                  (double)K3_TERNARY_LUT[(b0 >> 2) & 3],
                                  (double)K3_TERNARY_LUT[b0 & 3]),
                    _mm256_cvtps_pd(_mm_loadu_ps(x + i)), v0);
                v1 = _mm256_fmadd_pd(
                    _mm256_set_pd((double)K3_TERNARY_LUT[(b1 >> 6) & 3],
                                  (double)K3_TERNARY_LUT[(b1 >> 4) & 3],
                                  (double)K3_TERNARY_LUT[(b1 >> 2) & 3],
                                  (double)K3_TERNARY_LUT[b1 & 3]),
                    _mm256_cvtps_pd(_mm_loadu_ps(x + i + 4)), v1);
                v2 = _mm256_fmadd_pd(
                    _mm256_set_pd((double)K3_TERNARY_LUT[(b2 >> 6) & 3],
                                  (double)K3_TERNARY_LUT[(b2 >> 4) & 3],
                                  (double)K3_TERNARY_LUT[(b2 >> 2) & 3],
                                  (double)K3_TERNARY_LUT[b2 & 3]),
                    _mm256_cvtps_pd(_mm_loadu_ps(x + i + 8)), v2);
                v3 = _mm256_fmadd_pd(
                    _mm256_set_pd((double)K3_TERNARY_LUT[(b3 >> 6) & 3],
                                  (double)K3_TERNARY_LUT[(b3 >> 4) & 3],
                                  (double)K3_TERNARY_LUT[(b3 >> 2) & 3],
                                  (double)K3_TERNARY_LUT[b3 & 3]),
                    _mm256_cvtps_pd(_mm_loadu_ps(x + i + 12)), v3);
            }
            /* (v0+v1)+(v2+v3) lanewise, then the same cross-lane pairing as scalar */
            const __m256d vt = _mm256_add_pd(_mm256_add_pd(v0, v1),
                                             _mm256_add_pd(v2, v3));
            double bb[4];
            _mm256_storeu_pd(bb, vt);
            acc = (bb[0] + bb[1]) + (bb[2] + bb[3]);
        }
#else
        {
            double a[16] = {0};
            for (; i + 15 < in; i += 16)
                for (int l = 0; l < 16; l++) {
                    const unsigned c = (row[(i + l) / 4] >> (2 * ((i + l) % 4))) & 0x3u;
                    a[l] = fma((double)K3_TERNARY_LUT[c], (double)x[i + l], a[l]);
                }
            double b0 = (a[0] + a[4]) + (a[8]  + a[12]);
            double b1 = (a[1] + a[5]) + (a[9]  + a[13]);
            double b2 = (a[2] + a[6]) + (a[10] + a[14]);
            double b3 = (a[3] + a[7]) + (a[11] + a[15]);
            acc = (b0 + b1) + (b2 + b3);
        }
#endif
        for (; i < in; i++) {
            const unsigned c = (row[i / 4] >> (2 * (i % 4))) & 0x3u;
            acc = fma((double)K3_TERNARY_LUT[c], (double)x[i], acc);
        }
        y[o] = (float)acc;
    }
}