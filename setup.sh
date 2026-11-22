#!/usr/bin/env bash
# Deadwax Club — first-run setup
#
# Walks through everything that doesn't require Apple Developer:
#   1. Required CLI tools (xcodegen, bun)
#   2. Local secrets files (Config/Secrets.xcconfig, Site/public/js/config.js)
#   3. Backend pointer (Herman API, PostgreSQL and PowerSync)
#   4. Xcode project generation
#   5. Sanity verification
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
    warn "This script is designed for macOS. Web and backend steps work elsewhere; Xcode steps will be skipped."
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
need bun       "brew install oven-sh/bun/bun"


if (( ${#MISSING_TOOLS[@]} > 0 )); then
    err "Install the missing tools above and re-run setup.sh."
    exit 1
fi

# --- 2. Local secrets templates -------------------------------------------
step "Local secrets"

if [[ ! -f Config/Secrets.xcconfig ]]; then
    cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
    warn "Created Config/Secrets.xcconfig from the example — fill in real values before building."
    note "  API_URL, POWERSYNC_URL, optional SENTRY_DSN"
else
    ok "Config/Secrets.xcconfig already exists"
fi

if [[ ! -f Site/public/js/config.js ]]; then
    cp Site/public/js/config.example.js Site/public/js/config.js
    ok "Created Site/public/js/config.js (Deadwax API origin https://auth.deadwaxclub.app)"
else
    ok "Site/public/js/config.js already exists"
fi

# Detect placeholder values.
if grep -q "api.example.com\|your-instance.powersync" Config/Secrets.xcconfig 2>/dev/null; then
    warn "Config/Secrets.xcconfig still contains placeholders. Edit it before building."
fi

# --- 3. Backend -----------------------------------------------------------
step "Backend"

note "The API, PostgreSQL schema and PowerSync sync config live in Backend/."
note "Local checks and the Herman deployment order: Backend/deploy/README.md"

# --- 4. Xcode project ------------------------------------------------------
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
                -destination 'generic/platform=iOS Simulator' \
                -quiet
            ok "Simulator build succeeded"
        else
            note "Skipped. Run later with: xcodebuild build -project DeadWaxClub.xcodeproj -scheme DeadWaxClub -destination 'generic/platform=iOS Simulator'"
        fi
    fi
fi

# --- 5. Summary ------------------------------------------------------------
step "Done — what's next"
cat <<'EOF'

Local setup is finished. The remaining work needs Apple Developer access:

  1. Register App ID com.deadwaxclub.app with Sign in with Apple,
     Push Notifications, and Associated Domains capabilities.
  2. Create an APNs Auth Key (.p8) — note the Key ID, Team ID.
  3. Create a Services ID com.deadwaxclub.app.signin and a separate
     Sign in with Apple .p8 key.
  4. Put the Apple sign-in values in the Herman API's protected api.env
     (Backend/deploy/api.env.example lists them). Push notifications go
     through the shared APNs gateway (docs/push-gateway.md).
  5. Check the Apple Team ID in Site/public/.well-known/apple-app-site-association.
     Merging a Site/ change to main deploys the site to Herman.
  6. In Xcode → Signing & Capabilities, pick your paid team,
     plug your phone in, ⌘R.

See README.md for the full step-by-step.
EOF
