#!/usr/bin/env bash
# Writes web/js/config.js from environment variables at deploy time.
# Set SUPABASE_URL and SUPABASE_ANON_KEY under
# Netlify dashboard → Site settings → Environment variables.

set -euo pipefail

if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_ANON_KEY:-}" ]]; then
    echo "✗ SUPABASE_URL and SUPABASE_ANON_KEY must be set in Netlify env." >&2
    echo "  Configure them at: Netlify → Site settings → Environment variables" >&2
    exit 1
fi

# JSON-escape just the characters we care about (backslash + double-quote).
escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

cat > web/js/config.js <<EOF
// Generated at build time by web/build-config.sh from Netlify env vars.
// Edit Netlify environment variables to change values; do not edit by hand.
window.DEADWAXCLUB_CONFIG = {
    supabaseUrl: "$(escape "$SUPABASE_URL")",
    supabaseAnonKey: "$(escape "$SUPABASE_ANON_KEY")",
};
EOF

echo "✓ Wrote web/js/config.js for $SUPABASE_URL"
