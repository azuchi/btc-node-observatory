#!/usr/bin/env bash
# Archive last month's raw data as a tarball, optionally upload it to a GitHub
# Release of the data repository, then prune old observations to free disk.
# Meant to run monthly (systemd/observatory-archive.timer).
#
# Env:
#   DATA_REPO_SLUG  e.g. "azuchi/btc-node-data" — if set and `gh` is available,
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

uploaded=0
if [[ -n "${DATA_REPO_SLUG:-}" ]] && command -v gh >/dev/null; then
  gh release create "raw-${MONTH}" --repo "$DATA_REPO_SLUG" \
    --title "Raw data ${MONTH}" \
    --notes "Raw snapshots/observations for ${MONTH} (gzipped NDJSON, see meta.json)." \
    "$tarball" \
    || gh release upload "raw-${MONTH}" --repo "$DATA_REPO_SLUG" --clobber "$tarball"
  echo "uploaded to GitHub Releases: raw-${MONTH}"
  uploaded=1
else
  echo "DATA_REPO_SLUG not set or gh missing; tarball kept locally only"
fi

# Pruning is the irreversible half of this script: it deletes observations that
# exist nowhere else once the tarball is the only copy. Writing that tarball to
# the local disk is NOT what makes pruning safe -- getting it off this host is.
#
# This is not hypothetical. Between 2026-07-28 and 2026-08-12 DATA_REPO_SLUG was
# unset and gh was not installed, so every run took the `else` branch above and
# pruned anyway; the 2026-07 tarball sat on the observer's disk as the only copy
# of that month. Nothing was lost only because the series was younger than
# keep_days at the time.
#
# A successful upload above only covers ${MONTH}. prune deletes by age, so it
# reaches back across every month still holding observations older than the
# cutoff -- and if an earlier month's run failed, or the host was down when it
# was due, that month was never published and pruning now would destroy it.
# So ask prune what it would touch, and require a Release for each month.
check_months_uploaded() {
  local months missing=()
  months=$(bundle exec exe/observatory prune --dry-run | sed -n 's/^months: //p')
  if [[ -z "$months" ]]; then
    return 0
  fi
  for m in $months; do
    if ! gh release view "raw-${m}" --repo "$DATA_REPO_SLUG" >/dev/null 2>&1; then
      missing+=("$m")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "NOT pruning: no uploaded archive found for: ${missing[*]}"
    echo "Run 'scripts/archive_month.sh YYYY-MM' for each, then re-run this script."
    return 1
  fi
  echo "archives verified on the Release for: ${months}"
  return 0
}

if [[ "${PRUNE_WITHOUT_UPLOAD:-0}" == 1 ]]; then
  echo "PRUNE_WITHOUT_UPLOAD=1: pruning without verifying that archives were uploaded"
  bundle exec exe/observatory prune
elif [[ "$uploaded" != 1 ]]; then
  echo "NOT pruning: ${tarball} was not uploaded, so this host holds the only copy."
  echo "Upload it, or set PRUNE_WITHOUT_UPLOAD=1 to prune with local-only archives."
elif check_months_uploaded; then
  bundle exec exe/observatory prune
fi
