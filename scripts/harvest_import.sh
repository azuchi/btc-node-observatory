#!/usr/bin/env bash
# Recursive getaddr discovery, then import the result as crawl candidates.
# Meant to run daily (systemd/observatory-harvest.timer).
#
# Widening the candidate source is a methodology change: keep
# `candidate_sources` in the config in sync with what actually runs, and record
# the change in the data repository's CHANGELOG.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

OUT="${HARVEST_OUT:-/tmp/harvest.json}"

bundle exec exe/observatory harvest --out "$OUT"
bundle exec exe/observatory import --file "$OUT"
rm -f "$OUT"
