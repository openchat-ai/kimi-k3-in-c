/* k3_l2cache.c - see k3_l2cache.h. */
#define _GNU_SOURCE              /* O_DIRECT */
#define _POSIX_C_SOURCE 200809L

#include "k3_l2cache.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static double now_s(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* CRC-32/IEEE (reflected polynomial 0xEDB88320), used to fingerprint a slot's first
 * 4096 payload bytes together with its key. The crc rides in the meta file, so a
 * stale, part-written or re-used slot can never masquerade as the expert the meta
 * claims it holds: the fingerprint only matches when the key AND the payload bytes
 * on sdd7 are exactly what the previous run wrote. */
static uint32_t k3_crc32_table[256];

#define L2_CRC_N 4096   /* payload bytes folded into the fingerprint */

static void k3_crc32_build(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int j = 0; j < 8; j++)
            c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        k3_crc32_table[i] = c;
    }
}

/* Fingerprint of a slot: crc32 of (key as 4 LE bytes) ++ p[0..n). */
static uint32_t k3_slot_crc(int32_t key, const unsigned char *p, size_t n)
{
    uint32_t c = 0xFFFFFFFFu;
    const unsigned char kk[4] = {
        (unsigned char)(key & 0xFF),
        (unsigned char)((key >> 8) & 0xFF),
        (unsigned char)((key >> 16) & 0xFF),
        (unsigned char)((key >> 24) & 0xFF),
    };
    for (int i = 0; i < 4; i++)
        c = (c >> 8) ^ k3_crc32_table[(c ^ kk[i]) & 0xFFu];
    for (size_t i = 0; i < n; i++)
        c = (c >> 8) ^ k3_crc32_table[(c ^ p[i]) & 0xFFu];
    return c ^ 0xFFFFFFFFu;
}

int k3_l2_init(K3L2 *l2, const char *path, int64_t size_bytes,
               int n_layers, int n_experts, int64_t slot_bytes)
{
    memset(l2, 0, sizeof *l2);
    k3_crc32_build();

    /* Buffered rw fd for the miss path: the expert's clean run inside the checkpoint's
     * widened buffer starts at a shard-dependent pad that is not page aligned, so an
     * O_DIRECT pwrite would be EINVAL. Hits, however, read a whole cached slot whose
     * offset and length are page aligned and whose destination is the page-aligned
     * cache arena, so a second O_DIRECT read-only fd gets the device's full bandwidth
     * without the page-cache churn a 238 GB file would otherwise burn. */
    l2->fd = open(path, O_RDWR | O_CREAT, 0644);
    if (l2->fd < 0) {
        perror("k3_l2: open"); return -1;
    }
    l2->fdh = open(path, O_RDONLY | O_DIRECT);
    if (l2->fdh < 0)
        fprintf(stderr, "k3_l2: O_DIRECT read fd unavailable; using buffered hit reads\n");

    /* Round size DOWN to whole slots of slot_bytes, so every slot is aligned. */
    if (slot_bytes <= 0 || size_bytes < slot_bytes) {
        fprintf(stderr, "k3_l2: sizeof too small\n"); close(l2->fd); return -1;
    }
    l2->slot_bytes = slot_bytes;
    l2->nbytes = slot_bytes;
    l2->n_experts = n_experts;
    l2->nslot = (int)(size_bytes / slot_bytes);
    if (l2->nslot < 1) { fprintf(stderr, "k3_l2: no room\n"); close(l2->fd); return -1; }

    const int64_t flen = (int64_t)l2->nslot * slot_bytes;
    if (ftruncate(l2->fd, flen) != 0) { perror("k3_l2: ftruncate"); close(l2->fd); return -1; }

    const size_t nkey = (size_t)n_layers * n_experts;
    l2->key_of  = (int32_t *)malloc((size_t)l2->nslot * sizeof(int32_t));
    l2->slot_of = (int32_t *)malloc(nkey * sizeof(int32_t));
    l2->count   = (uint32_t *)calloc((size_t)l2->nslot, sizeof(uint32_t));
    l2->stamp   = (uint64_t *)calloc((size_t)l2->nslot, sizeof(uint64_t));
    l2->policy  = 0;      /* heat by default */
    l2->now     = 0;
    if (!l2->key_of || !l2->slot_of || !l2->count || !l2->stamp) { k3_l2_free(l2); return -1; }
    for (int i = 0; i < l2->nslot; i++) l2->key_of[i] = -1;
    for (size_t i = 0; i < nkey; i++)  l2->slot_of[i] = -1;

    /* Persistent key map: <path>.meta stores one 8-byte record per slot -- int32 key
     * plus crc32 of (key ++ first L2_CRC_N payload bytes). k3_l2_init revalidates each
     * populated slot against the payload crc and reattaches the map, so a later
     * process reuses everything the previous run wrote to sdd7 instead of re-reading
     * the slow checkpoint cold. A stale or partially-written slot fails its crc and is
     * treated as free. */
    l2->meta_fd = -1;
    char meta_path[512];
    if (snprintf(meta_path, sizeof meta_path, "%s.meta", path) >= (int)sizeof meta_path) {
        fprintf(stderr, "k3_l2: meta path too long; continuing without persistence\n");
    } else {
        l2->meta_fd = open(meta_path, O_RDWR | O_CREAT, 0644);
        if (l2->meta_fd < 0) {
            fprintf(stderr, "k3_l2: meta open failed; continuing without persistence\n");
        } else {
            const off_t mlen = (off_t)l2->nslot * 8;
            unsigned char *m = NULL;
            struct stat mst;
            if (fstat(l2->meta_fd, &mst) == 0 && mst.st_size > 0) {
                const size_t av = (size_t)(mst.st_size < mlen ? mst.st_size : mlen);
                m = (unsigned char *)malloc(av ? av : 1);
                if (m) {
                    const ssize_t got = av ? pread(l2->meta_fd, m, av, 0) : 0;
                    for (int i = 0; got >= (ssize_t)(i * 8 + 8); i++) {
                        int32_t key;
                        uint32_t crc;
                        memcpy(&key, m + i * 8, 4);
                        memcpy(&crc, m + i * 8 + 4, 4);
                        if (key < 0 || (size_t)key >= nkey) continue;
                        if (l2->slot_of[key] >= 0) continue;   /* dup: keep first */
                        unsigned char probe[L2_CRC_N];
                        const ssize_t pr = pread(l2->fd, probe, sizeof probe,
                                                 (off_t)i * l2->slot_bytes);
                        if (pr != (ssize_t)sizeof probe) continue;
                        if (k3_slot_crc(key, probe, sizeof probe) != crc) continue;
                        l2->key_of[i] = key;
                        l2->slot_of[key] = i;
                        l2->meta_loaded++;
                    }
                    free(m);
                }
            }
            if (ftruncate(l2->meta_fd, mlen) != 0) perror("k3_l2: meta ftruncate");
        }
    }
    return 0;
}

