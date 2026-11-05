# almalinux-dns-resolver-tests

Compares resolver setups on AlmaLinux 9 when the VPS provider's internal DNS resolvers fail.
Fully offline: a fake root and `test.` zone stand in for the internet.

## Conclusion

**Best setup:** local unbound on every VM, forwarding to the provider resolvers with
`forward-first: yes`, `infra-cache-max-rtt: 500` and `infra-host-ttl: 60`.
See [Recommended setup](#recommended-setup).

In normal operation unbound uses only the provider resolvers. Packet count for 20 cache-miss
lookups: 13 to provider-dns1, 7 to provider-dns2, 0 to the root, 0 to the public resolver.
It resolves from the root itself only while both providers fail.

### Expected downtime when both provider resolvers go down

| Setup | During the outage | After the providers recover |
|---|---|---|
| **unbound, tuned (recommended)** | **No downtime.** First lookup takes ~0.8 s, then normal | Back on the providers within ~60 s |
| unbound, defaults | All lookups fail for ~5 min, then normal | Back on the providers |
| resolved, public resolver in `DNS=` | First lookup takes ~10 s, then normal | Stays on the public resolver until it fails or resolved restarts |
| **resolved, `FallbackDNS=` public** | **Down for the whole outage.** Every lookup fails after 10 s | OK |
| glibc only (EL default) | Down for the whole outage. Every lookup fails after 20 s | OK |
| glibc, `timeout:1 attempts:2` | Down for the whole outage. Every lookup fails after 4 s | OK |

With `FallbackDNS=` a provider DNS outage is a full DNS outage for as long as it
lasts, and every lookup blocks for 10 s before failing.

### When only one provider resolver goes down

| Setup | Impact |
|---|---|
| unbound, tuned | First lookup up to 0.4 s, then normal |
| resolved (both configs) | First lookup 5 s, then normal |
| glibc only | Every lookup 5 s slower for the whole outage |
| glibc, `timeout:1 attempts:2` | Every lookup 1 s slower for the whole outage |

Caveat: lab numbers, one run with 5 lookups per client. Not yet checked against real domains,
see [Not tested yet](#not-tested-yet).

## Results (2026-11-05, N=5)

`ok` = successful lookups. Times in seconds. Clients are described under [Topology](#topology),
scenarios and per-client p50/p95/max under [Detailed results](#detailed-results).

| Scenario | glibc | glibc-tuned | resolved | resolved-public | unbound |
|---|---|---|---|---|---|
| baseline | 5/5, p50 0.002 | 5/5, p50 0.003 | 5/5, p50 0.003 | 5/5, p50 0.002 | 5/5, p50 0.002 |
| dns1 timeout | 5/5, every query 5.0 | 5/5, every query 1.0 | 5/5, first query 5.0 | 5/5, first query 5.0 | 5/5, max 0.30 |
| dns1 host gone | 5/5, every query 5.0 | 5/5, every query 1.0 | 5/5, first query 5.0 | 5/5, first query 5.0 | 5/5, max 0.39 |
| dns1 SERVFAIL | 5/5 | 5/5 | 5/5 | 5/5 | 5/5 |
| both providers down | 0/5, 20.0 each | 0/5, 4.0 each | **0/5**, 10.0 each | 4/5, first query 10.0 | 5/5, max 0.67 |
| providers + public down | 0/5 | 0/5 | 0/5 | 0/5 | 5/5, max 0.68 |
| everything down, expired cache | 0/3 | 0/3 | 0/3 | 0/3 | 3/3 (stale), max 1.42 |
| providers back after 70s | ok | ok | ok, back on provider | **stuck on public** | ok, back on provider |

The unbound column uses the tuned config below. With unbound defaults it does much worse.

## Unbound tuning results

`tests/unbound-tuning.sh`, client-unbound only, one run per variant.

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

## Findings

1. **`FallbackDNS=` never kicks in while `DNS=` is set.** resolved only uses it when it knows no
   other server at all. A `FallbackDNS=` config has no working fallback.
2. **resolved does not switch back.** Once it fails over to a later `DNS=` entry it stays there
   until that server fails or resolved restarts. With a public resolver in `DNS=`, the server
   keeps using it after the provider recovers.
3. **`StaleRetentionSec=` is ignored on EL9.** It needs systemd 254+; EL9 ships 252.
4. **glibc alone** pays the full timeout on every query while dns1 is down (no memory of dead
   servers). Default settings: 5 s per query, 20 s to fail.
5. **unbound** fails over in under 1 s, resolves from the root itself when all resolvers are
   down, serves stale data when everything is down, and returns to the provider resolvers.
   But only with two tuned settings: with unbound defaults the first answer came after 5 min.
   See [Unbound tuning results](#unbound-tuning-results).

## Recommended setup

Local unbound on every VM, forwarding to the provider resolvers. See `config/unbound-client.conf`.

```
server:
  interface: 127.0.0.1
  infra-cache-max-rtt: 500     # default 120000: 5 min before fallback
  infra-host-ttl: 60           # default 900: 15 min before returning to the providers
  prefetch: yes
  serve-expired: yes
  serve-expired-ttl: 86400
  serve-expired-client-timeout: 1800
  # keep the default DNSSEC validator + root trust anchor (the lab disables it)

forward-zone:
  name: "."
  forward-addr: <provider resolver 1>
  forward-addr: <provider resolver 2>
  forward-first: yes           # providers fail -> resolve from the root ourselves
```

Plus:

- `/etc/resolv.conf`: `nameserver 127.0.0.1` only.
- NetworkManager: `dns=none`, so it stops rewriting resolv.conf.
- Disable systemd-resolved.
- unbound drop-in with `Restart=always`; the stock unit has no restart.

No public resolver needed: unbound's own recursion is the fallback, and it doesn't hand
all lookups to a public resolver.

## Not tested yet

- `infra-cache-max-rtt: 500` also applies to authoritative servers during recursion. A far-away
  authoritative with RTT > 500 ms could be treated as down. Test against real domains on a staging VM.
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

All nodes are `almalinux/9-init` containers with real systemd (systemd 252, same as every EL9 server).

## Run

```bash
docker compose up -d --build
tests/run.sh                 # all scenarios, ~6 min
tests/run.sh provider-down   # one scenario
N=20 tests/run.sh            # more queries per client
tests/unbound-tuning.sh      # unbound infra-* variants, ~11 min
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
| recovered | providers down, clients fail over, providers back for 70 s. Then the public resolver is paused and client-unbound is blocked from the root, so only the provider path works |

### Full results

Run `results/20261105-091810.txt`. 5 unique (cache-miss) lookups per client, 3 for total-outage.

| Scenario | Client | ok | p50 s | p95 s | max s |
|---|---|---|---:|---:|---:|
| baseline | glibc | 5/5 | 0.002 | 0.003 | 0.003 |
| baseline | glibc-tuned | 5/5 | 0.003 | 0.005 | 0.005 |
| baseline | resolved | 5/5 | 0.003 | 0.004 | 0.004 |
| baseline | resolved-public | 5/5 | 0.002 | 0.004 | 0.004 |
| baseline | unbound | 5/5 | 0.002 | 0.003 | 0.003 |
| dns1-timeout | glibc | 5/5 | 5.014 | 5.017 | 5.017 |
| dns1-timeout | glibc-tuned | 5/5 | 1.008 | 1.013 | 1.013 |
| dns1-timeout | resolved | 5/5 | 0.003 | 5.010 | 5.010 |
| dns1-timeout | resolved-public | 5/5 | 0.004 | 5.012 | 5.012 |
| dns1-timeout | unbound | 5/5 | 0.005 | 0.296 | 0.296 |
| dns1-down | glibc | 5/5 | 5.016 | 5.018 | 5.018 |
| dns1-down | glibc-tuned | 5/5 | 1.009 | 1.014 | 1.014 |
| dns1-down | resolved | 5/5 | 0.002 | 5.010 | 5.010 |
| dns1-down | resolved-public | 5/5 | 0.002 | 5.010 | 5.010 |
| dns1-down | unbound | 5/5 | 0.003 | 0.387 | 0.387 |
| dns1-servfail | glibc | 5/5 | 0.002 | 0.004 | 0.004 |
| dns1-servfail | glibc-tuned | 5/5 | 0.004 | 0.005 | 0.005 |
| dns1-servfail | resolved | 5/5 | 0.002 | 0.004 | 0.004 |
| dns1-servfail | resolved-public | 5/5 | 0.002 | 0.003 | 0.003 |
| dns1-servfail | unbound | 5/5 | 0.002 | 0.003 | 0.003 |
| provider-down | glibc | 0/5 | 20.036 | 20.038 | 20.038 |
| provider-down | glibc-tuned | 0/5 | 4.021 | 4.031 | 4.031 |
| provider-down | resolved | 0/5 | 10.020 | 10.027 | 10.027 |
| provider-down | resolved-public | 4/5 | 0.009 | 10.019 | 10.019 |
| provider-down | unbound | 5/5 | 0.004 | 0.669 | 0.669 |
| resolvers-down | glibc | 0/5 | 20.038 | 20.053 | 20.053 |
| resolvers-down | glibc-tuned | 0/5 | 4.027 | 4.031 | 4.031 |
| resolvers-down | resolved | 0/5 | 10.023 | 10.025 | 10.025 |
| resolvers-down | resolved-public | 0/5 | 10.024 | 10.026 | 10.026 |
| resolvers-down | unbound | 5/5 | 0.002 | 0.681 | 0.681 |
| total-outage | glibc | 0/3 | 20.034 | 20.043 | 20.043 |
| total-outage | glibc-tuned | 0/3 | 4.019 | 4.025 | 4.025 |
| total-outage | resolved | 0/3 | 10.019 | 10.022 | 10.022 |
| total-outage | resolved-public | 0/3 | 10.025 | 10.026 | 10.026 |
| total-outage | unbound | 3/3 | 0.005 | 1.420 | 1.420 |
| recovered | glibc | 5/5 | 0.004 | 0.006 | 0.006 |
| recovered | glibc-tuned | 5/5 | 0.004 | 0.007 | 0.007 |
| recovered | resolved | 5/5 | 0.002 | 0.003 | 0.003 |
| recovered | resolved-public | 5/5 | 0.004 | 5.014 | 5.014 |
| recovered | unbound | 5/5 | 0.002 | 0.007 | 0.007 |

Current DNS server 70 s after the providers came back:

- resolved: `10.53.0.11` (provider)
- resolved-public: `10.53.0.53` (still on the public resolver)

The 5.014 s max for resolved-public in `recovered` is that pinning: it first times out on the
paused public resolver, then moves to a provider.
