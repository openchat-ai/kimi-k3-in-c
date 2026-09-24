#!/bin/bash
pkill -f probe_duallane.py 2>/dev/null
sleep 1
pkill -f probe_duallane.sh 2>/dev/null
sleep 1
nohup bash /mnt/f/kimi-k3-in-c/reports/probe_duallane.sh >/tmp/relaunch_duallane.log 2>&1 &
echo "launched $(date +%H:%M:%S)"