#!/bin/bash
# =============================================================================
# ONE-CLICK SAUNA DEPLOY
# =============================================================================
# Deploys everything in the correct order:
#   1. Cloudflare Worker (cloud infrastructure)
#   2. Primary Shelly (main control script)
#   3. Secondary Shelly (safety script)
#   4. Post-deploy verification
#
# Usage:
#   ./deploy.sh              — deploy everything
#   ./deploy.sh --cloud      — cloud Worker only
#   ./deploy.sh --primary    — primary Shelly only
#   ./deploy.sh --secondary  — secondary Shelly only
#   ./deploy.sh --local      — both Shellys, no cloud
#   ./deploy.sh --verify     — run tests only (no deploy)
#
# First time? See cloud/README.md before running.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET="${1:-all}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step() { echo -e "\n${YELLOW}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }

echo "=============================================="
echo "  SAUNA ONE-CLICK DEPLOY"
echo "=============================================="
echo "Target: $TARGET"
echo "Time:   $(date)"
echo ""

# Sanity check: never deploy to secondary with incomplete script
SECONDARY_LINES=$(wc -l < devices/shelly-secondary/script.js | tr -d ' ')
if [[ "$TARGET" == "all" || "$TARGET" == "--secondary" || "$TARGET" == "--local" ]]; then
    if [ "$SECONDARY_LINES" -lt 100 ]; then
        fail "Secondary script is only $SECONDARY_LINES lines — looks incomplete. Aborting."
    fi
fi

# --- Cloud ---
if [[ "$TARGET" == "all" || "$TARGET" == "--cloud" ]]; then
    step "Deploying Cloudflare Worker..."
    if [ ! -f "cloud/secrets.sh" ]; then
        warn "cloud/secrets.sh not found — skipping cloud deploy"
        warn "  cp cloud/secrets.sh.example cloud/secrets.sh && fill in values"
    else
        bash scripts/deploy-cloud.sh
        ok "Cloud Worker deployed"
    fi
fi

# --- Primary Shelly ---
if [[ "$TARGET" == "all" || "$TARGET" == "--primary" || "$TARGET" == "--local" ]]; then
    step "Deploying Primary Shelly..."
    bash scripts/deploy-primary.sh
    ok "Primary Shelly deployed"
fi

# --- Secondary Shelly ---
if [[ "$TARGET" == "all" || "$TARGET" == "--secondary" || "$TARGET" == "--local" ]]; then
    step "Deploying Secondary Shelly..."
    bash scripts/deploy-secondary.sh
    ok "Secondary Shelly deployed"
fi

# --- Verify ---
if [[ "$TARGET" != "--cloud" ]]; then
    step "Running post-deploy verification..."
    if bash tests/test-deployment.sh all; then
        ok "All tests passed"
    else
        fail "Tests failed — check output above before using sauna"
    fi
fi

echo ""
echo "=============================================="
echo -e "  ${GREEN}DEPLOY COMPLETE${NC}"
echo "=============================================="

# Show Worker URL if available
if [ -f "cloud/config.sh" ]; then
    source cloud/config.sh
    if [ -n "$WORKER_URL" ] && [[ "$WORKER_URL" != *"your-subdomain"* ]]; then
        echo ""
        echo "  Status: GET $WORKER_URL/status"
        echo "  SMS:    text 'status', 'on', or 'off' to your Twilio number"
    fi
fi
