#!/bin/sh
# Verify the shared iOS core against Scripts/shared-ios-core.sha256.
#
# `@APP@` in a manifest path is the app name from project.yml (its target and
# folder name). The iOS workflows are hashed with that name replaced by
# `@APP@` and its upper-case form by `@APP_UPPER@`, so only the target name may
# differ between apps. Pass --write to regenerate the manifest after an
# intentional change, then copy the changed files and manifest to every app.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$repo/Scripts/shared-ios-core.sha256"
app=$(sed -n 's/^name: *//p' "$repo/project.yml" | head -1)
[ -n "$app" ] || { echo "project.yml has no name" >&2; exit 1; }
upper=$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')
normalized=$(mktemp)
trap 'rm -f "$normalized"' EXIT

digest() {
  file="$repo/$(printf '%s' "$1" | sed "s/@APP@/$app/g")"
  case "$1" in
    .github/workflows/*)
      sed "s/$upper/@APP_UPPER@/g; s/$app/@APP@/g" "$file" > "$normalized"
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
