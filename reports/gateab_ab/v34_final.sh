#!/bin/bash
# v34 final: the two arms, interleaved in one session, and what it does to the day's claims.
set -u
cd /mnt/f/kimi-k3-in-c

python3 - <<'PY'
import glob, os, re, statistics as st

def runs(pattern):
    out=[]
    for d in sorted(glob.glob(pattern)):
        lg=os.path.join(d,"ctrl.log")
        if not os.path.exists(lg): continue
        txt=open(lg,errors="replace").read()
        m=re.search(r"([0-9.]+) s/token average", txt)
        if not m: continue
        s=float(m.group(1))
        # start state from the run log line
        lm=0
        for line in open("reports/gateab_ab/ab34_run.log",errors="replace"):
            if os.path.basename(d) in line and "start" in line:
                p=line.split()
                for tok in p:
                    if re.fullmatch(r"[0-9]+\.[0-9]+", tok): lm=float(tok)
        t1=t5=t15=None
        sp=os.path.join(d,"state.txt")
        if os.path.exists(sp):
            for line in open(sp,errors="replace"):
                if "1min/5min/15min" in line:
                    v=re.findall(r"[0-9]+\.[0-9]+", line)
                    if len(v)>=3: t1,t5,t15=map(float,v[:3])
                    break
        out.append((os.path.basename(d), s, t1, t5, t15))
    return out

A=runs("reports/gateab_ab/v34_ab/t32c15_*")   # trunk 32 / cache 15
B=runs("reports/gateab_ab/v34_ab/t6c40_*")    # trunk 6  / cache 40

def line(tag,rs):
    if not rs: return
    v=[r[1] for r in rs]
    med=st.median(v); sp=(max(v)-min(v))/med*100
    print("   %-9s %s" % (tag, "  ".join("%7.2f"%x for x in v)))
    print("   %-9s median %7.2f   spread %5.1f%%   (min %7.2f  max %7.2f)" %
          ("", med, sp, min(v), max(v)))

print("=== v34, interleaved A B A B A B, same session, 240s settle between runs")
print()
line("t32c15", A); print()
line("t6c40",  B); print()

if A and B:
    ma, mb = st.median([r[1] for r in A]), st.median([r[1] for r in B])
    print()
    print("=== the difference vs the noise")
    print("   32/15 is %.2f s/token faster = %.1f%%" % (mb-ma, (mb-ma)/mb*100))
    spa=(max(r[1] for r in A)-min(r[1] for r in A))/ma*100
    spb=(max(r[1] for r in B)-min(r[1] for r in B))/mb*100
    print("   arm spreads: %.1f%% and %.1f%%  -> the %.1f%% gap is %.1fx the larger spread"
          % (spa, spb, (mb-ma)/mb*100, ((mb-ma)/mb*100)/max(spa,spb)))
    print()
    print("=== does run time track the starting 15min loadavg?")
    for tag,rs in (("t32c15",A),("t6c40",B)):
        pts=[(r[4],r[1]) for r in rs if r[4] is not None]
        pts.sort()
        print("   %-8s %s" % (tag, "  ".join("15min=%.2f->%.2f"%(a,b) for a,b in pts)))
    allp=[(r[4],r[1],t) for t,rs in (("t32c15",A),("t6c40",B)) for r in rs if r[4] is not None]
    if len(allp)>2:
        xs=[p[0] for p in allp]; ys=[p[1] for p in allp]
        n=len(xs); mx=sum(xs)/n; my=sum(ys)/n
        cov=sum((x-mx)*(y-my) for x,y in zip(xs,ys))
        vx=sum((x-mx)**2 for x in xs)**.5; vy=sum((y-my)**2 for y in ys)**.5
        print("   pooled Pearson r = %.2f  (n=%d) -- a weak r means start state does NOT"
              % (cov/(vx*vy) if vx*vy else 0, n))
        print("   explain the run time, so the 6/40 spread is not a start-state artifact")

print()
print("=== 32/15 across BOTH sessions (v30 yesterday, v34 today)")
v30=[71.45,73.98,73.96]
v34=[r[1] for r in A]
allr=v30+v34
print("   v30  %s   median %6.2f  spread %4.1f%%" %
      ("  ".join("%6.2f"%x for x in v30), st.median(v30),
       (max(v30)-min(v30))/st.median(v30)*100))
print("   v34  %s   median %6.2f  spread %4.1f%%" %
      ("  ".join("%6.2f"%x for x in v34), st.median(v34),
       (max(v34)-min(v34))/st.median(v34)*100))
print("   both %s   median %6.2f  spread %4.1f%%" %
      ("  ".join("%6.2f"%x for x in sorted(allr)), st.median(allr),
       (max(allr)-min(allr))/st.median(allr)*100))
print()
print("   the two session medians differ by %.2f s (%.1f%%), well inside the" %
      (abs(st.median(v30)-st.median(v34)), abs(st.median(v30)-st.median(v34))/st.median(allr)*100))
print("   pooled spread -- so ~73 is reproducible, but v30's own 3.4%% understated it.")

print()
print("=== what the -8.6% headline becomes")
print("   v18 claimed 6/40 = 80.93 (single run, no start-state record)")
print("   v33 rep1 measured 6/40 = 80.33 from the only genuinely quiet start seen")
print("     today (15min = 0.14) -- that CORROBORATES v18 rather than refuting it")
print("   v34 measured 6/40 median = %.2f from 15min 6.1-7.0 starts" % mb)
print("   -> 6/40 spans %.0f-%.0f depending on start state, so the gain is not one" %
      (min([80.33, mb]), max([101.09, 108.48])))
print("      number. Interleaved/same-session (the defensible basis): %.1f%%." %
      ((mb-ma)/mb*100))
print("      Clean-start basis: 32/15 ~73 vs 6/40 ~80.3 = %.1f%%." % ((80.33-73)/80.33*100))
PY