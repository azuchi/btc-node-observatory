#!/usr/bin/env bash
# Delete observations older than retention.keep_days and reclaim the disk.
# Meant to run WEEKLY (systemd/observatory-prune.timer).
#
# Weekly, and not riding along with the monthly archive as it used to:
#
#   2026-10-02  archive_month.sh archived and tarred 2026-09, then hit a few
#               seconds of "error connecting to api.github.com" on the upload.
#               `set -e` aborted the script before the prune, which was correct
#               -- but it also meant NOTHING was pruned that month.
#   2026-10-04  the catch-up was 47.4M rows in one DELETE on a 6.5GB database.
#               The delete itself worked; the VACUUM after it ran the disk out
#               of space and raised SQLite3::FullException.
#
# Pruning weekly keeps each delete an order of magnitude smaller, keeps the
# database near its steady-state size, and -- the real point -- recovers by
# itself: a run that fails for any reason is retried in seven days, not thirty.
#
# Env:
#   DATA_REPO_SLUG       e.g. "azuchi/btc-node-data". Required: the guard below
#                        verifies an uploaded Release exists for every month
#                        this prune would delete from.
#   PRUNE_WITHOUT_UPLOAD 1 to prune without that verification. Dangerous.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

# Pruning is irreversible: it deletes observations that exist nowhere else once
# the archive is the only copy. Writing a tarball to the local disk is NOT what
# makes pruning safe -- getting it off this host is.
#
# This is not hypothetical. Between 2026-07-28 and 2026-08-12 DATA_REPO_SLUG was
# unset and gh was not installed, so the archive script pruned anyway and the
# 2026-07 tarball sat on the observer's disk as the only copy of that month.
# Nothing was lost only because the series was younger than keep_days at the time.
#
# prune deletes by age, so it reaches back across every month that still holds
# observations older than the cutoff -- not just last month. If an earlier
# month's archive failed, or the host was down when it was due, that month was
# never published and pruning now would destroy it. So ask prune what it would
# touch, and require a Release for each month it names.
check_months_uploaded() {
  local months missing=()
  months=$(bundle exec exe/observatory prune --dry-run | sed -n 's/^months: //p')
  if [[ -z "$months" ]]; then
    echo "nothing older than the cutoff; no archives to verify"
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
elif [[ -z "${DATA_REPO_SLUG:-}" ]] || ! command -v gh >/dev/null; then
  echo "NOT pruning: DATA_REPO_SLUG unset or gh missing, so the archives cannot be verified."
  echo "Set DATA_REPO_SLUG, or set PRUNE_WITHOUT_UPLOAD=1 to prune with local-only archives."
  exit 1
elif check_months_uploaded; then
  bundle exec exe/observatory prune
else
  # Exit non-zero so systemd marks the run failed. A refusal that exits 0 is
  # indistinguishable from a successful prune in `systemctl --failed`, and
  # "nothing has been pruned for weeks, unnoticed" is the exact failure this
  # script exists to prevent.
  exit 1
fi
