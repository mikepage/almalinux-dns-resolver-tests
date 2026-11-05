#!/usr/bin/env bash
# Tests client-unbound with different infra-* settings:
#   failover: both provider resolvers time out. How long until unbound answers by
#             resolving from the root itself (forward-first)?
#   recovery: providers back for 70 s, then the root is blocked for client-unbound.
#             Only answers via the providers succeed: did unbound go back to them?
#   tests/unbound-tuning.sh
set -euo pipefail
cd "$(dirname "$0")/.."

dc() { docker compose "$@"; }
ex() { dc exec -T client-unbound "$@"; }

VARIANTS=(
  "defaults|"
  "max-rtt 1500|infra-cache-max-rtt: 1500"
  "max-rtt 500|infra-cache-max-rtt: 500"
  "max-rtt 500, host-ttl 60|infra-cache-max-rtt: 500\n  infra-host-ttl: 60"
)

reset() {
  dc unpause provider-dns1 provider-dns2 >/dev/null 2>&1 || true
  ex iptables -F OUTPUT
}

configure() { # <settings, \n separated>
  ex sh -c "sed -e '/^  infra-cache-max-rtt:/d' -e '/^  infra-host-ttl:/d' \
    -e 's|^  prefetch: yes|  prefetch: yes\n  $1|' /etc/lab/unbound-client.conf > /etc/unbound/unbound.conf
    systemctl restart unbound"
}

# Prints "<ok> <ms>" per lookup.
lookups() { # <count> <dig timeout s>
  ex sh -c "for i in \$(seq 1 $1); do
    t0=\$(date +%s%N)
    r=\$(dig +time=$2 +tries=1 +short v\$RANDOM\$RANDOM.lab.test @127.0.0.1 2>/dev/null)
    case \"\$r\" in 10.*) ok=1 ;; *) ok=0 ;; esac
    echo \"\$ok \$(( (\$(date +%s%N) - t0) / 1000000 ))\"
  done"
}

mkdir -p results
out="results/el${EL:-9}-unbound-tuning-$(date +%Y%m%d-%H%M%S).txt"
{
  printf '%-26s %-12s %-22s %-12s\n' variant failover_ok first_answer_after_ms recovery_ok
  for v in "${VARIANTS[@]}"; do
    name=${v%%|*} settings=${v#*|}
    reset
    configure "$settings"
    sleep 1

    dc pause provider-dns1 provider-dns2 >/dev/null 2>&1
    fo=$(lookups 6 60)
    fo_ok=$(awk '{s += $1} END {print s}' <<<"$fo")
    first=$(awk '{t += $2} $1 == 1 {print t; exit}' <<<"$fo")

    dc unpause provider-dns1 provider-dns2 >/dev/null 2>&1
    sleep 70
    ex iptables -A OUTPUT -d 10.53.0.5 -j REJECT
    re_ok=$(lookups 5 5 | awk '{s += $1} END {print s}')

    printf '%-26s %-12s %-22s %-12s\n' "$name" "$fo_ok/6" "${first:-none}" "$re_ok/5"
  done
  reset
  configure "infra-cache-max-rtt: 500\n  infra-host-ttl: 60"
} | tee "$out"
echo "saved: $out" >&2