void k3_l2_free(K3L2 *l2)
{
    if (l2->fd >= 0) close(l2->fd);
    if (l2->fdh >= 0) close(l2->fdh);
    if (l2->meta_fd >= 0) close(l2->meta_fd);
    free(l2->key_of); free(l2->slot_of); free(l2->count); free(l2->stamp);
    memset(l2, 0, sizeof *l2);
}

/* Find the slot holding this key, or -1. O(1) direct map. The key namespace is
 * (layer, expert) so a flat slot_of[] indexed by key is exact -- no probing, and no
 * way for a stored key to sit unreachable on another probe chain. */
static int l2_find(const K3L2 *l2, int32_t key)
{
    return l2->slot_of[key];
}

/* Pick a victim slot for a fresh write. policy 0 (heat): the lowest cumulative
 * count slot, ties broken by lower index -- the "predictive" brain that keeps the
 * frequently-reused expert working set resident across a monotone-superset session.
 * policy 1 (LRU): the lowest stamp (least recently touched). Only called under the
 * omp critical region, or single-threaded during init fill. */
static int l2_victim(const K3L2 *l2)
{
    int best = 0;
    if (l2->policy == 1) {
        uint64_t mint = l2->stamp[0];
        for (int i = 1; i < l2->nslot; i++) {
            if (l2->stamp[i] < mint) { mint = l2->stamp[i]; best = i; }
        }
    } else {
        uint32_t minc = l2->count[0];
        for (int i = 1; i < l2->nslot; i++) {
            if (l2->count[i] < minc) { minc = l2->count[i]; best = i; }
        }
    }
    return best;
}

