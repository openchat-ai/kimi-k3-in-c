#!/usr/bin/env python
"""
probe_quant_tradeoff.py - per-tensor E2M1 vs E2M0 tradeoff probe on the real model.

WHY THIS EXISTS
    MXFP4 stores expert weights as E2M1 nibbles (4 bit, 16 codes) plus one E8M0 scale
    per 32 elements. The 4 bits carry 3.75 of 4 bits of real information on the released
    checkpoint (measured: every code is used, entropy is 3.75/4), so the packed side is
    already at the entropy wall. The only remaining lever for "compress harder" is a
    second, lower-precision format.

    E2M0 is the OCP MX two-bit format: 1 sign + 1 exponent, magnitudes {0,1,2,4} in the
    block-normalised range, sharing the same E8M0 scale. It halves the packed bytes
    (0.53125 -> 0.28125 bytes/element), but its dequantised result differs from E2M1's
    by about 26% relative L2 on realistic weight distributions (measured with the
    released checkpoint's scale statistics, which sit at bytes {120,121,122}).

    The conformance gate does NOT reject E2M0: tools/verify_real_layer.py::dequant and
    the C engine both dequantise from the stored format, so switching torch and C to
    E2M0 together keeps them in agreement. The real cost is model quality, which only a
    full PPL/MMLU eval on the real checkpoint can measure. This probe produces the
    per-tensor perturbation table that decides which (if any) tensors can afford the
    downgrade. It reuses an independent safetensors reader (same spirit as
    verify_real_layer.Shards) and mirrors the checkpoint's quant rule
    (tools/make_tiny_checkpoint.py::mxfp4_quant).

    The probe is deliberately zero-write: it never rewrites the checkpoint, it only
    reads shards and prints a report. The decision is made by the human (or a future
    eval run), not by this script.

usage: probe_quant_tradeoff.py <shard_dir> [--limit N] [--tensors a,b,c]
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _paths import FIX_OPS  # noqa: E402  (kept for parity with sibling tools)

E2M1_MAG = np.array([0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0], dtype=np.float32)
E2M0_MAG = np.array([0.0, 1.0, 2.0, 4.0], dtype=np.float32)
GROUP = 32


class Shards:
    """Independent safetensors reader (mirrors verify_real_layer.Shards; kept local so
    the probe does not import torch just to read a file)."""

    def __init__(self, d: str):
        self.index = {}
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".safetensors"):
                continue
            p = os.path.join(d, fn)
            with open(p, "rb") as f:
                n = struct.unpack("<Q", f.read(8))[0]
                hdr = json.loads(f.read(n).decode("utf-8"))
            base = 8 + n
            for name, e in hdr.items():
                if name == "__metadata__":
                    continue
                a, b = e["data_offsets"]
                self.index[name] = (p, e["dtype"], tuple(e["shape"]), base + a, b - a)

    def get(self, name: str) -> np.ndarray:
        p, dt, shape, off, nb = self.index[name]
        with open(p, "rb") as f:
            f.seek(off)
            buf = f.read(nb)
        if dt == "F32":
            a = np.frombuffer(buf, dtype=np.float32)
        elif dt == "BF16":
            a = (np.frombuffer(buf, dtype=np.uint16).astype(np.uint32) << 16).view(np.float32)
        elif dt == "U8":
            a = np.frombuffer(buf, dtype=np.uint8)
        else:
            raise ValueError(dt)
        return a.reshape(shape)

    def has(self, name: str) -> bool:
        return name in self.index


def dequant_e2m1(p: np.ndarray, s: np.ndarray) -> np.ndarray:
    R, C = p.shape
    lo, hi = (p & 0x0F), (p >> 4)
    out = np.empty((R, 2 * C), dtype=np.float32)
    out[:, 0::2] = E2M1_MAG[lo & 7] * np.where(lo & 8, -1.0, 1.0)
    out[:, 1::2] = E2M1_MAG[hi & 7] * np.where(hi & 8, -1.0, 1.0)
    mult = np.where(s == 255, 0.0, np.exp2(s.astype(np.int64) - 127).astype(np.float32))
    out *= np.repeat(mult, GROUP, axis=1)[:, : 2 * C]
    return out


def quant_e2m0_dequant(w: np.ndarray) -> np.ndarray:
    """Re-quantise an E2M1-dequantised matrix down to E2M0 with the same scale rule,
    then dequantise. The output is what the engine would compute if this tensor were
    stored as E2M0."""
    R, C = w.shape
    blocks = w.reshape(R, C // GROUP, GROUP)
    amax = np.abs(blocks).max(axis=2)
    amax = np.maximum(amax, 1e-30)
    exp = (np.floor(np.log2(amax)) - 2).astype(np.float32)  # top E2M0 value is 4.0=2^2
    s = np.clip(exp + 127, 0, 255).astype(np.uint8)
    m = np.where(s == 255, 0.0, np.exp2(s.astype(np.int64) - 127)).reshape(R, C // GROUP, 1)
    x = blocks / m
    pos = np.abs(x)
    idx = np.argmin(np.abs(pos[..., None] - E2M0_MAG), axis=-1)
    reco = np.sign(x) * E2M0_MAG[idx]
    reco = np.where(x == 0, 0.0, reco) * m
    return reco.reshape(R, C).astype(np.float32)


def probe_tensor(sh: Shards, name: str):
    base = name.removesuffix(".weight_packed")
    if not (sh.has(base + ".weight_packed") and sh.has(base + ".weight_scale")):
        return None
    p = sh.get(base + ".weight_packed")
    s = sh.get(base + ".weight_scale")
    w4 = dequant_e2m1(p, s)
    w2 = quant_e2m0_dequant(w4)
    denom = max(np.linalg.norm(w4.ravel()), 1e-30)
    rel = np.linalg.norm(w2.ravel() - w4.ravel()) / denom
    # byte saving if this tensor goes E2M0
    packed_bytes = p.size
    scale_bytes = s.size
    b4 = packed_bytes + scale_bytes
    b2 = packed_bytes // 2 + scale_bytes
    save = 1.0 - b2 / b4
    # scale entropy
    s_flat = s.ravel()
    u = np.unique(s_flat)
    hist = np.bincount(s_flat, minlength=256)
    hh = hist[hist > 0] / s.size
    ent = -(hh * np.log2(hh)).sum()
    return {
        "tensor": name,
        "distinct_scales": len(u),
        "scale_entropy": round(ent, 2),
        "rel_l2_e2m0_vs_e2m1": float(rel),
        "bytes_packed": int(packed_bytes),
        "bytes_scale": int(scale_bytes),
        "byte_saving": save,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[1].strip())
    ap.add_argument("shard_dir")
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--tensors", default=None, help="comma-separated exact names")
    a = ap.parse_args()

    sh = Shards(a.shard_dir)
    names = [n for n in sh.index if n.endswith(".weight_packed")]
    names.sort()
    if a.tensors:
        wanted = [n.strip() for n in a.tensors.split(",") if n.strip()]
        names = [n for n in names if n in wanted or n.replace(".weight_packed", "") in wanted]
    if a.limit:
        names = names[: a.limit]

    print("tensor                               scales  ent  rel_L2(E2M0)  bytes_pack  save")
    print("-" * 92)
    agg_bytes = agg_save = 0.0
    for n in names:
        r = probe_tensor(sh, n)
        if r is None:
            continue
        label = r["tensor"].replace(".weight_packed", "")
        if len(label) > 40:
            label = label[:37] + "..."
        print("%-40s %6d %4.2f %12.4f %10d  %5.1f%%"
              % (label, r["distinct_scales"], r["scale_entropy"],
                 r["rel_l2_e2m0_vs_e2m1"], r["bytes_packed"], r["byte_saving"] * 100))
        agg_bytes += r["bytes_packed"] + r["bytes_scale"]
        agg_save += (r["bytes_packed"] // 2 + r["bytes_scale"])

    if agg_bytes:
        print("-" * 92)
        print("aggregate over %d expert tensors: %.1f%% packed-byte saving if ALL go E2M0"
              % (len(names), (1.0 - agg_save / agg_bytes) * 100))


if __name__ == "__main__":
    main()
