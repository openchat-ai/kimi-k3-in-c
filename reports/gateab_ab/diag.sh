#!/bin/bash
echo "== k3/ab6 alive:"
for p in /proc/[0-9]*; do
  c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$c" in
    *'bin/k3'*) echo "PID=${p#/proc/} CMD=$c";;
    *'ab6.sh'*) echo "PID=${p#/proc/} AB6=$c";;
  esac
done
echo "== ab6_run.log tail:"
tail -5 /mnt/f/kimi-k3-in-c/reports/gateab_ab/ab6_run.log 2>/dev/null || echo "no log"
echo "== runoff dirs:"
ls -d /mnt/f/kimi-k3-in-c/reports/gateab_ab/v4_native-* 2>/dev/null || echo "none"