#!/usr/bin/env bash
# Managed-database failover: the database hostname has a 15 s TTL, like a cloud provider's
# managed database record. Its IP changes. How long does each client keep returning the old IP?
#   tests/db-failover.sh                 providers healthy
#   tests/db-failover.sh providers-down  provider resolvers time out during the failover
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:-normal}
NAME=mysql.db.lab.test
OLD=10.20.0.1 NEW=10.20.0.2
CLIENTS=(client-glibc client-glibc-tuned client-resolved client-resolved-public client-unbound client-recursive)

dc() { docker compose "$@"; }
ex() { dc exec -T "$@"; }

set_ip() { # <ip>: rewrite the record, bump the serial, reload nsd
  ex root sh -c "sed -e 's/^mysql.db.lab .*/mysql.db.lab 15 A $1/' \
    -e 's/hostmaster.test. [0-9]*/hostmaster.test. $(date +%s)/' /etc/lab/zones/test.zone > /tmp/test.zone
    cp /tmp/test.zone /etc/lab/zones/test.zone && systemctl reload nsd"
}

reset() {
  dc unpause provider-dns1 provider-dns2 >/dev/null 2>&1 || true
  set_ip "$OLD"
  for s in provider-dns1 provider-dns2; do ex "$s" systemctl restart unbound; done
  ex client-resolved systemctl restart systemd-resolved
  ex client-resolved-public systemctl restart systemd-resolved
  ex client-unbound sh -c 'iptables -F OUTPUT; systemctl restart unbound'
  ex client-recursive systemctl restart unbound
  sleep 2
}

# Polls every 0.5 s for up to 90 s. Prints seconds until the new IP, and how many
# lookups returned the old IP or failed.
watch_client() { # <client> <t0 ns>
  ex "$1" sh -c "t0=$2 old=0 fail=0
    while :; do
      ip=\$(timeout 30 getent ahostsv4 $NAME | awk 'NR==1{print \$1}')
      now=\$(date +%s%N); s=\$(( (now - t0) / 1000000 ))
      case \"\$ip\" in
        $NEW) awk -v c=$1 -v s=\$s -v o=\$old -v f=\$fail 'BEGIN{printf \"%-24s %8.1f %5d %5d\n\", c, s/1000, o, f}'; exit ;;
        $OLD) old=\$((old + 1)) ;;
        *)    fail=\$((fail + 1)) ;;
      esac
      [ \$s -gt 90000 ] && { printf '%-24s %8s %5d %5d\n' $1 '>90' \$old \$fail; exit; }
      sleep 0.5
    done"
}

reset
# Warm every cache, including the provider resolvers, with the old IP.
for c in "${CLIENTS[@]}"; do ex "$c" getent ahostsv4 "$NAME" >/dev/null; done
sleep 5

[ "$MODE" = providers-down ] && dc pause provider-dns1 provider-dns2 >/dev/null

set_ip "$NEW"
t0=$(date +%s%N)

mkdir -p results
out="results/db-failover-$MODE-$(date +%Y%m%d-%H%M%S).txt"
{
  printf '%-24s %8s %5s %5s\n' client new_ip_s old fail
  pids=()
  for c in "${CLIENTS[@]}"; do watch_client "$c" "$t0" & pids+=($!); done
  wait "${pids[@]}"
} | sort -k1 | tee "$out"
reset >/dev/null 2>&1
echo "saved: $out" >&2
