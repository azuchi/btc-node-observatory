#!/usr/bin/env bash
# Archive last month's raw data as a tarball, optionally upload it to a GitHub
# Release of the data repository, then prune old observations to free disk.
# Meant to run monthly (systemd/observatory-archive.timer).
#
# Env:
#   DATA_REPO_SLUG  e.g. "OWNER/btc-node-data" — if set and `gh` is available,
#                   the tarball is uploaded as release "raw-YYYY-MM".
#   ARCHIVE_DIR     where archives are written (default: ./archives)
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

ARCHIVE_DIR="${ARCHIVE_DIR:-archives}"
MONTH="${1:-$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m)}"

dir=$(bundle exec exe/observatory archive "$MONTH" --out "$ARCHIVE_DIR")
echo "archived: $dir"

tarball="${ARCHIVE_DIR}/raw-${MONTH}.tar"
# members are already gzipped NDJSON, so no additional compression
tar -cf "$tarball" -C "$ARCHIVE_DIR" "raw-${MONTH}"
echo "tarball: $tarball"

if [[ -n "${DATA_REPO_SLUG:-}" ]] && command -v gh >/dev/null; then
  gh release create "raw-${MONTH}" --repo "$DATA_REPO_SLUG" \
    --title "Raw data ${MONTH}" \
    --notes "Raw snapshots/observations for ${MONTH} (gzipped NDJSON, see meta.json)." \
    "$tarball" \
    || gh release upload "raw-${MONTH}" --repo "$DATA_REPO_SLUG" --clobber "$tarball"
  echo "uploaded to GitHub Releases: raw-${MONTH}"
else
  echo "DATA_REPO_SLUG not set or gh missing; tarball kept locally only"
fi

# Safe to prune now that the month is archived
bundle exec exe/observatory prune
