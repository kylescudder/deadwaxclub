#!/bin/sh
# Verify the shared core against the same recorded checksums in both repos.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for app in Diald DeadWaxClub; do
  if [ -d "$repo/$app/Notifications" ]; then
    cd "$repo/$app/Notifications"
    shasum -a 256 -c "$repo/Scripts/shared-push-core.sha256"
    exit
  fi
done
echo "Cannot locate notification sources" >&2
exit 1
