#!/bin/bash
# =============================================================================
# DEPLOY CLOUDFLARE WORKER
# =============================================================================
# Deploys the sauna cloud worker including:
#   - KV namespace creation (first run only)
#   - wrangler.toml configuration
#   - All Cloudflare secrets
#   - Worker deployment
#
# Prerequisites:
#   - npm install in cloud/worker/ (or run ./deploy.sh which handles this)
#   - cloud/config.sh filled in
#   - cloud/secrets.sh filled in (copy from secrets.sh.example)
#   - wrangler authenticated: npx wrangler login
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
WORKER_DIR="$PROJECT_ROOT/cloud/worker"
CONFIG="$PROJECT_ROOT/cloud/config.sh"
SECRETS="$PROJECT_ROOT/cloud/secrets.sh"

echo "=============================================="
echo "  SAUNA CLOUD WORKER DEPLOYMENT"
echo "=============================================="

# --- Load config ---
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: cloud/config.sh not found. Copy and fill in the values."
    exit 1
fi
source "$CONFIG"

if [ ! -f "$SECRETS" ]; then
    echo "ERROR: cloud/secrets.sh not found."
    echo "  cp cloud/secrets.sh.example cloud/secrets.sh"
    echo "  Then fill in your secrets."
    exit 1
fi
source "$SECRETS"

# --- Validate required values ---
check_required() {
    local var="$1"
    local name="$2"
    local file="$3"
    if [ -z "${!var}" ] || [[ "${!var}" == *"your-"* ]] || [[ "${!var}" == *"generate-"* ]]; then
        echo "ERROR: $name not set in $file"
        exit 1
    fi
}

check_required CLOUDFLARE_SUBDOMAIN  "CLOUDFLARE_SUBDOMAIN"  "cloud/config.sh"
check_required SHELLY_CLOUD_SERVER   "SHELLY_CLOUD_SERVER"   "cloud/config.sh"
check_required GRAFANA_METRICS_URL   "GRAFANA_METRICS_URL"   "cloud/config.sh"
check_required GRAFANA_METRICS_USER  "GRAFANA_METRICS_USER"  "cloud/config.sh"
check_required AUTHORIZED_USERS      "AUTHORIZED_USERS"      "cloud/secrets.sh"
check_required SHELLY_AUTH_KEY       "SHELLY_AUTH_KEY"       "cloud/secrets.sh"
check_required TWILIO_AUTH_TOKEN     "TWILIO_AUTH_TOKEN"     "cloud/secrets.sh"
check_required WEBHOOK_SECRET        "WEBHOOK_SECRET"        "cloud/secrets.sh"
check_required GRAFANA_API_KEY       "GRAFANA_API_KEY"       "cloud/secrets.sh"

cd "$WORKER_DIR"

# --- Install dependencies ---
echo "Step 1: Installing dependencies..."
npm install --silent
echo "  ✓ Dependencies installed"
echo ""

# --- KV namespace ---
echo "Step 2: Checking KV namespace..."
TOML="$WORKER_DIR/wrangler.toml"

if grep -q "KV_NAMESPACE_ID_PLACEHOLDER" "$TOML"; then
    echo "  Creating KV namespace (first run)..."
    KV_OUTPUT=$(npx wrangler kv:namespace create sauna 2>&1)
    KV_ID=$(echo "$KV_OUTPUT" | grep -o 'id = "[^"]*"' | cut -d'"' -f2)
    # Fall back to old wrangler output format
    if [ -z "$KV_ID" ]; then
        KV_ID=$(echo "$KV_OUTPUT" | grep -o '"id": "[^"]*"' | cut -d'"' -f4)
    fi

    if [ -z "$KV_ID" ]; then
        echo "ERROR: Could not parse KV namespace ID from wrangler output:"
        echo "$KV_OUTPUT"
        exit 1
    fi

    sed -i.bak "s/KV_NAMESPACE_ID_PLACEHOLDER/$KV_ID/" "$TOML"
    rm -f "$TOML.bak"
    echo "  ✓ KV namespace created: $KV_ID"
    echo "    (ID saved to wrangler.toml — commit this change)"
else
    echo "  ✓ KV namespace already configured"
fi
echo ""

# --- Vars in wrangler.toml ---
echo "Step 3: Updating wrangler.toml vars..."

# Rebuild the vars section (idempotent)
# Remove any existing [vars] block and re-append
python3 - <<PYEOF
import re

with open('wrangler.toml', 'r') as f:
    content = f.read()

# Strip existing [vars] block if present
content = re.sub(r'\n\[vars\].*', '', content, flags=re.DOTALL)
content = content.rstrip()

vars_block = """

[vars]
SHELLY_CLOUD_SERVER  = "$SHELLY_CLOUD_SERVER"
PRIMARY_DEVICE_ID    = "$PRIMARY_DEVICE_ID"
SECONDARY_DEVICE_ID  = "$SECONDARY_DEVICE_ID"
EXTERIOR_DEVICE_ID   = "$EXTERIOR_DEVICE_ID"
HVAC_DEVICE_ID       = "$HVAC_DEVICE_ID"
LED_DEVICE_ID        = "$LED_DEVICE_ID"
GRAFANA_METRICS_URL  = "$GRAFANA_METRICS_URL"
GRAFANA_METRICS_USER = "$GRAFANA_METRICS_USER"
"""

with open('wrangler.toml', 'w') as f:
    f.write(content + vars_block)

print("  ✓ wrangler.toml vars updated")
PYEOF
echo ""

