# btc-node-observatory

Observation infrastructure for reachable Bitcoin P2P nodes (the crawler), with the goal of
**sustainable observation and publication of the raw data**.

Design principles: **continuity > accuracy / explicit and fixed methodology / open and distributed raw data / no single point of failure**

## Repository layout (split into three repositories)

Data and presentation are separated so that a third party can fork the data repository and
continue the observations even if the operator disappears.

```
btc-node-observatory/   This repository. The crawler (Ruby + bitcoinrb + Async), run on a VPS via systemd timers
../btc-node-data/       Aggregate time series + Actions (aggregates rebuild). Published under CC-BY 4.0, mirroring mandatory
../btc-node-dashboard/  GitHub Pages static site. Only reads btc-node-data raw URLs
```

Layout of this repository:

```
lib/, exe/          The crawler itself
systemd/            service / timer units for the VPS
scripts/            Daily export + git push script, monthly archive script
```

Division of roles (spec §1):

- **Pi / Umbrel**: runs bitcoind continuously and only supplies the addrman (`getnodeaddresses 0`)
- **VPS**: runs the crawls and stores raw data in SQLite. No residential connections, no AWS/GCP
- **GitHub Actions**: only rebuilds aggregates on push and deploys Pages (no cron-based collection)

## Setup (VPS)

```sh
bundle install
cp config/observatory.yml.example config/observatory.yml
$EDITOR config/observatory.yml   # bitcoind RPC, Tor SOCKS5, path to the data repository

# Import addresses → run one crawl → check
bundle exec exe/observatory import            # or --file addrs.json
bundle exec exe/observatory crawl clearnet
bundle exec exe/observatory stats
```

Continuous operation is driven by systemd timers:

```sh
sudo cp systemd/observatory-*.{service,timer} /etc/systemd/system/
sudo systemctl enable --now observatory-clearnet.timer   # every 15 minutes
sudo systemctl enable --now observatory-onion.timer      # once a day (requires a dedicated Tor)
sudo systemctl enable --now observatory-export.timer     # daily export + push
sudo systemctl enable --now observatory-archive.timer    # monthly raw archive + prune
```

The observations table grows by roughly 50–150 MB/day, so on a small disk the
monthly archive + prune cycle is required: `scripts/archive_month.sh` dumps last
month's raw data (`observatory archive`), uploads the tarball to a GitHub Release
of the data repository when `DATA_REPO_SLUG` is set, then frees disk space with
`observatory prune` (default retention 60 days; daily JSON exports are unaffected).

Run a **dedicated Tor instance** for the onion crawl (do not share the Umbrel/LN Tor daemon).

### CLI

```
observatory import [--file PATH]   Import addrman addresses (bitcoind RPC by default)
observatory crawl clearnet|onion   Run a single snapshot
observatory export [YYYY-MM-DD]    Write the daily aggregate JSON into the data repository
observatory archive [YYYY-MM]      Dump a month of raw data to gzipped NDJSON (for GitHub Releases)
observatory prune [--keep-days N]  Delete archived-off observations and VACUUM (default 60 days)
observatory geoip                  Resolve ASN/country with GeoLite2 (requires maxmind-db config)
observatory stats                  Show database overview
```

## Data publication (three tiers, spec §5)

| Destination | Contents |
|---|---|
| git (btc-node-data) | Daily aggregate JSON only: `daily/YYYY/MM/*.json` + Actions-generated `aggregates/*.json` |
| GitHub Releases | Monthly tarball of all raw snapshots from SQLite (`scripts/archive_month.sh`) |
| Zenodo | Yearly archive (with DOI, mandatory) |

Push `../btc-node-data` to GitHub and **set up mirrors on Codeberg / GitLab**.
Whenever a methodology parameter changes, record it in `CHANGELOG.md` with the date
(it is also machine-detectable via `params_hash`).

## Dashboard

Push `../btc-node-dashboard` to GitHub and enable GitHub Pages.
`DATA_BASE` in `app.js` and the links in the HTML point at `azuchi/btc-node-data`;
replace them when forking.
**Do not use a custom domain** (keep serving from `*.github.io`).

## Implementation phases

| Phase | Contents | Status |
|---|---|---|
| 1 | clearnet crawler + SQLite | Done (`crawl clearnet`, records instantaneous / union_24h) |
| 2 | Daily aggregation + push + Actions aggregates | Done (`export` + `push_daily.sh` + `btc-node-data`) |
| 3 | Pages dashboard (Node Count) | Done (separate clearnet/onion display + churn) |
| 4 | onion crawler | Done (`crawl onion`, via dedicated Tor) |
| 5 | Multi-source overlay / Zenodo / mirrors | Not yet (fetching external series and the overlay view) |

**Start accumulating data as soon as Phases 1–2 are running.** The dashboard can be built later,
but lost time can never be recovered.

## Tests

```sh
bundle exec rspec
```

No network required (handshakes are verified against local fake nodes / a fake SOCKS5 server).
