#!/usr/bin/env bash
# Runs every failure scenario against every client and prints one table.
#   tests/run.sh                 all scenarios
#   tests/run.sh dns1-timeout    one scenario
#   N=20 tests/run.sh            more queries per client (default 5)
set -euo pipefail
cd "$(dirname "$0")/.."

N=${N:-5}
CLIENTS=(client-glibc client-glibc-tuned client-resolved client-resolved-public client-unbound client-recursive)
SERVERS=(root provider-dns1 provider-dns2 public-dns)

dc() { docker compose "$@"; }
ex() { dc exec -T "$@"; }

# Back to a healthy lab with cold caches and no learned "bad server" state.
reset() {
  local s c
  for s in "${SERVERS[@]}"; do dc unpause "$s" >/dev/null 2>&1 || true; done
  dc start "${SERVERS[@]}" >/dev/null 2>&1
  for s in provider-dns1 provider-dns2 public-dns; do
    ex "$s" sh -c 'iptables -F OUTPUT; systemctl restart unbound'
  done
  ex client-resolved systemctl restart systemd-resolved
  ex client-resolved-public systemctl restart systemd-resolved
  ex client-unbound sh -c 'iptables -F OUTPUT; systemctl restart unbound'
  ex client-recursive systemctl restart unbound
  for c in "${CLIENTS[@]}"; do
    for _ in $(seq 1 30); do ex "$c" getent ahosts www.lab.test >/dev/null 2>&1 && break; sleep 1; done
  done
}

measure() { # <scenario> <measure.sh args...>
  local c
  local pids=()
  for c in "${CLIENTS[@]}"; do ex "$c" /lab/tests/measure.sh "$@" & pids+=($!); done
  wait "${pids[@]}"
}

s_baseline()       { measure baseline unique "$N"; }
# Provider resolver 1 drops packets: every query to it times out.
s_dns1_timeout()   { dc pause provider-dns1 >/dev/null; measure dns1-timeout unique "$N"; }
# Provider resolver 1 is gone: no host, ARP fails, ICMP unreachable.
s_dns1_down()      { dc stop -t 0 provider-dns1 >/dev/null 2>&1; measure dns1-down unique "$N"; }
# Provider resolver 1 answers, but SERVFAIL (it cannot reach the internet).
s_dns1_servfail()  { ex provider-dns1 iptables -A OUTPUT -d 10.53.0.5 -j REJECT; measure dns1-servfail unique "$N"; }
# Both provider resolvers time out (provider incident).
s_provider_down()  { dc pause provider-dns1 provider-dns2 >/dev/null; measure provider-down unique "$N"; }
# Provider and the public resolver unreachable; the internet itself still works.
s_resolvers_down() { dc pause provider-dns1 provider-dns2 public-dns >/dev/null; measure resolvers-down unique "$N"; }
# Nothing upstream answers. A name cached earlier (TTL 5s) has expired: is it served stale?
s_total_outage() {
  for c in "${CLIENTS[@]}"; do ex "$c" getent ahosts short.lab.test >/dev/null || true; done
  sleep 8
  dc pause "${SERVERS[@]}" >/dev/null
  measure total-outage name short.lab.test 3
}
# Providers fail, clients fail over, providers come back. Do clients go back to them?
# Afterwards only the provider path works: public resolver paused, and client-unbound
# blocked from recursing itself. A client still pinned to its fallback pays for it here.
# client-recursive never uses the providers, so it is not blocked.
s_recovery() {
  dc pause provider-dns1 provider-dns2 >/dev/null
  measure failover unique 3 >/dev/null
  dc unpause provider-dns1 provider-dns2 >/dev/null
  sleep 70
  for c in client-resolved client-resolved-public; do
    echo "# $c $(ex "$c" resolvectl status | grep -m1 'Current DNS Server' | xargs)"
  done
  dc pause public-dns >/dev/null
  ex client-unbound iptables -A OUTPUT -d 10.53.0.5 -j REJECT
  measure recovered unique "$N"
}

ALL=(baseline dns1-timeout dns1-down dns1-servfail provider-down resolvers-down total-outage recovery)
SCENARIOS=("${@:-${ALL[@]}}")

mkdir -p results
out="results/$(date +%Y%m%d-%H%M%S).txt"
{
  printf '%-16s %-24s %7s %7s %7s %7s\n' scenario client ok p50_ms p95_ms max_ms
  for sc in "${SCENARIOS[@]}"; do
    reset
    "s_${sc//-/_}" | sort -k2
  done
  reset
} | tee "$out"
echo "saved: $out" >&2
