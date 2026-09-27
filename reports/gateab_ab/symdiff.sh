#!/bin/bash
set -u
A=/root/k3_0859
B=/mnt/f/kimi-k3-in-c/bin/k3
dump_syms() {
  objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk '
    /^[0-9a-f]+ <.*>:$/ { line=$0; sub(/^[0-9a-f]+ </,"",line); sub(/>:$/,"",line); cur=line; next }
    /^[[:space:]]+[0-9a-f]+:/ { if (cur != "") n[cur]++ }
    END { for (k in n) printf "%d %s\n", n[k], k }' | sort -k2
}
dump_syms "$A" > /root/sym_old.txt
dump_syms "$B" > /root/sym_new.txt
echo "old symbols: $(wc -l < /root/sym_old.txt)   today: $(wc -l < /root/sym_new.txt)"
echo
echo "== hot path (instruction count old / today):"
printf "%-36s %8s %8s\n" SYMBOL OLD TODAY
for s in k3_io_tier_main k3_io_submit_g k3_io_submit k3_io_submit_write k3_io_set_active \
         cache_getmany_inner k3_cache_getmany k3_trunk_load_run load_run \
         k3_l2_load_direct k3_st_read_direct k3_bind_layer forward main; do
  o=$(awk -v k="$s" '$2==k{print $1; exit}' /root/sym_old.txt)
  n=$(awk -v k="$s" '$2==k{print $1; exit}' /root/sym_new.txt)
  if [ -n "$o" ] || [ -n "$n" ]; then printf "%-36s %8s %8s\n" "$s" "${o:--}" "${n:--}"; fi
done
echo
echo "== biggest absolute deltas across ALL shared symbols:"
join -j 2 /root/sym_old.txt /root/sym_new.txt 2>/dev/null | awk '{d=$3-$2; if (d<0) d=-d; if (d>40) printf "%7d  old=%-7d new=%-7d %s\n", d, $2, $3, $1}' | sort -rn | head -18