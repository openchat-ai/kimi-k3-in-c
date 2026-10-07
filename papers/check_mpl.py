import matplotlib
print("matplotlib", matplotlib.__version__)
import pathlib
for p in sorted(pathlib.Path("docs/images").glob("*.png")):
    print("  %8d  %s" % (p.stat().st_size, p.name))