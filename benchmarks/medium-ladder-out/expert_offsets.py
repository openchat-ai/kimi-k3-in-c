import json, struct, sys
p = sys.argv[1]
with open(p, "rb") as fh:
    hlen = struct.unpack("<Q", fh.read(8))[0]
    hdr = json.loads(fh.read(hlen))
offs = []
for k, t in hdr.items():
    if ".experts." in k and k.endswith("weight_packed"):
        lo, hi = t["data_offsets"]
        offs.append(lo)
        if len(offs) >= 32:
            break
print(" ".join(map(str, offs)))
