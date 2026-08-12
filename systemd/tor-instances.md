# Running several Tor daemons for the onion crawl

A single Tor daemon saturates its circuit-building queue long before the
candidate set is exhausted: with ~20k onion candidates behind one daemon, 98% of
probes end in `timeout`. Throughput comes from running several daemons and
spreading probes across them — and from giving each probe long enough to finish
building a rendezvous circuit (90 s, not 30 s).

Debian/Ubuntu ship a systemd template (`tor@.service`) for exactly this.

## 1. Create one torrc per instance

Each instance needs its own SocksPort and data directory:

```sh
for i in 1 2 3; do
  port=$((9050 + i))
  sudo install -d -o debian-tor -g debian-tor -m 700 /var/lib/tor-instances/crawler$i
  printf 'SocksPort %d\nDataDirectory /var/lib/tor-instances/crawler%d\nMaxMemInQueues 256 MB\nConfluxEnabled 0\n' \
    "$port" "$i" | sudo tee /etc/tor/instances/crawler$i/torrc
done
```

`MaxMemInQueues` and `ConfluxEnabled` are not optional here — see Sizing below.

If `/etc/tor/instances/` does not exist, use `tor-instance-create crawler$i`
(from the `tor` package), which creates the directories and the torrc for you.

## 2. Start them

```sh
sudo systemctl enable --now tor@crawler1 tor@crawler2 tor@crawler3
ss -tlnp | grep -E '905[123]'      # 9051, 9052, 9053 should be listening
```

## 3. Point the crawler at every instance

```yaml
# config/observatory.yml
onion:
  concurrency: 90          # roughly 30 per daemon
  connect_timeout: 90
  handshake_timeout: 90
  socks5_host: 127.0.0.1
  socks5_ports: [9051, 9052, 9053]
```

The number of instances is part of `params_hash`, so changing it is a
methodology change: record it in the data repository's CHANGELOG.

## Sizing

**A round's memory use is set by the candidate count, not by the timeouts.** Tor
caches the onion-service descriptor of every address it looks up, so the
rendezvous cache grows over a round. Measured peak RSS per daemon, from the
`Consumed ... memory peak` line systemd logs when each daemon is restarted at the
start of the next round:

| Round | Candidates | Peak RSS per daemon | Peak swap per daemon | Wall |
|---|---|---|---|---|
| 2026-08-07 | 24,930 | 172 / 177 / 186 MB | 6 / 7 / 10 MB | 2h55m |
| 2026-08-08 | 25,496 | 219 / 151 / 152 MB | 137 / 142 / 143 MB | 3h43m |
| 2026-08-10 | 26,297 | 168 / 159 / 160 MB | 134 / 164 / 156 MB | 4h02m |
| 2026-08-12 | 26,937 | 237 / 230 / 165 MB | 139 / 126 / 138 MB | 4h09m |

That is roughly **6–8 KB per candidate**, not the ~4 KB this document claimed
before the figures were measured. Budget for it and for growth: the candidate set
gains a few hundred addresses a day.

Setting `MaxMemInQueues` below what a round actually needs does not save memory,
it breaks the crawl. At 96 MB every round hit the ceiling roughly two hours in, and within a
few minutes of `We're low on memory ... Killing circuits with over-long queues`
Tor aborted on a conflux assertion in Tor 0.4.8.10. All three daemons crashed
mid-round, every round, for days. `ConfluxEnabled 0` removes that abort path;
conflux is a multipath speed optimisation that a crawler does not need.

The ceiling also made rounds incomparable. The cache fills in proportion to
descriptors successfully fetched, so a productive round hits the ceiling — and
therefore crashes — sooner, and then spends longer on freshly restarted daemons.
2026-08-04 and 08-05 ran identical parameters: the second reached the ceiling 20%
faster and returned 29% more reachable nodes. Which part of that gap is the
network and which is our own Tor state is not recoverable from the logs.

So: 256 MB per instance, three instances. `MaxMemInQueues` is a ceiling rather
than a reservation, so a generous value costs nothing until the workload actually
grows into it.

**At the current size the binding constraint is the host's RAM, not
`MaxMemInQueues`.** The two are easy to conflate: the table above is cgroup RSS
for the whole process, while `MaxMemInQueues` governs only Tor's own queue and
cache accounting, so a 237 MB RSS is not "93% of the 256 MB ceiling". Tor tells
you directly when the ceiling is the problem, by logging `We're low on memory ...
Killing circuits with over-long queues` — as it did continuously at 96 MB before
2026-08-05. Since raising it there have been **zero** such lines. Check for them
before concluding that `MaxMemInQueues` needs raising again.

What the host does show is swap pressure. Three daemons at ~200 MB plus the
crawler process (~95 MB RSS) on a 961 MB VPS puts roughly 130 MB per daemon into
swap, and that began with the 2026-08-08 round: the round before it swapped under
10 MB per daemon. Round duration stepped up over the same boundary (2h55m to
3h43m) and has kept climbing, while candidates grew only 2% between those two
rounds — so swap is the better explanation of the two, though the candidate count
does keep rising and the confound is not fully separable from these figures
alone. CPU is not consistently the limit either: the same rounds ran at 97%, 98%,
74% and 96% of the single core, and the slowest of them was the least CPU-bound,
which is what waiting on swap I/O looks like.

Watch `free -h`, the daemons' RSS, and the swap column during the first run.

`observatory-onion.service` restarts all three daemons before each round
(`ExecStartPre`), so every round starts from an empty descriptor cache and is
measured under the same conditions rather than inheriting the previous day's
state.

The crawl aborts before recording anything if any declared instance is
unreachable, so a daemon that failed to start is loud rather than silently
halving capacity.
