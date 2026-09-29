#!/bin/bash
# Is the 32/15 advantage a config effect or a device-state effect?
#
# The stall turned out to be no stall: token 1 was uniformly ~2x slower, 99.9% accounted
# for in the expert and compute phases, longest single event 12.81 s. So the 6/40 arm's
# spread is the NVMe delivering less, uniformly. That raises the obvious objection to v34's
# 30.4%: maybe both arms moved bytes at wildly different device rates and the gap is just
# whichever arm got the better drive.
#
# The test needs no new measurement. Aggregate throughput per token -- (trunk bytes +
# expert bytes) / wall -- is comparable across arms, and the engine prints the byte
# totals and the pread rate for every run.
#
# If the two arms' aggregate-rate distributions OVERLAP, the 30% could be device state.
# If they are DISJOINT, no single device state explains both, and the config effect is
# real on its own terms.
set -u
cd /mnt/f/kimi-k3-in-c

python3 - <<'PY'
import glob, os, re, statistics as st

def parse(d):
    lg=os.path.join(d,"ctrl.log")
    if not os.path.exists(lg): return None
    t=open(lg,errors="replace").read()
    def g(pat, cast=float, n=1):
        m=re.search(pat, t)
        return cast(m.group(1)) if m else None
    stk=g(r"([0-9.]+) s/token average")
    trunk=g(r"read ([0-9.]+) GB in")
    pread=g(r"in [0-9.]+ s \(([0-9.]+) MB/s pread\)")
    wall=g(r"([0-9.]+) s, .* s/token average")  # not present; use tokens*stk
    exp=g(r"experts, whole run: ([0-9.]+) GB")
    if None in (stk,trunk,pread,exp): return None
    ntok=8
    per_tok_bytes=(trunk+exp)/ntok
    return dict(name=os.path.basename(d)[:20], stk=stk, trunk=trunk, exp=exp,
                pread=pread, bytes_tok=per_tok_bytes,
                agg=per_tok_bytes*1e9/stk/1e6)   # MB/s aggregate

runs=[]
for pat,arm in (("reports/gateab_ab/v34_ab/t32c15_*","t32c15"),
                ("reports/gateab_ab/v34_ab/t6c40_*","t6c40"),
                ("reports/gateab_ab/v35_stall/rep*","t6c40*"),
                ("reports/gateab_ab/v33_base640/rep*","t6c40*")):
    for d in sorted(glob.glob(pat)):
        r=parse(d)
        if r: r["arm"]=arm; r["quiet"]=None
        # pull the 15min recorded at start, if the run has a state file
        for sf in ("state.txt","baseline.txt"):
            p=os.path.join(d,sf)
            if os.path.exists(p):
                for line in open(p,errors="replace"):
                    if "1min/5min/15min" in line:
                        v=re.findall(r"[0-9]+\.[0-9]+", line)
                        if len(v)>=3: r["quiet"]=float(v[2])
                    elif "load_before" in line:
                        v=re.findall(r"[0-9]+\.[0-9]+", line)
                        if len(v)>=3: r["quiet"]=float(v[2])
        if r: runs.append(r)

print("=== aggregate throughput per token: (trunk + expert bytes) / wall")
print("   %-9s %-22s %9s %9s %9s %9s" %
      ("arm","run","s/tok","GB/tok","pread","AGGREGATE"))
for r in sorted(runs,key=lambda x:(x["arm"],x["agg"])):
    print("   %-9s %-22s %9.2f %9.1f %9.0f %9.0f" %
          (r["arm"],r["name"],r["stk"],r["bytes_tok"],r["pread"],r["agg"]))

print()
print("=== do the two arms' aggregate-rate ranges overlap?")
a=[r["agg"] for r in runs if r["arm"]=="t32c15"]
b=[r["agg"] for r in runs if r["arm"]!="t32c15"]
if a and b:
    print("   t32c15  aggregate MB/s: %s   range %.0f-%.0f" %
          (" ".join("%3.0f"%x for x in sorted(a)), min(a), max(a)))
    print("   t6c40   aggregate MB/s: %s   range %.0f-%.0f" %
          (" ".join("%3.0f"%x for x in sorted(b)), min(b), max(b)))
    gap=min(a)-max(b)
    print()
    if gap>0:
        print("   DISJOINT. t32c15's WORST (%.0f MB/s) beats t6c40's BEST (%.0f MB/s)"
              % (min(a),max(b)))
        print("   by %.0f MB/s = %.1f%%. No single device state explains both arms,"
              % (gap, gap/max(b)*100))
        print("   so the config effect is real and not a device-rate artifact.")
    else:
        print("   OVERLAP of %.0f MB/s -- the gap could be device state; not separable."
              % (-gap))

print()
print("=== decompose the 30.4%: fewer bytes, or faster per byte?")
ma=st.median([r["stk"] for r in runs if r["arm"]=="t32c15"])
mb=st.median([r["stk"] for r in runs if r["arm"]!="t32c15"])
ba=st.median([r["bytes_tok"] for r in runs if r["arm"]=="t32c15"])
bb=st.median([r["bytes_tok"] for r in runs if r["arm"]!="t32c15"])
print("   bytes/token : %.1f -> %.1f GB  = %.1f%% fewer" % (bb,ba,(bb-ba)/bb*100))
print("   time/token  : %.2f -> %.2f s   = %.1f%% less" % (mb,ma,(mb-ma)/mb*100))
eff=(1-(mb-ma)/mb)/(1-(bb-ba)/bb)
print("   so the time gain decomposes into %.1f%% fewer bytes x %.1f%% more efficient per byte"
      % ((bb-ba)/bb*100, (1-eff)*100))
PY