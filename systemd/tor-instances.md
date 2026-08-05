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
rendezvous cache grows to roughly `candidates * 4.2 KB` over a round — about
100 MB at 24k candidates. Budget for that and for growth: the candidate set gains
a few hundred addresses a day.

Setting `MaxMemInQueues` below that figure does not save memory, it breaks the
crawl. At 96 MB every round hit the ceiling roughly two hours in, and within a
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

So: 256 MB per instance, three instances, roughly 130 MB resident each in
practice on a 1 GB VPS. `MaxMemInQueues` is a ceiling rather than a reservation,
so a generous value costs nothing until the workload actually grows into it.
Watch `free -h` and the daemons' RSS during the first run.

`observatory-onion.service` restarts all three daemons before each round
(`ExecStartPre`), so every round starts from an empty descriptor cache and is
measured under the same conditions rather than inheriting the previous day's
state.

The crawl aborts before recording anything if any declared instance is
unreachable, so a daemon that failed to start is loud rather than silently
halving capacity.
