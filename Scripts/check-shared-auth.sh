#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for app in Diald DeadWaxClub; do
  if [ -d "$repo/$app/Auth" ]; then
    while read -r expected path; do
      case "$path" in
        Native/*) actual="$repo/$app/Auth/${path#Native/}" ;;
        Tests/*) actual="$repo/${app}Tests/${path#Tests/}" ;;
        *) actual="$repo/$path" ;;
      esac
      printf '%s  %s\n' "$expected" "$actual" | shasum -a 256 -c -
    done < "$repo/Scripts/shared-auth.sha256"
    exit
  fi
done
echo "Cannot locate native auth sources" >&2
exit 1
