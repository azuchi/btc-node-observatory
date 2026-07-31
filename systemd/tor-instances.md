# Running several Tor daemons for the onion crawl

A single Tor daemon saturates its circuit-building queue long before the
candidate set is exhausted: with ~20k onion candidates behind one daemon, 99% of
probes end in `timeout` regardless of how generous the timeouts are. Throughput
comes from running several daemons and spreading probes across them.

Debian/Ubuntu ship a systemd template (`tor@.service`) for exactly this.

## 1. Create one torrc per instance

Each instance needs its own SocksPort and data directory:

```sh
for i in 1 2 3; do
  port=$((9050 + i))
  sudo install -d -o debian-tor -g debian-tor -m 700 /var/lib/tor-instances/crawler$i
  printf 'SocksPort %d\nDataDirectory /var/lib/tor-instances/crawler%d\n' "$port" "$i" \
    | sudo tee /etc/tor/instances/crawler$i/torrc
done
```

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
  connect_timeout: 30
  handshake_timeout: 30
  socks5_host: 127.0.0.1
  socks5_ports: [9051, 9052, 9053]
```

The number of instances is part of `params_hash`, so changing it is a
methodology change: record it in the data repository's CHANGELOG.

## Sizing

Each daemon holds a few hundred MB of resident memory once circuits are warm, so
on a 1 GB VPS two or three instances is the practical ceiling — watch `free -h`
during the first run. The crawl aborts before recording anything if any declared
instance is unreachable, so a daemon that failed to start is loud rather than
silently halving capacity.
