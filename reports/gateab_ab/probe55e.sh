#!/bin/bash
# The concurrency curve in v55 is only meaningful if dd actually moved the bytes it claims.
# The source is one file from the trunk directory; if that file is smaller than the 2 GiB the
# arms ask for, dd stops at end of file and every rate is a rate over less work than reported.
set -u
D=/mnt/nvme/trunk_layers_out
echo "== largest files"
ls -lS "$D" | head -4 | sed 's/^/  /'
BIG=$(ls -S "$D" | head -1)
SZ=$(stat -c %s "$D/$BIG")
echo
echo "  source: $BIG  $SZ bytes = $((SZ/1048576)) MiB"
echo "  arms request: 2 GiB total, per stream 2GiB/ns"
echo "  32 streams would need $((2147483648/32)) bytes each"

if [ "$SZ" -lt 2147483648 ]; then
  echo "  ** source is SMALLER than 2 GiB -- dd hit EOF **"
  echo "  ** every arm read at most $((SZ/1048576)) MiB per stream, not $((2147483648/32/1048576)) **"
else
  echo "  source is larger than 2 GiB, arms are not truncated"
fi

echo
echo "== what dd reported for the biggest arms: byte totals vs what was asked"
OUT=reports/gateab_ab/v55_stream/raw.txt
if [ -r "$OUT" ]; then
  echo "  label                     bs    n   rate"
  sed 's/^/    /' "$OUT"
else
  echo "  no raw.txt"
fi

echo
echo "== the log's own copy of dd's output, if it was kept"
ls -l /tmp/tmp.* 2>/dev/null | head -5 | sed 's/^/  /' || echo "  temp files cleaned up (they are removed on success)"

echo
echo "== re-measure one arm and compare bytes asked vs bytes delivered"
F="$D/$BIG"
ask=$((2147483648/16/4194304))
dd if="$F" of=/dev/null bs=4M count=$ask iflag=direct 2>&1 | tail -1 | sed 's/^/  16 streams, asked 16x'"$ask"' blocks: /'
