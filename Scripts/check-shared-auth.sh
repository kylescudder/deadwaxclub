#!/bin/sh
# Verify the shared auth files against Scripts/shared-auth.sha256. `Native/`
# is the app's Auth folder and `Tests/` its test target, named after the
# `name:` in project.yml.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=$(sed -n 's/^name: *//p' "$repo/project.yml" | head -1)
[ -n "$app" ] && [ -d "$repo/$app/Auth" ] || {
  echo "Cannot locate native auth sources" >&2
  exit 1
}
while read -r expected path; do
  case "$path" in
    Native/*) actual="$repo/$app/Auth/${path#Native/}" ;;
    Tests/*) actual="$repo/${app}Tests/${path#Tests/}" ;;
    *) actual="$repo/$path" ;;
  esac
  printf '%s  %s\n' "$expected" "$actual" | shasum -a 256 -c -
done < "$repo/Scripts/shared-auth.sha256"
