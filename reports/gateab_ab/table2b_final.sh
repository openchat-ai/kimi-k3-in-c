#!/bin/bash
# All three reps: does the mutually-exclusive decomposition close every time?
#
# A table that reconciles on one run is luck. This checks the identity
#     trunk_disjoint + (compute - expert) + expert == union_wall
# on each rep separately, and reports the spread of every column across reps, because a
# column that moves more than the run-to-run band cannot go in the paper as a number.
set -u
cd /mnt/f/kimi-k3-in-c

for d in reports/gateab_ab/v32_table2b/rep*; do
  echo "=== $(basename $d)"
  echo "    $(grep -a 's/token average' $d/ctrl.log)"
  echo "    $(grep -a 'load_before\|load_after' $d/baseline.txt | tr '\n' ' ')"
  echo
done

python3 - <<'PY'
import csv, glob, os

def union(iv):
    if not iv: return 0.0
    s=sorted(iv); tot=0.0; cs,ce=s[0]
    for a,b in s[1:]:
        if a>ce: tot+=ce-cs; cs,ce=a,b
        else: ce=max(ce,b)
    return tot+(ce-cs)

def walls_of(path):
    w={}
    for line in open(path,errors="replace"):
        p=line.split()
        if len(p)>=3 and len(p[0])==1 and p[0].isdigit() and p[0] in "01234567":
            try: w[int(p[0])]=float(p[2])
            except ValueError: pass
    return w

print("=== steady state = tokens 1..7 (token 0 is the cold start, reported separately)")
print()
hdr = "   %-6s %8s %8s %8s %8s %8s %8s" % ("rep","trunk","expert","pure","union","wall","closed")
print(hdr)
cols={k:[] for k in ("trunk","expert","pure","union","wall")}
reps=sorted(glob.glob("reports/gateab_ab/v32_table2b/rep*"))
for d in reps:
    per={}
    with open(os.path.join(d,"trace.csv"),newline="") as fh:
        for r in csv.DictReader(fh):
            per.setdefault(int(r["token"]),{}).setdefault(r["phase"],[]).append(
                (float(r["t0"]),float(r["t1"])))
    W=walls_of(os.path.join(d,"ctrl.log"))
    tr=ex=pu=un=0.0
    for t in range(1,8):
        ph=per.get(t,{})
        Tv=union([(a,b) for a,b in ph.get("trunk",[])])
        Ev=union([(a,b) for a,b in ph.get("expert",[])])
        Cv=union([(a,b) for a,b in ph.get("compute",[])])
        allu=union([x for v in ph.values() for x in v])
        tr+=Tv; ex+=Ev; pu+=(Cv-Ev); un+=allu
    n=7
    tr/=n; ex/=n; pu/=n; un/=n
    w=sum(W[t] for t in range(1,8))/n
    for k,v in zip(("trunk","expert","pure","union","wall"),(tr,ex,pu,un,w)): cols[k].append(v)
    closed = abs((tr+pu+ex)-un)
    print("   %-6s %8.2f %8.2f %8.2f %8.2f %8.2f %8.4f" %
          (os.path.basename(d)[:4], tr,ex,pu,un,w,closed))
print()
print("=== the identity: trunk + pure + expert == union   (closed must be ~0)")
print()
print("=== spread across the 3 reps, in % of median  (paper needs this << 3.4% band)")
for k,v in cols.items():
    med=sorted(v)[1]
    sp=(max(v)-min(v))/med*100
    print("   %-6s %s  median %7.2f  spread %5.1f%%" % (k, ["%7.2f"%x for x in v], med, sp))
print()
print("=== shares of wall, median rep")
med={k:sorted(v)[1] for k,v in cols.items()}
tot=med["union"]
for k in ("expert","pure","trunk"):
    print("   %-6s %7.2f s  %5.1f%%" % (k, med[k], med[k]/tot*100))
print("   %-6s %7.2f s  %5.1f%%  (sum of shares above must be 100)" % ("union", tot, 100.0))
PY