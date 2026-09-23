/* k3_l2cache.h - a disk-resident, expert-granularity second-level cache on a fast
 * volume (sdd7), behind the RAM expert cache.
 *
 * WHY IT EXISTS, IN MEASURED NUMBERS
 *   The RAM expert cache can hold only ~960 experts (17 GB of usable memory), so at a
 *   decode step it must stream ~25.83 GB/token of experts back from the slow checkpoint
 *   disk (sde, ~85 MB/s): ~94% of the wall time. A routing probe (expert_hist.json,
 *   gen=4 incremental) shows just 4,047 distinct experts account for ALL 5,888 requests
 *   across 4 tokens -- about 69.4 GB -- and there is 31% reuse across tokens. That set
 *   is scattered one layer per shard across ~92 shards, so it cannot be captured by
 *   coarse whole-shard symlinks (which would need 83 shards = 1.4 TB to reach 90%).
 *   Only expert-granularity (17.55 MB) eviction on a fast volume can hold the hot set.
 *
 *   sdd7 has 256 GB free; that is ~14,600 expert slots, comfortably above the traced
 *   distinct set, so the traced workload fits with no eviction at all.
 *
 * LAYOUT
 *   One preallocated file, one fixed-size slot per possible expert slot. Slots are
 *   indexed by array index: expert slot s lives at byte offset s * slot_bytes. Each
 *   slot stores the expert's CLEAN payload (17,547,264 bytes, which is a multiple of
 *   4096 and therefore O_DIRECT-aligned by construction). A memory array maps key
 *   (layer * n_experts + expert) to a slot index, or -1 for not resident. A slot's
 *   resident copy is valid only when key_of[slot] >= 0.
 *
 *   PERSISTENCE: the key map is also stored in <path>.meta -- 8 bytes per slot, the
 *   int32 key plus a crc32 of the key ++ the first 4096 payload bytes. k3_l2_init
 *   revalidates each populated slot's fingerprint against the bytes already on sdd7
 *   and reattaches the map, so a later process reuses what a previous run wrote
 *   instead of re-reading the slow checkpoint cold. A stale, part-written or recycled
 *   slot fails its crc and is treated as free (reuse is lost, data is never wrong).
 *
 * CONCURRENCY
 *   The hot path is the parallel phase-2 read in cache_getmany, so the sdd7 HIT read
 *   must be lock-free: pread takes an explicit offset and each thread reads a distinct
 *   slot, so it is race-free by construction. The cold path (a miss has to write the
 *   bytes back to sdd7) is serialized with an omp critical section so two threads never
 *   choose the same victim slot.
 *
 * EVICTION
 *   When the file is full and a miss arrives, the least-referenced (count) slot is
 *   reclaimed. With 256 GB and a ~69 GB working set this should almost never trigger.
 */
#ifndef K3_L2CACHE_H
#define K3_L2CACHE_H

#include <stdint.h>

#include "k3_load.h"
#include "k3_st.h"
#include "k3_io.h"

typedef struct K3L2 {
    int          fd;            /* buffered rw fd (miss write-back)               */
    int          fdh;           /* O_DIRECT ro fd for aligned hit reads, -1 off   */
    int          meta_fd;       /* <path>.meta key map, -1 if unavailable        */
    int          nslot;         /* number of expert slots in the file            */
    int          n_experts;     /* experts per layer, for key computation        */
    int64_t      slot_bytes;    /* bytes per slot (experts are uniform)          */
    int64_t      nbytes;        /* the expert payload size, == slot_bytes        */

    int32_t     *key_of;        /* [nslot] key held in slot, or -1               */
    int32_t     *slot_of;       /* [n_layers*n_experts] -> slot, or -1           */
    uint32_t    *count;         /* [nslot] reference counts for eviction         */

    /* Eviction policy: 0 = heat (evict lowest cumulative count, default, the
     * "predictive" brain from moe-paging), 1 = LRU (evict lowest stamp). */
    int          policy;
    uint64_t    *stamp;         /* [nslot] monotone last-access tick for LRU      */
    uint64_t     now;           /* global monotone tick                           */

    uint64_t     meta_loaded;   /* slots reattached from meta by init             */

    /* stats */
    uint64_t     hits, misses, bytes_read, bytes_written;
    /* I/O timing, split by source so the report can say how much of the load time was
     * the fast sdd7 hit reads vs the slow /model HDD miss reads. Effective MB/s is the
     * classic trap here: a 199 MB/s average hides a 1.5 GB/s NVMe hit path dragging a
     * ~200 MB/s HDD miss path. */
    double       hit_seconds, miss_seconds;
    /* Wall-clock equivalents. hit_seconds/miss_seconds are accumulated per-thread by
     * phase-2 read (each of the 16 parallel pread threads adds its own duration), so
     * reporting MB/s against them divides by the concurrency and understates the true
     * aggregate bandwidth. cache_getmany folds each batch's wall time (t2) into these
     * fields, split by the hit/miss share, so the report's MB/s reflects real throughput. */
    double       hit_wall, miss_wall;

    /* Unified media-tier I/O scheduler; hit reads go through the NVMe tier so the
     * trunk stream and the expert L2-hit burst share the fast drive by queue, not by
     * a 0/1 gate. NULL = direct pread (unit tests / no scheduler). */
    K3IO        *kio;
} K3L2;

/* Build the slot map for one expert. n_layers/keys are given so we can size slot_of.
 * size_bytes is the full file size; it is rounded DOWN to whole slots of slot_bytes.
 * Returns 0 on success. */
int  k3_l2_init(K3L2 *l2, const char *path, int64_t size_bytes,
                int n_layers, int n_experts, int64_t slot_bytes);

void k3_l2_free(K3L2 *l2);

/* Count per-layer L2-alive expert slots from <path>.meta + payload fingerprints,
 * without keeping any cache state (for the layer-bundle planner). Returns the total
 * alive, or -1 when the file/meta cannot be read (caller falls back to a constant). */
int k3_l2_count_alive(const char *path, int64_t size_bytes,
                      int n_layers, int n_experts, int64_t slot_bytes,
                      int *out);

/* Load expert (layer, expert) into buf so the caller can dequantise it, exactly like
 * k3_expert_load_direct but with the sdd7 second level in front. buf must hold
 * slot_bytes and be O_DIRECT-alignable. On a hit the bytes come from sdd7 (pread,
 * lock-free); on a miss k3_expert_load_direct pulls them from the checkpoint and the
 * private write-back serialised by an omp critical section stores them onto sdd7.
 * *payload_off receives where the payload starts (always 0 here because the stored
 * bytes are already aligned). Returns bytes available, or -1 on error. */
int64_t k3_l2_load_direct(K3L2 *l2, const K3St *st, const K3ExpertRef *r,
                          unsigned char *buf, int64_t bufcap, int64_t *payload_off);

void k3_l2_report(const K3L2 *l2, const char *label);

#endif /* K3_L2CACHE_H */
