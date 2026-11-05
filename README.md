# almalinux-dns-resolver-tests

Compares resolver setups on AlmaLinux 9 when the VPS provider's internal DNS resolvers fail.
Fully offline: a fake root and `test.` zone stand in for the internet.

## Conclusion

**Best setup:** local unbound on every VM doing **full recursion**: no forwarders, a local
copy of the root zone, `serve-expired`. It doesn't use the provider's resolvers at all, so no
provider resolver failure affects it, and there is no failover to tune.
See [Recommended setup](#recommended-setup).

**Second best:** local unbound **forwarding** to the provider resolvers with
`forward-first: yes`, `infra-cache-max-rtt: 500` and `infra-host-ttl: 60`. Use it only when
you need the provider's resolvers, for example for provider-internal names or when outbound
DNS is blocked. Without the two `infra-*` settings it is much worse,
see [Unbound tuning results](#unbound-tuning-results).

### Expected downtime when both provider resolvers go down

| Setup | During the outage | After the providers recover |
|---|---|---|
| **unbound, full recursion (recommended)** | **No impact.** Never uses the providers | No impact |
| unbound, forwarding, tuned | No downtime. First lookup takes ~0.7 s, then normal | Back on the providers within ~60 s |
| unbound, forwarding, defaults | All lookups fail for ~5 min, then normal | Back on the providers |
| resolved, public resolver in `DNS=` | First lookup takes ~10 s, then normal | Stays on the public resolver until it fails or resolved restarts |
| **resolved, `FallbackDNS=` public** | **Down for the whole outage.** Every lookup fails after 10 s | OK |
| glibc only (EL default) | Down for the whole outage. Every lookup fails after 20 s | OK |
| glibc, `timeout:1 attempts:2` | Down for the whole outage. Every lookup fails after 4 s | OK |

With `FallbackDNS=` a provider DNS outage is a full DNS outage for as long as it
lasts, and every lookup blocks for 10 s before failing.

### When only one provider resolver goes down

| Setup | Impact |
|---|---|
| unbound, full recursion | None |
| unbound, forwarding, tuned | First lookup up to 0.4 s, then normal |
| resolved (both configs) | First lookup 5 s, then normal |
| glibc only | Every lookup 5 s slower for the whole outage |
| glibc, `timeout:1 attempts:2` | Every lookup 1 s slower for the whole outage |

### Managed database failover (15 s TTL)

A managed database hostname with a 15 s TTL changes IP. Seconds until each client returns the
new IP (cache warmed 5 s before the change, so ~10 s of TTL left):

| Setup | Providers healthy | Providers down |
|---|---:|---|
| unbound, full recursion | 8.6 | 8.1 |
| unbound, forwarding, tuned | 10.1 | 8.7 |
| resolved, public resolver in `DNS=` | 10.1 | 20.2 |
| resolved, `FallbackDNS=` public | 10.1 | **never**: old IP until expiry, then failures |
| glibc only | 10.0 | **never**: every lookup fails |
| glibc, `timeout:1 attempts:2` | 10.1 | **never**: every lookup fails |

No client kept the old IP past its TTL, including through two caches (provider + local).
Never set `cache-min-ttl`: it would keep the old IP after a failover. Keep
`serve-expired-client-timeout` above 0: with 0, unbound serves an expired IP right away even
when the authoritative server is reachable.

Caveat: lab numbers, one run with 5 lookups per client. In the lab the authoritative servers
are local, so full-recursion cache misses are as fast as forwarding; on the internet they take
tens of ms. See [Not tested yet](#not-tested-yet).

## Results (2026-11-05, N=5)

`ok` = successful lookups. Times in seconds. Clients are described under [Topology](#topology),
scenarios and per-client p50/p95/max under [Detailed results](#detailed-results).

| Scenario | glibc | glibc-tuned | resolved | resolved-public | unbound forward | unbound recursive |
|---|---|---|---|---|---|---|
| baseline | 5/5, p50 0.002 | 5/5, p50 0.002 | 5/5, p50 0.002 | 5/5, p50 0.004 | 5/5, p50 0.003 | 5/5, p50 0.002 |
| dns1 timeout | 5/5, every query 5.0 | 5/5, every query 1.0 | 5/5, first query 5.0 | 5/5, first query 5.0 | 5/5, max 0.30 | 5/5, max 0.002 |
| dns1 host gone | 5/5, every query 5.0 | 5/5, every query 1.0 | 5/5, first query 5.0 | 5/5, first query 5.0 | 5/5, max 0.39 | 5/5, max 0.002 |
| dns1 SERVFAIL | 5/5 | 5/5 | 5/5 | 5/5 | 5/5 | 5/5 |
| both providers down | 0/5, 20.0 each | 0/5, 4.0 each | **0/5**, 10.0 each | 4/5, first query 10.0 | 5/5, max 0.68 | 5/5, max 0.004 |
| providers + public down | 0/5 | 0/5 | 0/5 | 0/5 | 5/5, max 0.67 | 5/5, max 0.002 |
| everything down, expired cache | 0/3 | 0/3 | 0/3 | 0/3 | 3/3 (stale), max 0.96 | 3/3 (stale), 1.8 each |
| providers back after 70s | ok | ok | ok, back on provider | **stuck on public** | ok, back on provider | ok |

"unbound forward" uses the tuned config. With unbound defaults it does much worse.

## Unbound tuning results

Applies to the forwarding setup only. `tests/unbound-tuning.sh`, client-unbound only, one run
per variant.

- **Failover:** both provider resolvers time out. 6 lookups (`dig`, 60 s timeout).
  How long until unbound answers by resolving from the root itself?
- **Recovery:** providers back for 70 s, then client-unbound is blocked from the root.
  5 lookups only succeed if unbound went back to the providers.

| Variant | Failover ok | First answer after | Recovery ok |
|---|---|---:|---|
| defaults | 1/6 | 300 s | 5/5 |
| `infra-cache-max-rtt: 1500` | 5/6 | 60 s | 0/5 |
| `infra-cache-max-rtt: 500` | 6/6 | 0.8 s | 0/5 |
| `infra-cache-max-rtt: 500` + `infra-host-ttl: 60` | **6/6** | **0.8 s** | **5/5** |

- `infra-cache-max-rtt` (default 120000 ms) caps the backoff on a dead forwarder. With the
  default, unbound kept retrying the providers for 5 minutes before it resolved itself.
- `infra-host-ttl` (default 900 s) is how long a forwarder stays marked dead. Once
  `max-rtt` makes unbound mark them dead quickly, the default keeps it off the providers for
  up to 15 minutes after they recover.
- Defaults pass recovery only because unbound never gave up on the providers in the first place.
- Full recursion doesn't need these settings. Keep the defaults there: `infra-cache-max-rtt: 500`
  would make unbound give up on slow authoritative servers too early.

## Findings

1. **`FallbackDNS=` never kicks in while `DNS=` is set.** resolved only uses it when it knows no
   other server at all. A `FallbackDNS=` config has no working fallback.
2. **resolved does not switch back.** Once it fails over to a later `DNS=` entry it stays there
   until that server fails or resolved restarts. With a public resolver in `DNS=`, the server
   keeps using it after the provider recovers.
3. **`StaleRetentionSec=` is ignored on EL9.** It needs systemd 254+; EL9 ships 252.
4. **glibc alone** pays the full timeout on every query while dns1 is down (no memory of dead
   servers). Default settings: 5 s per query, 20 s to fail. glibc uses at most 3 `nameserver`
   lines; any further ones are ignored.
5. **unbound with full recursion** is unaffected by any provider resolver failure, and serves
   stale data when everything is down.
6. **unbound forwarding** fails over in under 1 s and returns to the providers, but only with
   two tuned settings: with unbound defaults the first answer came after 5 min.

## Recommended setup

Local unbound on every VM, full recursion. See `config/unbound-recursive-client.conf`.

```
server:
  interface: 127.0.0.1
  prefetch: yes
  serve-expired: yes
  serve-expired-ttl: 86400
  serve-expired-client-timeout: 1800   # 0 serves expired records before trying upstream
  msg-cache-size: 64m
  rrset-cache-size: 128m
  # keep the default DNSSEC validator + root trust anchor (the lab disables it)

# Local copy of the root zone (RFC 8806): no root server round trips, root stays
# reachable from cache.
auth-zone:
  name: "."
  primary: 170.247.170.2        # b.root-servers.net
  primary: 192.33.4.12          # c.root-servers.net
  primary: 192.5.5.241          # f.root-servers.net
  primary: 193.0.14.129         # k.root-servers.net
  fallback-enabled: yes
  for-downstream: no
  for-upstream: yes
```

Plus:

- `/etc/resolv.conf`: `nameserver 127.0.0.1` only.
- NetworkManager: `dns=none`, so it stops rewriting resolv.conf.
- Disable systemd-resolved.
- unbound drop-in with `Restart=always`; the stock unit has no restart.

Need the provider's resolvers? Use `config/unbound-client.conf` instead: the same, plus a
`forward-zone` with `forward-first: yes` and the two `infra-*` settings.

## Not tested yet

- Full recursion against real domains: cache-miss latency and slow authoritative servers.
- IPv6 and TCP fallback.
- Load (e.g. `dnsperf`).

## Topology

| Node | IP | Role |
|---|---|---|
| root | 10.53.0.5 | nsd, authoritative for `.` and `test.` (the "internet") |
| provider-dns1/2 | 10.53.0.11/.12 | provider's internal recursive resolvers (unbound) |
| public-dns | 10.53.0.53 | public resolver, stand-in for 8.8.8.8 / 1.1.1.1 |
| client-glibc | .101 | resolv.conf with provider resolvers, no options (EL default) |
| client-glibc-tuned | .102 | same, `options timeout:1 attempts:2` |
| client-resolved | .103 | systemd-resolved, `DNS=` providers, `FallbackDNS=` public |
| client-resolved-public | .104 | systemd-resolved, public resolver as third `DNS=` entry |
| client-unbound | .105 | local unbound, forwards to providers, `forward-first`, `serve-expired` |
| client-recursive | .106 | local unbound, full recursion, local root zone copy, `serve-expired` |

All nodes are `almalinux/9-init` containers with real systemd (systemd 252, same as every EL9 server).

## Run

```bash
docker compose up -d --build
tests/run.sh                        # all scenarios, ~7 min
tests/run.sh provider-down          # one scenario
N=20 tests/run.sh                   # more queries per client
tests/unbound-tuning.sh             # unbound infra-* variants, ~11 min
tests/db-failover.sh                # 15 s TTL record changes IP, ~1 min
tests/db-failover.sh providers-down # same, provider resolvers down
```

Lookups go through glibc (`getent ahosts`), the same path PHP and curl use.
Failures are simulated with `docker pause` (timeout), `docker stop` (host gone) and iptables (SERVFAIL).

## Detailed results

### Scenarios

| Scenario | What fails |
|---|---|
| baseline | nothing |
| dns1-timeout | provider-dns1 paused: queries to it time out |
| dns1-down | provider-dns1 stopped: host gone, ARP fails |
| dns1-servfail | provider-dns1 can't reach the root, answers SERVFAIL |
| provider-down | both provider resolvers time out |
| resolvers-down | both providers and the public resolver time out; the root still works |
| total-outage | everything upstream paused; query a name cached 8 s earlier with TTL 5 s |
| recovered | providers down, clients fail over, providers back for 70 s. Then the public resolver is paused and client-unbound is blocked from the root, so only the provider path works. client-recursive is not blocked |

### Full results

Run `results/20261105-100009.txt`. 5 unique (cache-miss) lookups per client, 3 for total-outage.

| Scenario | Client | ok | p50 s | p95 s | max s |
|---|---|---|---:|---:|---:|
| baseline | glibc | 5/5 | 0.002 | 0.003 | 0.003 |
| baseline | glibc-tuned | 5/5 | 0.002 | 0.004 | 0.004 |
| baseline | recursive | 5/5 | 0.002 | 0.004 | 0.004 |
| baseline | resolved | 5/5 | 0.002 | 0.003 | 0.003 |
| baseline | resolved-public | 5/5 | 0.004 | 0.005 | 0.005 |
| baseline | unbound | 5/5 | 0.003 | 0.004 | 0.004 |
| dns1-timeout | glibc | 5/5 | 5.017 | 5.022 | 5.022 |
| dns1-timeout | glibc-tuned | 5/5 | 1.013 | 1.015 | 1.015 |
| dns1-timeout | recursive | 5/5 | 0.002 | 0.002 | 0.002 |
| dns1-timeout | resolved | 5/5 | 0.004 | 5.021 | 5.021 |
| dns1-timeout | resolved-public | 5/5 | 0.003 | 5.008 | 5.008 |
| dns1-timeout | unbound | 5/5 | 0.004 | 0.296 | 0.296 |
| dns1-down | glibc | 5/5 | 5.009 | 5.021 | 5.021 |
| dns1-down | glibc-tuned | 5/5 | 1.013 | 1.017 | 1.017 |
| dns1-down | recursive | 5/5 | 0.001 | 0.002 | 0.002 |
| dns1-down | resolved | 5/5 | 0.003 | 5.008 | 5.008 |
| dns1-down | resolved-public | 5/5 | 0.004 | 5.012 | 5.012 |
| dns1-down | unbound | 5/5 | 0.005 | 0.386 | 0.386 |
| dns1-servfail | glibc | 5/5 | 0.004 | 0.006 | 0.006 |
| dns1-servfail | glibc-tuned | 5/5 | 0.006 | 0.011 | 0.011 |
| dns1-servfail | recursive | 5/5 | 0.002 | 0.004 | 0.004 |
| dns1-servfail | resolved | 5/5 | 0.002 | 0.004 | 0.004 |
| dns1-servfail | resolved-public | 5/5 | 0.005 | 0.012 | 0.012 |
| dns1-servfail | unbound | 5/5 | 0.002 | 0.003 | 0.003 |
| provider-down | glibc | 0/5 | 20.041 | 20.046 | 20.046 |
| provider-down | glibc-tuned | 0/5 | 4.027 | 4.037 | 4.037 |
| provider-down | recursive | 5/5 | 0.003 | 0.004 | 0.004 |
| provider-down | resolved | 0/5 | 10.025 | 10.027 | 10.027 |
| provider-down | resolved-public | 4/5 | 0.008 | 10.019 | 10.019 |
| provider-down | unbound | 5/5 | 0.004 | 0.675 | 0.675 |
| resolvers-down | glibc | 0/5 | 20.038 | 20.050 | 20.050 |
| resolvers-down | glibc-tuned | 0/5 | 4.026 | 4.032 | 4.032 |
| resolvers-down | recursive | 5/5 | 0.002 | 0.002 | 0.002 |
| resolvers-down | resolved | 0/5 | 10.019 | 10.023 | 10.023 |
| resolvers-down | resolved-public | 0/5 | 10.026 | 10.029 | 10.029 |
| resolvers-down | unbound | 5/5 | 0.005 | 0.674 | 0.674 |
| total-outage | glibc | 0/3 | 20.041 | 20.044 | 20.044 |
| total-outage | glibc-tuned | 0/3 | 4.028 | 4.029 | 4.029 |
| total-outage | recursive | 3/3 | 1.816 | 1.819 | 1.819 |
| total-outage | resolved | 0/3 | 10.015 | 10.021 | 10.021 |
| total-outage | resolved-public | 0/3 | 10.027 | 10.028 | 10.028 |
| total-outage | unbound | 3/3 | 0.010 | 0.957 | 0.957 |
| recovered | glibc | 5/5 | 0.002 | 0.006 | 0.006 |
| recovered | glibc-tuned | 5/5 | 0.001 | 0.002 | 0.002 |
| recovered | recursive | 5/5 | 0.003 | 0.006 | 0.006 |
| recovered | resolved | 5/5 | 0.003 | 0.004 | 0.004 |
| recovered | resolved-public | 5/5 | 0.005 | 5.017 | 5.017 |
| recovered | unbound | 5/5 | 0.001 | 0.001 | 0.001 |

Current DNS server 70 s after the providers came back:

- resolved: `10.53.0.12` (provider)
- resolved-public: `10.53.0.53` (still on the public resolver)

The 5.017 s max for resolved-public in `recovered` is that pinning: it first times out on the
paused public resolver, then moves to a provider.

### Database failover

`results/db-failover-normal-20261105-101304.txt` and
`results/db-failover-providers-down-20261105-101328.txt`. Polled every 0.5 s for up to 90 s.
`old` = lookups that still returned the old IP, `fail` = failed lookups.

| Client | Healthy: new IP after s | old | fail | Providers down: new IP after s | old | fail |
|---|---:|---:|---:|---:|---:|---:|
| glibc | 10.0 | 19 | 0 | >90 | 0 | 5 |
| glibc-tuned | 10.1 | 19 | 0 | >90 | 0 | 20 |
| resolved | 10.1 | 19 | 0 | >90 | 17 | 8 |
| resolved-public | 10.1 | 19 | 0 | 20.2 | 18 | 1 |
| unbound | 10.1 | 19 | 0 | 8.7 | 16 | 0 |
| recursive | 8.6 | 16 | 0 | 8.1 | 15 | 0 |
