#!/usr/bin/env bash
# Export yesterday's (UTC) daily aggregate into the btc-node-data repository, commit & push.
# Aggregates are rebuilt by GitHub Actions (btc-node-data/.github/workflows/build.yml).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

# Must point at the same location as export.out_dir in the config
DATA_REPO="${DATA_REPO:-../btc-node-data}"
DATE="${1:-$(date -u -d 'yesterday' +%F)}"

path=$(bundle exec exe/observatory export "$DATE" --out "$DATA_REPO")
echo "exported: $path"

cd "$DATA_REPO"
git add daily/
if git diff --cached --quiet; then
  echo "no changes to commit"
  exit 0
fi
git commit -m "data: ${DATE}"
# The aggregates workflow pushes its own commit to main after every data push,
# so the clone is always one commit behind by the next day: sync before pushing
git pull --rebase origin main
git push origin HEAD
# Also push to the mirror (Codeberg / GitLab). Configure a remote named 'mirror'.
git push mirror HEAD || echo "WARN: mirror push failed (continuing)"