int64_t k3_l2_load_direct(K3L2 *l2, const K3St *st, const K3ExpertRef *r,
                          unsigned char *buf, int64_t bufcap, int64_t *payload_off)
{
    const int32_t key = r->layer * l2->n_experts + r->expert;
    const int s = l2_find(l2, key);

    if (s >= 0) {
        /* sdd7 HIT: lock-free pread of a distinct slot. The stored bytes are the clean
         * payload already aligned to K3_ST_ALIGN, so the payload starts at offset 0. */
        const int64_t want = r->nbytes < l2->nbytes ? r->nbytes : l2->nbytes;
        if (want > bufcap) return -1;
        const int rfd = (l2->fdh >= 0 && want == l2->slot_bytes) ? l2->fdh : l2->fd;
        const double t0 = now_s();
        const ssize_t n = pread(rfd, buf, (size_t)want,
                                (off_t)s * l2->slot_bytes);
        l2->hit_seconds += now_s() - t0;
        if (n != (ssize_t)want) return -1;
        l2->hits++;
        l2->bytes_read += (uint64_t)want;
        (void)__sync_fetch_and_add(&l2->count[s], 1u);
        (void)__sync_fetch_and_add(&l2->now, 1u);
        l2->stamp[s] = l2->now;
        *payload_off = 0;
        return want;
    }

    /* sdd7 MISS: read from the slow checkpoint, then store onto sdd7. The write and
     * victim choice are serialised so parallel phase-2 threads cannot fight for a slot. */
    const double tm0 = now_s();
    l2->misses++;
    int64_t pad = 0;
    const int64_t got = k3_expert_load_direct(st, r, buf, bufcap, &pad);
    /* k3_expert_load_direct widened the O_DIRECT read to the enclosing 4096 boundary, so
     * the expert's bytes start at buf + pad. The caller must know that offset or its
     * fill_q resolves the expert to the wrong bytes and the MoE multiplies garbage. */
    if (payload_off) *payload_off = pad;
    if (got != r->nbytes) { l2->miss_seconds += now_s() - tm0; return got; }

    /* Defensive: only a contiguous expert is stored as one aligned run. A fragmented
     * expert (not seen in real K3, but k3_expert_ref can report it) is served from the
     * checkpoint and simply not cached, keeping the slot map consistent. */
    if (!r->contiguous) return got;

    /* Fingerprint the payload up front, on this thread's own buffer, so the critical
     * section below stays as short as possible. */
    const size_t nchk = (r->nbytes < (int64_t)L2_CRC_N) ?
                        (size_t)r->nbytes : (size_t)L2_CRC_N;
    const uint32_t crc = (l2->meta_fd >= 0) ? k3_slot_crc(key, buf + pad, nchk) : 0;

    {
#ifdef _OPENMP
#   pragma omp critical(k3_l2_fill)
#endif
        {
            int slot = l2_find(l2, key);
            if (slot < 0) {
                slot = l2_victim(l2);
                const int32_t old = l2->key_of[slot];
                if (old >= 0) l2->slot_of[old] = -1;   /* drop the evicted key's map */
                l2->key_of[slot] = key;
                l2->count[slot] = 0;
            }
            /* Write the clean, aligned payload. r->nbytes is 4096-aligned for real K3
             * so the slot write is aligned too. The pwrite must COMPLETE before the
             * mapping is published below, otherwise the lock-free HIT path could pread
             * a slot whose bytes are not on sdd7 yet. */
            const int64_t want = r->nbytes;
            const ssize_t n = pwrite(l2->fd, buf + pad, (size_t)want,
                                     (off_t)slot * l2->slot_bytes);
            if (n == (ssize_t)want) {
                /* Publish AFTER the bytes are durable: readers only trust slot_of. */
                l2->slot_of[key] = slot;
                l2->count[slot]++; l2->bytes_written += (uint64_t)want;
                (void)__sync_fetch_and_add(&l2->now, 1u);
                l2->stamp[slot] = l2->now;
                /* Persist the (key, crc) record for slot so a later process revalidates
                 * and reuses it instead of re-reading the slow checkpoint cold. */
                if (l2->meta_fd >= 0) {
                    const uint32_t rec[2] = { (uint32_t)key, crc };
                    (void)pwrite(l2->meta_fd, rec, sizeof rec, (off_t)slot * 8);
                }
            }
        }
    }
    l2->miss_seconds += now_s() - tm0;
    return got;
}

void k3_l2_report(const K3L2 *l2, const char *label)
{
    const uint64_t n = l2->hits + l2->misses;
    printf("l2cache [%s]\n", label ? label : "");
    printf("  requests     : %llu  hits %llu (%.2f%%)  misses %llu\n",
           (unsigned long long)n, (unsigned long long)l2->hits,
           n ? 100.0 * l2->hits / n : 0.0, (unsigned long long)l2->misses);
    printf("  read  from sdd7: %.2f GB, written %.2f GB\n",
           (double)l2->bytes_read / 1e9, (double)l2->bytes_written / 1e9);
    printf("  hit I/O   : %.2f GB in %.2f s = %.0f MB/s\n",
           (double)l2->bytes_read / 1e9, l2->hit_seconds,
           l2->hit_seconds > 0 ? (double)l2->bytes_read / 1e6 / l2->hit_seconds : 0.0);
    printf("  miss I/O  : %llu misses, %.2f GB from /model in %.2f s = %.0f MB/s\n",
           (unsigned long long)l2->misses, l2->misses * (double)l2->slot_bytes / 1e9,
           l2->miss_seconds, l2->miss_seconds > 0
               ? l2->misses * (double)l2->slot_bytes / 1e6 / l2->miss_seconds : 0.0);
    if (l2->meta_loaded)
        printf("  restored from meta: %llu slots\n",
               (unsigned long long)l2->meta_loaded);
}
