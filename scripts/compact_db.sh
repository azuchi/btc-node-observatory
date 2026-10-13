#!/usr/bin/env bash
# Rewrite the database small (VACUUM INTO) with every writer stopped.
#
# Why this exists rather than letting prune's VACUUM do it: VACUUM needs free
# space for two copies of the live data -- a temporary rebuild plus the -wal it
# lands in. By 2026-10-13 that was 6.4GB wanted against 6.3GB free, on a 19GB
# disk holding a 6.5GB database file, and the weekly prune had skipped the
# VACUUM every time. VACUUM INTO needs one copy (3.2GB), which fits.
#
# Run it by hand, rarely. It is not on a timer: it interrupts collection.
#
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

TIMERS=(observatory-clearnet.timer observatory-onion.timer
        observatory-harvest.timer observatory-export.timer
        observatory-prune.timer observatory-archive.timer)
SERVICES=(observatory-clearnet observatory-onion observatory-harvest
          observatory-export observatory-prune observatory-archive)

# The onion round takes hours and is the one measurement that cannot be redone
# if this collides with it, so refuse rather than queue behind it.
if systemctl is-active --quiet observatory-onion.service ||
   [[ "$(systemctl is-active observatory-onion.service)" == "activating" ]]; then
  echo "refusing: the onion round is running. Wait for it to finish."
  exit 1
fi

restore_timers() {
  echo "re-enabling timers"
  systemctl start "${TIMERS[@]}"
}
trap restore_timers EXIT

echo "stopping timers"
systemctl stop "${TIMERS[@]}"

# Stopping a timer does not stop a job already running under it. VACUUM INTO
# snapshots the database as it stands and the swap discards anything written
# after that, so a round still in flight would have its results thrown away.
echo "waiting for in-flight jobs"
for s in "${SERVICES[@]}"; do
  while [[ "$(systemctl is-active "${s}.service")" =~ ^(active|activating|deactivating)$ ]]; do
    echo "  ${s} still running..."
    sleep 10
  done
done

echo "compacting"
# Prints the sizes and where it kept the original. The backup is deliberately
# NOT deleted here: the thing it protects against is a fault that only surfaces
# when the crawler reopens the database, which happens after this script exits.
runuser -u observatory -- /bin/bash -lc 'bundle exec exe/observatory compact'
