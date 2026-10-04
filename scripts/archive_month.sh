#!/usr/bin/env bash
# Archive last month's raw data as a tarball and upload it to a GitHub Release
# of the data repository. Meant to run monthly (systemd/observatory-archive.timer).
#
# This script no longer prunes. Pruning lives in scripts/prune.sh on its own
# weekly timer, because coupling the two meant a transient upload failure here
# cost a whole month of pruning -- see the header of that script for what that
# did on 2026-10-02.
#
# Env:
#   DATA_REPO_SLUG  e.g. "azuchi/btc-node-data" — if set and `gh` is available,
#                   the tarball is uploaded as release "raw-YYYY-MM".
#   ARCHIVE_DIR     where archives are written (default: ./archives)
#   KEEP_LOCAL      1 to keep the local copies after a successful upload.
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
  # Reported, not left to `set -e`: on 2026-10-02 both calls failed on a few
  # seconds of "error connecting to api.github.com" and the script died with a
  # bare non-zero exit, so what had actually gone wrong had to be dug out of the
  # journal afterwards.
  if gh release create "raw-${MONTH}" --repo "$DATA_REPO_SLUG" \
       --title "Raw data ${MONTH}" \
       --notes "Raw snapshots/observations for ${MONTH} (gzipped NDJSON, see meta.json)." \
       "$tarball" \
     || gh release upload "raw-${MONTH}" --repo "$DATA_REPO_SLUG" --clobber "$tarball"; then
    echo "uploaded to GitHub Releases: raw-${MONTH}"
    uploaded=1
  else
    echo "upload FAILED for raw-${MONTH}; the tarball is kept locally at ${tarball}."
    echo "Re-run 'scripts/archive_month.sh ${MONTH}' once GitHub is reachable."
    echo "scripts/prune.sh will refuse to prune until that Release exists."
    exit 1
  fi
else
  echo "DATA_REPO_SLUG not set or gh missing; tarball kept locally only"
fi

# Both the unpacked directory and the tarball built from it were being kept
# forever after a successful upload, so every month cost twice its own size on
# a disk that retention is already sized against: by 2026-10-04 three uploaded
# months were holding 1.0GB for nothing. Keep them only while this host is
# still the only copy.
if [[ "$uploaded" == 1 && "${KEEP_LOCAL:-0}" != 1 ]]; then
  # Verify the asset is really on the Release before deleting the local copy --
  # `gh release create` exiting 0 is not the same as the asset being readable,
  # and this is the step that makes the local copy redundant.
  remote_size=$(gh release view "raw-${MONTH}" --repo "$DATA_REPO_SLUG" \
    --json assets --jq ".assets[] | select(.name == \"raw-${MONTH}.tar\") | .size" 2>/dev/null || true)
  local_size=$(stat -c %s "$tarball")
  if [[ "$remote_size" == "$local_size" ]]; then
    rm -rf "$dir" "$tarball"
    echo "removed local copies (${local_size} bytes verified on the Release)"
  else
    echo "keeping local copies: Release asset is ${remote_size:-missing}, local is ${local_size}"
  fi
fi
