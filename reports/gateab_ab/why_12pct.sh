#!/bin/bash
# Why is the band 12%? The data to answer it is already on disk: v34 ran 6 x 8 = 48
# per-token wall times. The shape of the variation says which cause it is.
#
#   - a per-run CONSTANT offset (all 8 tokens of a run slow by the same factor) points at
#     something that is constant during a run and differs between runs: device throughput,
#     thermal state, or a cache/page state fixed at startup.
#   - BURSTS inside a run (one or two tokens far out, the rest normal) point at eviction
#     thrash, a reclaim event, or a foreign process.
#   - a monotone RAMP (successively slower) points at writeback, thermal drift, or an
#     accumulating resource.
#
# v33 already showed the work is byte-for-byte identical run to run, so this is not about
# the engine doing different work.
set -u
cd /mnt/f/kimi-k3-in-c

python3 - <<'PY'
import glob, os, re, statistics as st

rows=[]
for d in sorted(glob.glob("reports/gateab_ab/v34_ab/t*"))+sorted(glob.glob("reports/gateab_ab/v33_base640/rep*")):
    lg=os.path.join(d,"ctrl.log")
    if not os.path.exists(lg): continue
    per=[]
    for line in open(lg,errors="replace"):
        p=line.split()
        if len(p)>=3 and len(p[0])==1 and p[0].isdigit() and p[0] in "01234567":
            try: per.append((int(p[0]), float(p[2])))
            except ValueError: pass
    if len(per)!=8: continue
    per.sort()
    v=[t for _,t in per]
    med=st.median(v)
    name=os.path.basename(d)
    arm="t32c15" if "t32c15" in name else ("t6c40" if "t6c40" in name else "t6c40")
    rows.append((arm,name,v,med))

print("=== per-token wall times, all runs")
print("   %-7s %-22s %s   %6s %6s" % ("arm","run","per-token seconds","median","CV%"))
for arm,name,v,med in rows:
    cv=(max(v)-min(v))/med*100
    print("   %-7s %-22s %s  %6.2f %5.1f%%" %
          (arm,name[:22]," ".join("%5.1f"%x for x in v),med,cv))

print()
print("=== within-run shape: is the run uniformly slow, or does it have bursts?")
print("   %-7s %-22s %8s %8s %8s %8s" % ("arm","run","mean/med","max/med","tok0/med","last/med"))
for arm,name,v,med in rows:
    print("   %-7s %-22s %8.2f %8.2f %8.2f %8.2f" %
          (arm,name[:22], st.mean(v)/med, max(v)/med, v[0]/med, v[-1]/med))

print()
print("=== two sources of variance, separated")
for arm in ("t32c15","t6c40"):
    meds=[r[3] for r in rows if r[0]==arm]
    if len(meds)<2: continue
    # between-run: spread of the per-run medians
    between=(max(meds)-min(meds))/st.median(meds)*100
    # within-run: median of each run's own max/med
    w=[max(r[2])/r[3] for r in rows if r[0]==arm]
    print("   %-7s between-run medians %s -> %5.1f%%   within-run spread %5.1f%%" %
          (arm, " ".join("%6.2f"%m for m in meds), between, (max(w)-min(w))*0+100*(st.median(w)-1)))

print()
print("=== the two 32/15 runs that differ most (76.47 vs 68.00): where is the gap?")
a=[r for r in rows if r[1].startswith("t32c15")]
if len(a)>=2:
    a.sort(key=lambda r:st.median(r[2]))
    lo,hi=a[0],a[-1]
    print("   run %-20s %s" % (lo[1], " ".join("%5.1f"%x for x in lo[2])))
    print("   run %-20s %s" % (hi[1], " ".join("%5.1f"%x for x in hi[2])))
    print("   ratio slow/fast  %s" % " ".join("%5.2f"%(x/y) for x,y in zip(hi[2],lo[2])))
    print("   -> a flat ratio means a constant offset; rising/falling means burst or ramp")
PY