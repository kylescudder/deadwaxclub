#!/bin/sh
# Verify the shared core against the same recorded checksums in every app.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=$(sed -n 's/^name: *//p' "$repo/project.yml" | head -1)
[ -d "$repo/$app/Notifications" ] || { echo "Cannot locate notification sources" >&2; exit 1; }
cd "$repo/$app/Notifications"
shasum -a 256 -c "$repo/Scripts/shared-push-core.sha256"
