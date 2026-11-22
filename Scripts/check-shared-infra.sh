#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project=$(sed -n 's/^  "project": "\([a-z][a-z0-9-]*\)",$/\1/p' "$repo/Backend/deploy/app.json")
[ -n "$project" ] || { echo "Backend/deploy/app.json has no project" >&2; exit 1; }
normalized=$(mktemp)
trap 'rm -f "$normalized"' EXIT
while read -r expected path; do
  if [ "$path" = Backend/deploy/compose.yaml ]; then
    # Only the app-prefixed service names may differ between apps.
    sed -E "s/^  $project-(api|sync):$/  APP-\1:/" "$repo/$path" > "$normalized"
    actual=$normalized
  else
    actual="$repo/$path"
  fi
  printf '%s  %s\n' "$expected" "$actual" | shasum -a 256 -c -
done < "$repo/Scripts/shared-infra.sha256"
