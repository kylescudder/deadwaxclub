#!/usr/bin/env bash
# First-run setup. Idempotent: safe to re-run at any time.
#
#   1. Required CLI tools (Homebrew, XcodeGen, the pinned Bun)
#   2. Local secrets (Config/Secrets.xcconfig) and any app extras
#   3. Backend dependencies
#   4. Xcode project generation and an optional simulator build
#
# This script never connects to or changes a production backend. Steps that
# need Apple Developer access are listed at the end. The app name, scheme and
# Bun version come from project.yml and Backend/package.json, so this file is
# identical in every app (Scripts/shared-ios-core.sha256). App-only steps live
# in Scripts/setup-extras.sh.

set -euo pipefail

cd "$(dirname "$0")"

APP="$(sed -n 's/^name: *//p' project.yml | head -1)"
BUN_VERSION="$(sed -n 's/.*"packageManager": *"bun@\([^"]*\)".*/\1/p' Backend/package.json)"

# --- pretty printing -------------------------------------------------------
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
step()  { printf "\n${BLUE}${BOLD}==>${NC} ${BOLD}%s${NC}\n" "$1"; }
ok()    { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${NC} %s\n" "$1"; }
err()   { printf "${RED}✗${NC} %s\n" "$1"; }
note()  { printf "${DIM}  %s${NC}\n" "$1"; }

is_mac() { [[ "${OSTYPE:-}" == darwin* ]]; }

if ! is_mac; then
    warn "This script is designed for macOS. Backend and site steps work elsewhere; Xcode steps will be skipped."
fi

# --- 1. Required tools -----------------------------------------------------
step "Checking required tools"
MISSING_TOOLS=()
need() {
    local cmd="$1"; local hint="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd present"
    else
        err "$cmd not found — $hint"
        MISSING_TOOLS+=("$cmd")
    fi
}

if is_mac; then
    need brew "install from https://brew.sh"
    need xcodegen "brew install xcodegen"
fi
need bun "install Bun $BUN_VERSION from https://bun.sh"

if (( ${#MISSING_TOOLS[@]} > 0 )); then
    err "Install the missing tools above and re-run setup.sh."
    exit 1
fi

if [[ "$(bun --version)" != "$BUN_VERSION" ]]; then
    err "Use Bun $BUN_VERSION (found $(bun --version)) to match CI and image builds."
    exit 1
fi
ok "Bun $BUN_VERSION matches Backend/package.json"

# --- 2. Local secrets ------------------------------------------------------
step "Local secrets"

if [[ ! -f Config/Secrets.xcconfig ]]; then
    cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
    warn "Created Config/Secrets.xcconfig from the example — fill in real values before running against a backend."
    note "API_URL, POWERSYNC_URL, optional PUSH_GATEWAY_URL and SENTRY_DSN"
    note "Escape URLs as https:/\$()/… in xcconfig files."
else
    ok "Config/Secrets.xcconfig already exists"
fi

if grep -Eq '\.invalid|your-instance\.powersync' Config/Secrets.xcconfig; then
    warn "Config/Secrets.xcconfig still has placeholders: the app builds, but auth and sync stay disabled."
fi

if [[ -f Scripts/setup-extras.sh ]]; then
    # shellcheck source=/dev/null
    source Scripts/setup-extras.sh
fi

# --- 3. Backend ------------------------------------------------------------
step "Backend"
(cd Backend && bun install --frozen-lockfile)
ok "Installed Backend dependencies"
note "Checks, migrations and the Herman deployment order: Backend/deploy/README.md"

# --- 4. Xcode project ------------------------------------------------------
if is_mac; then
    step "Generate Xcode project"
    rm -rf "$APP.xcodeproj"
    xcodegen generate
    ok "Generated $APP.xcodeproj"

    build_cmd="xcodebuild build -project $APP.xcodeproj -scheme $APP -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet"
    if [[ -t 0 ]]; then
        read -p "Run a sanity simulator build now? Takes a couple of minutes. [y/N] " -n 1 -r
        echo
    else
        REPLY=n
    fi
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        eval "$build_cmd"
        ok "Simulator build succeeded"
    else
        note "Skipped. Run later with: $build_cmd"
    fi
fi

# --- 5. Next steps ---------------------------------------------------------
step "Done — what's next"
cat <<EOF2

Local setup is finished. Open $APP.xcodeproj and press ⌘R to run in a simulator.

Running on a device or shipping needs Apple Developer access: the README's
"Apple setup" section lists the App IDs, capabilities, keys and provisioning
profiles, and "Releasing" covers the TestFlight secrets.
EOF2
