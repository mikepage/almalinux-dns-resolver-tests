# Test results

2026-11-05, one run, 5 lookups per client unless noted. Times in seconds.
Clients: see [Lab](../README.md#lab).

## Summary per scenario

`ok` = successful lookups. Scenarios are described [below](#scenarios).

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

Applies to the forwarding setup only. Raw: [`unbound-tuning-20261105-093118.txt`](unbound-tuning-20261105-093118.txt). `tests/unbound-tuning.sh`, client-unbound only, one run
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

## Scenarios

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

## Full results

Raw: [`20261105-100009.txt`](20261105-100009.txt). 5 unique (cache-miss) lookups per client, 3 for total-outage.

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

## Database failover

Raw: [`db-failover-normal-20261105-101304.txt`](db-failover-normal-20261105-101304.txt) and
[`db-failover-providers-down-20261105-101328.txt`](db-failover-providers-down-20261105-101328.txt). Polled every 0.5 s for up to 90 s.
`old` = lookups that still returned the old IP, `fail` = failed lookups.

| Client | Healthy: new IP after s | old | fail | Providers down: new IP after s | old | fail |
|---|---:|---:|---:|---:|---:|---:|
| glibc | 10.0 | 19 | 0 | >90 | 0 | 5 |
| glibc-tuned | 10.1 | 19 | 0 | >90 | 0 | 20 |
| resolved | 10.1 | 19 | 0 | >90 | 17 | 8 |
| resolved-public | 10.1 | 19 | 0 | 20.2 | 18 | 1 |
| unbound | 10.1 | 19 | 0 | 8.7 | 16 | 0 |
| recursive | 8.6 | 16 | 0 | 8.1 | 15 | 0 |
