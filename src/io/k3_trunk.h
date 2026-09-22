/* k3_trunk.h - stream the resident trunk, so RAM becomes a dial instead of a floor.
 *
 * WHY STREAM THE TRUNK AT ALL
 *   The engine holds 110 GB of trunk plus 4.70 GB of embed/lm_head. That is the floor
 *   that forces a 128 GB machine. Quantising it down is the obvious idea and it is the
 *   wrong one: Kimi K3's technical report section 4.1.4 says the experts are MXFP4 with
 *   quantisation-aware training "while all non-expert components (attention projections,
 *   latent MoE projections, shared experts, and MoE routers) remain in higher
 *   precision". That list IS this trunk. Measured on 31 real attention tensors
 *   (docs/data/trunk-quantisation.txt), post-hoc int4 costs 17.4% mean relative WEIGHT
 *   reconstruction error against 0.96% for int8 -- an ~18x gap, consistent across every
 *   tensor sampled. That is weight error, not output quality, but it is enough to rule
 *   out 4-bit on a trunk that was never trained for it.
 *
 *   Streaming costs zero error. The bytes are the checkpoint's own bytes.
 *
 * WHY IT IS AFFORDABLE
 *   Read bandwidth decides this, and it varies by an order of magnitude between a
 *   network volume and local NVMe. Measure the target device with tools/devbw.py
 *   before drawing conclusions. On local NVMe at a few GB/s the whole trunk costs
 *   tens of seconds per token against compute of the same order, so the read is not
 *   automatically the bottleneck. What makes it hideable is that, unlike expert routing,
 *   the trunk access order is FIXED: layer 0, 1, ... 92, every single token, so the next
 *   read is always known in advance.
 *
 *   It IS hidden now. k3_trunk_prefetch hands layer L+1 to a reader thread while the
 *   main thread computes on layer L, which is what the fixed walk order makes safe: the
 *   next layer is always known, so there is nothing to predict. Measured on the released
 *   checkpoint at the laptop preset, this took 71.75 s/token to 42.27 s/token, a 1.70x
 *   improvement, and it beat running the same model with four times the memory and no
 *   overlap.
 *
 *   The second ring slot it needs costs a full slot, 2.37 GB at the floor, so it is only
 *   taken when the trunk budget can pay for it. Below that the ring stays at one slot and
 *   reads are serial again; k3_trunk_open says so on stdout when that happens. Correctness
 *   does not depend on which path runs, and the emitted tokens are identical either way.
 *
 * WHY LRU WOULD BE THE WORST POSSIBLE POLICY HERE
 *   A cyclic sequential scan is the classic LRU pathology. With N < 93 slots, by the
 *   time the walk returns to layer 0 it is exactly the least recently used thing and has
 *   just been evicted, so the hit rate is ZERO no matter how much RAM is added. This
 *   cache therefore PINS a prefix of layers and streams the rest through a small ring:
 *   pin K layers and the hit rate is exactly K/93, deterministically, and every extra
 *   gigabyte buys its fair share. The expert cache keeps LRU because expert reuse is
 *   data-dependent, which is the opposite situation.
 *
 * LAYOUT
 *   tools/pack_trunk.py copies each layer's trunk, which is ONE contiguous run in its
 *   shard, into trunk.bin, and records offsets in trunk.json. So loading a layer is a
 *   single pread from local NVMe. The bytes are copied verbatim, so a tensor's position
 *   inside a slot is (its absolute shard offset - the run start).
 */
#ifndef K3_TRUNK_H
#define K3_TRUNK_H

#include "k3.h"
#include "k3_bind.h"

#define K3_TRUNK_ALIGN 4096   /* pack_trunk.py pads runs to this so O_DIRECT works */

typedef struct {
    char    *name;
    int64_t  off;          /* byte offset WITHIN the layer run */
    int64_t  nbytes;
    int      dtype;        /* K3Dtype */
    int      e;            /* MXFP8_E8M7 per-tensor exponent; 0 otherwise */
    int      ngrp;         /* MXFP8_E8M7_128 groups per row;
                            * data on disk is [scales ngrp][codes cols] per row */
    int64_t  shape[2];     /* rows, cols for 2D tensors; 0 otherwise */
} K3TrunkTensor;

typedef struct {
    int64_t  file_off;     /* offset in trunk.bin */
    int64_t  nbytes;
    K3TrunkTensor *t;
    int      nt;
} K3TrunkLayer;

