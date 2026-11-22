#!/bin/sh
# Verify the shared site files against Scripts/shared-site.sha256.
#
# Site/app.json holds each app's site values. Site/Caddyfile and
# Site/compose.yaml are hashed with the app's `repository` replaced by `@REPO@`
# and its `token` by `@APP@`, so only those may differ between apps; every other
# file is compared as is. Pass --write to regenerate the manifest after an
# intentional change, then copy the changed files and manifest to every app.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$repo/Scripts/shared-site.sha256"
value() {
  sed -n "s/^  \"$1\": \"\([A-Za-z0-9-]*\)\",\$/\1/p" "$repo/Site/app.json"
}
token=$(value token)
repository=$(value repository)
[ -n "$token" ] && [ -n "$repository" ] || {
  echo "Site/app.json needs a token and a repository" >&2
  exit 1
}
normalized=$(mktemp)
trap 'rm -f "$normalized"' EXIT

digest() {
  file="$repo/$1"
  case "$1" in
    Site/Caddyfile | Site/compose.yaml)
      sed "s/$repository/@REPO@/g; s/$token/@APP@/g" "$file" > "$normalized"
      file=$normalized ;;
  esac
  shasum -a 256 "$file" | cut -d ' ' -f 1
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
