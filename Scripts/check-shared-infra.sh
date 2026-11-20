#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
while read -r expected path; do
  if [ "$path" = Hooks/hooks.py ]; then
    set -- "$repo"/Backend/deploy/deploy-core-candidate/app_hooks/*/hooks.py
    [ "$#" -eq 1 ] || { echo "Expected one backend hook" >&2; exit 1; }
    actual=$1
  else
    actual="$repo/$path"
  fi
  printf '%s  %s\n' "$expected" "$actual" | shasum -a 256 -c -
done < "$repo/Scripts/shared-infra.sha256"
