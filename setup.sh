#!/usr/bin/env bash
# Dead Wax Club — first-run setup
#
# Walks through everything that doesn't require Apple Developer:
#   1. Required CLI tools (xcodegen, supabase CLI, optional netlify CLI)
#   2. Local secrets files (Config/Secrets.xcconfig, web/js/config.js)
#   3. Supabase migrations
#   4. PowerSync sync rules pointer
#   5. Xcode project generation
#   6. Sanity verification
#
# Steps that depend on Apple (App ID, APNs key, AASA team ID, signing) are
# clearly flagged at the end.

set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

# --- pretty printing -------------------------------------------------------
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
step()  { printf "\n${BLUE}${BOLD}==>${NC} ${BOLD}%s${NC}\n" "$1"; }
ok()    { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${NC} %s\n" "$1"; }
err()   { printf "${RED}✗${NC} %s\n" "$1"; }
note()  { printf "${DIM}  %s${NC}\n" "$1"; }

# --- platform check --------------------------------------------------------
if [[ "${OSTYPE:-}" != darwin* ]]; then
    warn "This script is designed for macOS. Web/Supabase steps work elsewhere; Xcode steps will be skipped."
fi

is_mac() { [[ "${OSTYPE:-}" == darwin* ]]; }

# --- 1. Required tools -----------------------------------------------------
step "Checking required tools"
need() {
    local cmd="$1"; local hint="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd present"
    else
        err "$cmd not found — $hint"
        MISSING_TOOLS+=("$cmd")
    fi
}
MISSING_TOOLS=()

if is_mac; then
    if ! command -v brew >/dev/null 2>&1; then
        err "Homebrew is required on macOS — install from https://brew.sh"
        MISSING_TOOLS+=("brew")
    fi
    need xcodegen "brew install xcodegen"
fi
need supabase  "brew install supabase/tap/supabase"

# Optional tools — warn but don't fail.
if command -v netlify >/dev/null 2>&1; then
    ok "netlify CLI present (optional)"
else
    note "netlify CLI not installed (optional). Use \`npx netlify\` or install via \`brew install netlify-cli\`."
fi
if command -v psql >/dev/null 2>&1; then
    ok "psql present (optional, used to apply migrations)"
else
    note "psql not installed. Migrations applied via 'supabase db push' instead."
fi

if (( ${#MISSING_TOOLS[@]} > 0 )); then
    err "Install the missing tools above and re-run setup.sh."
    exit 1
fi

# --- 2. Local secrets templates -------------------------------------------
step "Local secrets"

if [[ ! -f Config/Secrets.xcconfig ]]; then
    cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
    warn "Created Config/Secrets.xcconfig from the example — fill in real values before building."
    note "  SUPABASE_URL, SUPABASE_ANON_KEY, POWERSYNC_URL, optional SENTRY_DSN"
else
    ok "Config/Secrets.xcconfig already exists"
fi

if [[ ! -f web/js/config.js ]]; then
    cp web/js/config.example.js web/js/config.js
    warn "Created web/js/config.js from the example — fill in your Supabase URL and anon key before deploying the web site."
else
    ok "web/js/config.js already exists"
fi

# Detect placeholder values.
if grep -q "your-supabase-anon-key\|your-project.supabase.co" Config/Secrets.xcconfig 2>/dev/null; then
    warn "Config/Secrets.xcconfig still contains placeholders. Edit it before building."
fi
if grep -q "your-supabase-anon-key\|your-project.supabase.co" web/js/config.js 2>/dev/null; then
    warn "web/js/config.js still contains placeholders. Edit it before deploying."
fi

# --- 3. Supabase project ---------------------------------------------------
step "Supabase project"

if [[ ! -f supabase/config.toml ]]; then
    note "Creating supabase/config.toml via supabase init"
    supabase init >/dev/null
fi

if ! supabase projects list >/dev/null 2>&1; then
    warn "supabase CLI is not logged in. Run \`supabase login\` and \`supabase link --project-ref <ref>\`, then re-run."
    note "Find the project ref at: supabase.com → your project → Settings → General"
else
    ok "supabase CLI is logged in"

    read -p "Apply Supabase migrations from supabase/migrations/ to your linked project now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        supabase db push
        ok "Migrations applied"
    else
        note "Skipped. To apply manually:"
        note "  supabase db push"
        note "Or paste each file in supabase/migrations/ into the Supabase SQL editor in order."
    fi
fi

# --- 4. PowerSync ----------------------------------------------------------
step "PowerSync"

note "Sync rules live at supabase/powersync/sync_rules.yaml."
note "Apply via the PowerSync dashboard:"
note "  1. https://powersync.com → your instance → Sync rules"
note "  2. Paste the contents of supabase/powersync/sync_rules.yaml"
note "  3. Validate, then Deploy"
note "(Or use the powersync CLI: \`powersync sync-rules apply supabase/powersync/sync_rules.yaml\`)"

# --- 5. Xcode project ------------------------------------------------------
if is_mac; then
    step "Generate Xcode project"
    if [[ -d DeadWaxClub.xcodeproj ]]; then
        rm -rf DeadWaxClub.xcodeproj
    fi
    xcodegen generate
    ok "Generated DeadWaxClub.xcodeproj"

    # Quick sanity build against the simulator (catches major SDK breakage early).
    if command -v xcodebuild >/dev/null 2>&1; then
        read -p "Run a sanity simulator build now? Takes a couple of minutes. [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            xcodebuild build \
                -project DeadWaxClub.xcodeproj \
                -scheme DeadWaxClub \
                -destination 'platform=iOS Simulator,name=iPhone 15' \
                -quiet
            ok "Simulator build succeeded"
        else
            note "Skipped. Run later with: xcodebuild build -project DeadWaxClub.xcodeproj -scheme DeadWaxClub -destination 'platform=iOS Simulator,name=iPhone 15'"
        fi
    fi
fi

# --- 6. Summary ------------------------------------------------------------
step "Done — what's next"
cat <<'EOF'

Local setup is finished. The remaining work needs Apple Developer access:

  1. Register App ID com.deadwaxclub.app with Sign in with Apple,
     Push Notifications, and Associated Domains capabilities.
  2. Create an APNs Auth Key (.p8) — note the Key ID, Team ID.
  3. Create a Services ID com.deadwaxclub.app.signin and a separate
     Sign in with Apple .p8 key.
  4. Supabase → Authentication → Providers → Apple: paste the Services
     ID, Team ID, Key ID, and the Sign in with Apple .p8 contents.
  5. Supabase → Edge Functions → Secrets:
       APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID
     Then `supabase functions deploy notify-price-change` and create
     the price_entries Insert webhook pointing at the function.
  6. Replace TEAMID in web/.well-known/apple-app-site-association
     with your real Apple Team ID, then `npx netlify deploy --dir=web --prod`.
  7. In Xcode → Signing & Capabilities, pick your paid team,
     plug your phone in, ⌘R.

See README.md for the full step-by-step.
EOF