typedef struct {
    int          fd;
    int          direct;        /* 1 when the file was opened O_DIRECT */
    int          n_layers;
    K3TrunkLayer *lay;

    /* Sliced mode: when the trunk directory holds layer_%03d.bin slices instead of a
     * single trunk.bin, each layer gets its own fd (opened lazily). NULL otherwise;
     * load_run uses layer_fd[L] (offset 0) when present, else tr->fd + file_off. */
    int          *layer_fd;     /* [n_layers], -1 when not yet opened; NULL = packed mode */
    char          *slice_dir;    /* dir the slices live in (owned, freed in close); sliced mode */

    /* Backs every K3TrunkTensor.name, so it must outlive the whole struct. Owned here
     * and freed by k3_trunk_close; do not free the parser arena separately. */
    char          *json_arena;

    /* Pinned layers get exact-size allocations; only the streaming ring is uniform.
     * Uniform slots everywhere would size EVERY slot for layer 0, whose dense MLP makes
     * it 2.34 GB against 1.27 GB for a normal layer, wasting about half the budget. */
    unsigned char **pin;        /* [npin] one exact allocation per pinned layer */
    unsigned char *arena;       /* [nslot] uniform ring slots                   */
    int64_t      slot_bytes;    /* raw run + the widen area                     */
    int64_t      widen_bytes;   /* of slot_bytes, the fp32 expansion area       */
    int          nslot;
    int          npin;          /* layers 0..npin-1 are pinned                  */
    int         *layer_of;      /* [nslot] which layer occupies each ring slot  */
    int32_t     *slot_of;       /* [n_layers], -1 when not resident             */
    int          ring;          /* next ring slot to reuse                      */

    /* One asynchronous reader owns one spare ring slot. The worker never publishes a
     * layer name before its read succeeds; bind waits for completion before consuming it. */
    void         *io_state;
    struct K3IO *kio;        /* unified media-tier I/O scheduler (NULL = direct pread) */

    /* stats */
    uint64_t     hits, misses;
    uint64_t     bytes_read;
    double       load_seconds;    /* pread + gate wait, see k3_trunk_report */
    double       wait_seconds;    /* of load_seconds, spent parked on the expert gate */
    uint64_t    *reads_by_layer;  /* [n_layers] how many times each layer was load_run */
} K3Trunk;

/* Sum of the layer nbytes in dir/trunk.json, i.e. the packed trunk.bin size without
 * the file being open. 0 on any read/parse failure. Used by the budget code so "fit
 * this machine" is measured against the ACTUAL trunk, not a stale hardcoded figure. */
int64_t k3_trunk_packed_bytes(const char *dir);

/* budget_bytes sizes the slot array. Layers 0..K-1 are pinned, where K is as large as
 * the budget allows minus a streaming ring. ring_want is the DESIRED number of ring
 * slots; the allocator takes as many as the budget can pay for, down to 1. A larger
 * ring keeps more recently-streamed layers resident across tokens, so a mid-budget run
 * re-reads the trunk fewer than once-per-layer-per-token. Returns 0 on success. */
int  k3_trunk_open(K3Trunk *tr, const char *dir, const K3Cfg *c, int64_t budget_bytes,
                   int ring_want);
void k3_trunk_close(K3Trunk *tr);

/* Make layer L resident and point b's weight pointers at it. b must already have been
 * prepared by k3_bind_layer_mem, which resolves the layer's tensor shapes once. */
int  k3_trunk_bind(K3Trunk *tr, const K3Cfg *c, int L, K3LayerBind *b);

/* Start an asynchronous read of layer L into its slot, if it is not resident. Safe to
 * call for a layer that is pinned or already loaded (it becomes a no-op). */
void k3_trunk_prefetch(K3Trunk *tr, int L);

/* A layer's bytes may be reused once its compute is done. Call after computing L: the
 * slot it occupied is marked free so a later prefetch can claim it without ever
 * evicting a slot that is still being read by the caller's kernel. Pinned layers are
 * never released. */
void k3_trunk_release(K3Trunk *tr, int L);

/* NVMe contended-stream gate. While the expert cache is running its phase-2 scattered
 * burst it dominates the drive; letting the trunk reader co-stream at the same time
 * halves both. hold != 0 pauses the async reader (at the next TRUNK_READ_CHUNK
 * boundary), hold == 0 resumes it. Safe to call with any io_state, including NULL
 * (single-slot ring, no reader). */
void k3_trunk_expert_hold(K3Trunk *tr, int hold);

void k3_trunk_report(const K3Trunk *tr, const char *label);

#endif /* K3_TRUNK_H */
