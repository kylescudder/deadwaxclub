#!/usr/bin/env bash
#
# DESTRUCTIVE — recursively deletes every object in the `covers` Supabase
# Storage bucket. Intended for development resets only.
#
# Pairs with `purge-all.sql` (which handles auth + public-schema rows but
# can't touch storage because storage.objects is owned by
# supabase_storage_admin).
#
# Usage:
#   SUPABASE_URL=https://<project>.supabase.co \
#   SUPABASE_SERVICE_ROLE_KEY=eyJ... \
#   ./Supabase/scripts/purge-storage.sh [bucket]
#
# bucket defaults to "covers". Requires `curl` and `jq`.

set -euo pipefail

: "${SUPABASE_URL:?Set SUPABASE_URL (e.g. https://abc.supabase.co)}"
: "${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY (Project Settings -> API -> service_role key)}"

BUCKET="${1:-covers}"
LIMIT=1000
DELETED=0

list_at() {
  local prefix="$1"
  curl -fsS -X POST \
    "${SUPABASE_URL}/storage/v1/object/list/${BUCKET}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"prefix\":\"${prefix}\",\"limit\":${LIMIT},\"offset\":0}"
}

# Folders show up as items with id == null; files have a real id.
walk() {
  local prefix="$1"
  local response
  response=$(list_at "$prefix")

  # Files at this level
  local files
  files=$(echo "$response" | jq -r '.[] | select(.id != null) | .name')
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    local full="${prefix:+${prefix}/}${name}"
    curl -fsS -X DELETE \
      "${SUPABASE_URL}/storage/v1/object/${BUCKET}/${full}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" >/dev/null
    DELETED=$((DELETED + 1))
    printf "."
  done <<< "$files"

  # Recurse into folders
  local folders
  folders=$(echo "$response" | jq -r '.[] | select(.id == null) | .name')
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    local full="${prefix:+${prefix}/}${name}"
    walk "$full"
  done <<< "$folders"
}

echo "Purging gs://${BUCKET}…"
walk ""
echo
echo "Deleted ${DELETED} objects from bucket '${BUCKET}'."