# --- Secrets ---
echo "Step 4: Setting Cloudflare secrets..."
echo "$SHELLY_AUTH_KEY"   | npx wrangler secret put SHELLY_AUTH_KEY   --name "$WORKER_NAME" 2>&1 | grep -v "^$" || true
echo "$TWILIO_AUTH_TOKEN" | npx wrangler secret put TWILIO_AUTH_TOKEN --name "$WORKER_NAME" 2>&1 | grep -v "^$" || true
echo "$WEBHOOK_SECRET"    | npx wrangler secret put WEBHOOK_SECRET    --name "$WORKER_NAME" 2>&1 | grep -v "^$" || true
echo "$GRAFANA_API_KEY"    | npx wrangler secret put GRAFANA_API_KEY    --name "$WORKER_NAME" 2>&1 | grep -v "^$" || true
echo "$AUTHORIZED_USERS"  | npx wrangler secret put AUTHORIZED_USERS  --name "$WORKER_NAME" 2>&1 | grep -v "^$" || true
echo "  ✓ Secrets set"
echo ""

# --- Deploy ---
echo "Step 5: Deploying worker..."
npx wrangler deploy
echo ""

# --- Grafana dashboard ---
echo "Step 6: Deploying Grafana dashboard..."
DASHBOARD_JSON="$PROJECT_ROOT/cloud/grafana-dashboard.json"

if [ -z "$GRAFANA_ADMIN_KEY" ]; then
    echo "  ⚠ Skipping — GRAFANA_ADMIN_KEY not set in cloud/secrets.sh"
    echo "    To deploy the dashboard:"
    echo "    1. panoramasauna.grafana.net → Administration → Service accounts"
    echo "    2. Create service account with Editor role → Add token"
    echo "    3. Add GRAFANA_ADMIN_KEY=\"your-token\" to cloud/secrets.sh"
elif [ ! -f "$DASHBOARD_JSON" ]; then
    echo "  ⚠ Skipping — cloud/grafana-dashboard.json not found"
else
    GRAFANA_HOST="panoramasauna.grafana.net"

    # Find the Prometheus datasource UID.
    # Use configured value if set, otherwise try API (requires datasources:read permission).
    DS_UID="${GRAFANA_DATASOURCE_UID:-}"

    if [ -z "$DS_UID" ]; then
        DS_RESPONSE=$(curl -sf "https://$GRAFANA_HOST/api/datasources" \
            -H "Authorization: Bearer $GRAFANA_ADMIN_KEY" 2>&1)
        DS_UID=$(echo "$DS_RESPONSE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for ds in data:
    if ds.get('type') == 'prometheus':
        print(ds.get('uid', ''))
        break
" 2>/dev/null)
    fi

    if [ -z "$DS_UID" ]; then
        echo "  ⚠ Could not determine Prometheus datasource UID."
        echo "    Option A: Set GRAFANA_DATASOURCE_UID in cloud/config.sh"
        echo "              (find it: Grafana → Connections → Data sources → Prometheus → URL has uid=xxxxx)"
        echo "    Option B: Give the service account Admin role in Grafana → Administration → Service accounts"
    else
        echo "  ✓ Prometheus datasource UID: $DS_UID"

        # Import dashboard, substituting the datasource input.
        # Pass key as arg (not env) since sourced vars aren't exported to subprocesses.
        IMPORT_RESULT=$(python3 - "$DASHBOARD_JSON" "$DS_UID" "$GRAFANA_ADMIN_KEY" <<'PYEOF'
import json, sys, urllib.request

dashboard_file = sys.argv[1]
ds_uid         = sys.argv[2]
grafana_key    = sys.argv[3]

with open(dashboard_file) as f:
    dash = json.load(f)

# Remove import-only fields
dash.pop('__inputs', None)
dash.pop('__requires', None)
dash.pop('id', None)

# Substitute datasource UID throughout
dash_str = json.dumps(dash).replace('${DS_PROMETHEUS}', ds_uid)
dash = json.loads(dash_str)

payload = json.dumps({
    'dashboard': dash,
    'overwrite': True,
    'inputs': [{'name': 'DS_PROMETHEUS', 'type': 'datasource', 'pluginId': 'prometheus', 'value': ds_uid}],
    'folderId': 0,
}).encode()

grafana_host = 'panoramasauna.grafana.net'

req = urllib.request.Request(
    f'https://{grafana_host}/api/dashboards/import',
    data=payload,
    headers={
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {grafana_key}',
    }
)
try:
    resp = urllib.request.urlopen(req, timeout=15)
    result = json.loads(resp.read())
    print(result.get('status', 'ok'), result.get('slug', ''), result.get('importedUrl', ''))
except urllib.error.HTTPError as e:
    print('ERROR', e.code, e.read().decode())
PYEOF
)

        if echo "$IMPORT_RESULT" | grep -q "ERROR"; then
            echo "  ⚠ Dashboard import failed: $IMPORT_RESULT"
        else
            DASH_URL=$(echo "$IMPORT_RESULT" | awk '{print $3}')
            echo "  ✓ Dashboard deployed: https://$GRAFANA_HOST$DASH_URL"
        fi
    fi
fi
echo ""

echo "=============================================="
echo "  WORKER DEPLOYMENT COMPLETE"
echo "=============================================="
echo ""
echo "  Worker URL: $WORKER_URL"
echo ""
echo "  Endpoints:"
echo "    POST $WORKER_URL/sms    <- Twilio webhook"
echo "    POST $WORKER_URL/event  <- Shelly primary script"
echo "    GET  $WORKER_URL/status <- status check"
echo ""
echo "  Next: configure Twilio to send inbound SMS to:"
echo "    $WORKER_URL/sms"
