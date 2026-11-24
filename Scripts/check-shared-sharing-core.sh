#!/bin/sh
# Verify the shared sharing core against Scripts/shared-sharing-core.sha256.
#
# Only apps that let people share their data carry this manifest. `@APP@` in
# a manifest path is the app name from project.yml (its target and folder
# name). Pass --write to regenerate the manifest after an intentional change,
# then copy the changed files and manifest to every app that has it.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$repo/Scripts/shared-sharing-core.sha256"
app=$(sed -n 's/^name: *//p' "$repo/project.yml" | head -1)
[ -n "$app" ] || { echo "project.yml has no name" >&2; exit 1; }

digest() {
  shasum -a 256 "$repo/$(printf '%s' "$1" | sed "s/@APP@/$app/g")" | cut -d ' ' -f 1
}

if [ "${1:-}" = --write ]; then
  updated=$(mktemp)
  while read -r _ path; do
    printf '%s  %s\n' "$(digest "$path")" "$path"
  done < "$manifest" > "$updated"
  mv "$updated" "$manifest"
fi

status=0
while read -r expected path; do
  if [ "$(digest "$path")" = "$expected" ]; then
    echo "$path: OK"
  else
    echo "$path: FAILED" >&2
    status=1
  fi
done < "$manifest"
exit "$status"
