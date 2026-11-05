#!/bin/bash
# Runs inside a client. Resolves names through glibc (getent), like PHP or curl would.
#   measure.sh <scenario> unique <n>       n cache-miss names (u<random>.lab.test)
#   measure.sh <scenario> name <fqdn> <n>  the same name n times
set -uo pipefail

scenario=$1 kind=$2
if [ "$kind" = unique ]; then n=$3; else name=$3 n=$4; fi
client=$(cat /proc/sys/kernel/hostname)

ok=0 fail=0 times=()
for i in $(seq 1 "$n"); do
  q=${name:-u$RANDOM$RANDOM-$i.lab.test}
  t0=$(date +%s%N)
  if timeout 30 getent ahosts "$q" >/dev/null 2>&1; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
  times+=($(( ($(date +%s%N) - t0) / 1000000 )))
done

printf '%s\n' "${times[@]}" | sort -n | awk -v c="$client" -v s="$scenario" -v ok=$ok -v fail=$fail '
  { t[NR] = $1 }
  END {
    p50 = t[int((NR + 1) / 2)]; p95 = t[int(NR * 0.95 + 0.999)]
    printf "%-16s %-24s %3d/%-3d %7d %7d %7d\n", s, c, ok, ok + fail, p50, p95, t[NR]
  }'
