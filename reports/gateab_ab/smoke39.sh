#!/bin/bash
# 30-second smoke test of probe39's precondition writer, at 1/1000 scale.
# The point is to prove the file is actually NON-sparse (real writes reach the drive), since
# a sparse file would silently leave the device cache untouched and the whole run would be
# measuring a cold drive while claiming to measure a full one.
set -u
cd /mnt/f/kimi-k3-in-c
python3 - <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("p39", "reports/gateab_ab/probe39.py")
m = importlib.util.module_from_spec(spec)
sys.modules["p39"] = m
# import without running main()
src = open("reports/gateab_ab/probe39.py").read().replace('if __name__ == "__main__":\n    main()', '')
exec(compile(src, "probe39.py", "exec"), m.__dict__)

m.PRECOND_GB = 0.04          # 40 MB instead of 40 GB
m.precondition()

p = m.PRECOND_PATH
st = os.stat(p)
apparent = st.st_size
allocated = st.st_blocks * 512
print()
print("   apparent size : %d B" % apparent)
print("   allocated     : %d B   (%.1f%% of apparent)"
      % (allocated, 100.0 * allocated / apparent if apparent else 0))
print("   VERDICT: %s" % ("REAL writes, cache will be filled" if allocated >= apparent * 0.9
                         else "SPARSE -- the run would be measuring a cold drive"))
os.unlink(p)
print("   cleaned up")
PY
