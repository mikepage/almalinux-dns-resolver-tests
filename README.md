# almalinux-dns-resolver-tests

Offline Docker lab that compares DNS resolver setups on AlmaLinux 9 and 10 when a VPS provider's
internal DNS resolvers fail. Detailed numbers: [results/README.md](results/README.md).

## Conclusion

Run **local unbound with full recursion** on every VM. It asks the authoritative servers
itself (root, TLD, the domain's nameservers), so it needs no provider, Google or Cloudflare
resolver, and no resolver failure can take DNS down.

| Setup | One provider resolver down | Both down | After recovery |
|---|---|---|---|
| **unbound, full recursion** | **no impact** | **no impact** | **no impact** |
| unbound, forwarding to provider, tuned | first lookup ≤ 0.4 s | first lookup ~0.7 s | back within ~60 s |
| unbound, forwarding, defaults | first lookup ≤ 0.4 s | all lookups fail ~5 min | back on provider |
| resolved, public resolver in `DNS=` | first lookup 5 s | first lookup 10 s | stuck on public resolver |
| resolved, `FallbackDNS=` public | first lookup 5 s | **DNS down**, 10 s per lookup | ok |
| glibc, provider resolvers | every lookup +5 s | **DNS down**, 20 s per lookup | ok |

AlmaLinux 9 and 10 give the same results (same unbound 1.24.2; systemd 252 vs 257).

Key findings:

- `FallbackDNS=` is never used while `DNS=` is set. It is not a fallback.
- resolved doesn't switch back after failing over to a later `DNS=` entry.
- `StaleRetentionSec=` needs systemd 254+ (EL9 has 252). On EL10 (257) it didn't produce stale
  answers in the lab: resolved only gives up on its upstreams after up to 120 s, long after
  glibc's 10 s.
- glibc has no memory of dead servers and uses at most 3 `nameserver` lines.
- A 15 s TTL database record that changes IP: every setup picks up the new IP within its TTL.
  With both provider resolvers down, only both unbound setups (≤ 9 s) and resolved with a
  public `DNS=` entry (20 s) get it; the others fail.

Lab caveats: the authoritative servers are local, so recursion looks as fast as forwarding;
on the internet a cache miss takes tens of ms. Docker Desktop steps the clock every 30 s and
resolved flushes its cache on every clock step, so resolved's cache results are pessimistic.

## Preferred config

`/etc/unbound/conf.d/local.conf` (lab version: [`config/unbound-recursive-client.conf`](config/unbound-recursive-client.conf)):

```
server:
  interface: 127.0.0.1
  prefetch: yes
  serve-expired: yes
  serve-expired-ttl: 86400
  serve-expired-client-timeout: 1800   # never 0: it serves expired records first
  msg-cache-size: 64m
  rrset-cache-size: 128m
  # keep the default DNSSEC validator + root trust anchor

# Local copy of the root zone (RFC 8806)
auth-zone:
  name: "."
  primary: 170.247.170.2   # b.root-servers.net
  primary: 192.33.4.12     # c.root-servers.net
  primary: 192.5.5.241     # f.root-servers.net
  primary: 193.0.14.129    # k.root-servers.net
  fallback-enabled: yes
  for-downstream: no
  for-upstream: yes
```

Plus:

- `/etc/resolv.conf`: `nameserver 127.0.0.1` only.
- NetworkManager `dns=none`, systemd-resolved disabled.
- systemd drop-in for unbound: `Restart=always`.
- Never set `cache-min-ttl`: it breaks low-TTL failover records.

No forwarders: no Google, no Cloudflare, no provider resolver. The usual public list
(`8.8.8.8`, `8.8.4.4`, `2001:4860:4860::8888`, `2001:4860:4860::8844`, `1.1.1.1`, `1.0.0.1`,
`2606:4700:4700::1111`, `2606:4700:4700::1001`) isn't needed.

Need the provider's resolvers anyway? Use [`config/unbound-client.conf`](config/unbound-client.conf):
forwarding with `forward-first: yes`, `infra-cache-max-rtt: 500` and `infra-host-ttl: 60`.
See [unbound tuning results](results/README.md#unbound-tuning-results) for why both settings matter.

## Lab

| Node | IP | Role |
|---|---|---|
| root | 10.53.0.5 | nsd: fake root and `test.` zone (the "internet") |
| provider-dns1/2 | .11 / .12 | provider's internal resolvers |
| public-dns | .53 | public resolver |
| client-glibc / -tuned | .101 / .102 | resolv.conf with provider resolvers, default / `timeout:1 attempts:2` |
| client-resolved / -public | .103 / .104 | systemd-resolved, `FallbackDNS=` public / public as third `DNS=` |
| client-unbound | .105 | unbound forwarding to providers, tuned |
| client-recursive | .106 | unbound full recursion, local root zone |

`almalinux/9-init` (systemd 252) or `almalinux/10-init` (systemd 257) containers with real
systemd. Lookups go through glibc (`getent ahosts`).

```bash
docker compose up -d --build        # AlmaLinux 9; EL=10 for AlmaLinux 10
tests/run.sh                        # all failure scenarios, ~7 min
tests/unbound-tuning.sh             # forwarding infra-* variants, ~11 min
tests/db-failover.sh                # 15 s TTL record changes IP
tests/db-failover.sh providers-down
```

## Check in production

The lab can't show real cache-miss latency. On a server with local unbound, after a day:

```bash
unbound-control stats_noreset | grep -E '^total\.(recursion\.time\.(median|avg)|num\.(queries|cachehits|cachemiss|expired))='
```

- `total.recursion.time.median`: typical cache-miss time. Expect tens of ms.
- `total.recursion.time.avg`: far above the median means slow or dead authoritative servers.
- `cachehits` / `queries`: share answered from cache (~0.1 ms).
- `expired` / `queries`: share answered stale. Should stay well below 1%.

A cache miss only delays the one lookup that misses: a new database connection waits one
extra round trip to the authoritative servers, roughly 10–30 ms, at most once per TTL.
Queries on an open connection don't use DNS. `prefetch` refreshes busy names before they
expire, so most lookups never miss.

## Not tested yet

- On a Linux host without clock steps: resolved's `StaleRetentionSec=` on EL10.

- Full recursion against real domains: slow authoritative servers.
- IPv6 and TCP fallback.
- Load (`dnsperf`).
