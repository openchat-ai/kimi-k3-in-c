#!/bin/bash
# v35: where does token 1's excess wall time actually go?
#
# The 6/40 arm ran 150-297 s on token 1 in five of six earlier runs. These two runs show
# 129.57 s and 146.12 s -- still clearly above the other tokens, but not the earlier
# magnitude. The get() instrumentation added zero rows, so cache_get is never called and
# the single-expert path is not the answer; the counters' 14.73 GB vs 137.01 GB gap is a
# definitional difference (phase 2 counts misses only, ~840 x 17.56 MB = 14.75 GB), not a
# second code path.
#
# So this looks straight at the trace: per token, per phase, the union of intervals, and
# what fraction of the engine's reported per-token wall each phase accounts for. If token 1
# is longer and the traced phases do NOT explain the extra, the time is outside every
# instrumented region and the next probe has to go somewhere else.
set -u
cd /mnt/f/kimi-k3-in-c

python3 - <<'PY'
import csv, glob, os, re, statistics as st

def union(iv):
    if not iv: return 0.0
    s=sorted(iv); tot=0.0; cs,ce=s[0]
    for a,b in s[1:]:
        if a>ce: tot+=ce-cs; cs,ce=a,b
        else: ce=max(ce,b)
    return tot+(ce-cs)

def walls(path):
    w={}
    for line in open(path,errors="replace"):
        p=line.split()
        if len(p)>=3 and len(p[0])==1 and p[0].isdigit() and p[0] in "01234567":
            try: w[int(p[0])]=float(p[2])
            except ValueError: pass
    return w

for d in sorted(glob.glob("reports/gateab_ab/v35_stall/rep*")):
    print("="*78)
    print(os.path.basename(d), " ", end="")
    for line in open(os.path.join(d,"state.txt"),errors="replace"):
        if "1min" in line: print(line.strip())
    W=walls(os.path.join(d,"ctrl.log"))
    per={}
    with open(os.path.join(d,"trace.csv"),newline="") as fh:
        for r in csv.DictReader(fh):
            per.setdefault(int(r["token"]),{}).setdefault(r["phase"],[]).append(
                (float(r["t0"]),float(r["t1"]),int(r["bytes"])))
    print()
    print("   %-6s %8s %8s %8s %9s %9s %9s %8s" %
          ("token","trunk","expert","compute","union","wall","unexpl","exp%"))
    for t in sorted(per):
        ph=per[t]
        Tv=union([(a,b) for a,b,_ in ph.get("trunk",[])])
        Ev=union([(a,b) for a,b,_ in ph.get("expert",[])])
        Cv=union([(a,b) for a,b,_ in ph.get("compute",[])])
        allu=union([(a,b) for v in ph.values() for a,b,_ in v])
        w=W.get(t,0.0)
        # where the traced span starts and ends, vs the engine's own wall
        alliv=[x for v in ph.values() for x in v]
        gap=0.0
        if alliv and w>0:
            s=sorted(alliv); span=s[-1][1]-s[0][0]
            gap=w-span
        print("   %-6d %8.2f %8.2f %8.2f %9.2f %9.2f %9.2f %7.1f%%" %
              (t,Tv,Ev,Cv,allu,w,gap, allu/w*100 if w else 0))
    print()
    # the biggest single traced event, which is where a 100 s stall would show
    print("   longest single traced events:")
    ev=[]
    for t in sorted(per):
        for ph,v in per[t].items():
            for a,b,n in v: ev.append((b-a,ph,t,n))
    ev.sort(reverse=True)
    for dur,ph,t,n in ev[:6]:
        print("      %7.2f s  token=%d  %-8s %.2f GB" % (dur,t,ph,n/1e9))
    print()
PY