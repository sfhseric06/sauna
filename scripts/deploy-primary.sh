#!/bin/bash
# =============================================================================
# COMPLETE DEPLOYMENT SCRIPT FOR PRIMARY SHELLY PRO 2
# =============================================================================
# This script configures EVERYTHING needed on the Primary Shelly:
#   - Input modes (Button/Momentary)
#   - Relay defaults (OFF on power restore)
#   - Virtual Button for HA integration
#   - MQTT configuration
#   - Script upload and enable
#
# HARDWARE VERSION: Values below are for hardware v1.0
# See: hardware/versions/v1.0.yaml for authoritative configuration
#
# Usage: ./deploy-primary.sh [hostname] [mqtt_broker]
# Example: ./deploy-primary.sh shellypro2-0cb815fcaff4.local 192.168.1.100
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source device manifest
source "$SCRIPT_DIR/../hardware/devices.sh"

# Load cloud config + secrets if present (optional — cloud webhook is skipped if not configured)
CLOUD_CONFIG="$SCRIPT_DIR/../cloud/config.sh"
CLOUD_SECRETS="$SCRIPT_DIR/../cloud/secrets.sh"
if [ -f "$CLOUD_CONFIG" ]; then source "$CLOUD_CONFIG"; fi
if [ -f "$CLOUD_SECRETS" ]; then source "$CLOUD_SECRETS"; fi

# -----------------------------------------------------------------------------
# CONFIGURATION
# Defaults are loaded from hardware/devices.sh - override with arguments
# -----------------------------------------------------------------------------
DEVICE_HOST="${1:-$PRIMARY_HOSTNAME}"
MQTT_BROKER="${2:-}"  # Optional: MQTT broker IP/hostname
SCRIPT_FILE="$SCRIPT_DIR/../devices/shelly-primary/script.js"
SCRIPT_ID="1"
VIRTUAL_BUTTON_ID="200"  # From hardware/versions/v1.0.yaml

# Device configuration
DEVICE_NAME="Sauna Primary Controller"

echo "=============================================="
echo "  PRIMARY SHELLY COMPLETE DEPLOYMENT"
echo "=============================================="
echo "Target Device: $DEVICE_HOST"
echo "Script File: $SCRIPT_FILE"
echo ""

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS
# -----------------------------------------------------------------------------

rpc_call() {
    local endpoint="$1"
    local data="$2"
    local result
    
    if [ -n "$data" ]; then
        result=$(curl -s -X POST "http://$DEVICE_HOST/rpc/$endpoint" \
            -H "Content-Type: application/json" \
            -d "$data" 2>&1)
    else
        result=$(curl -s "http://$DEVICE_HOST/rpc/$endpoint" 2>&1)
    fi
    
    echo "$result"
}

check_error() {
    local result="$1"
    local context="$2"
    
    if echo "$result" | grep -q '"error"'; then
        echo "  ⚠ Warning during $context:"
        echo "    $result"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# CONNECTIVITY CHECK
# -----------------------------------------------------------------------------

echo "Step 1: Checking device connectivity..."
DEVICE_INFO=$(rpc_call "Shelly.GetDeviceInfo")
if ! check_error "$DEVICE_INFO" "connectivity check"; then
    echo "ERROR: Cannot reach $DEVICE_HOST"
    echo "Check that the device is online and hostname is correct."
    exit 1
fi

DEVICE_ID=$(echo "$DEVICE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','unknown'))" 2>/dev/null || echo "unknown")
echo "  ✓ Connected to: $DEVICE_ID"
echo ""

# -----------------------------------------------------------------------------
# CONFIGURE INPUT 0 (RC Button - Momentary)
# -----------------------------------------------------------------------------

echo "Step 2: Configuring Input 0 (RC Button)..."
INPUT0_CONFIG='{
    "id": 0,
    "config": {
        "name": "RC Button",
        "type": "button",
        "enable": true
    }
}'
RESULT=$(rpc_call "Input.SetConfig" "$INPUT0_CONFIG")
if check_error "$RESULT" "Input 0 config"; then
    echo "  ✓ Input 0 configured as Button (momentary)"
fi

# -----------------------------------------------------------------------------
# CONFIGURE RELAY 0 (Main Contactor)
# -----------------------------------------------------------------------------

echo "Step 3: Configuring Relay 0 (Main Contactor)..."
SWITCH0_CONFIG='{
    "id": 0,
    "config": {
        "name": "Main Contactor",
        "in_mode": "detached",
        "initial_state": "off",
        "auto_on": false,
        "auto_off": false
    }
}'
RESULT=$(rpc_call "Switch.SetConfig" "$SWITCH0_CONFIG")
if check_error "$RESULT" "Switch 0 config"; then
    echo "  ✓ Relay 0: 'Main Contactor', default OFF, input detached"
fi

# -----------------------------------------------------------------------------
# CONFIGURE RELAY 1 (Indicator Light)
# -----------------------------------------------------------------------------

echo "Step 4: Configuring Relay 1 (Indicator Light)..."
SWITCH1_CONFIG='{
    "id": 1,
    "config": {
        "name": "Indicator Light",
        "in_mode": "detached",
        "initial_state": "off",
        "auto_on": false,
        "auto_off": false
    }
}'
RESULT=$(rpc_call "Switch.SetConfig" "$SWITCH1_CONFIG")
if check_error "$RESULT" "Switch 1 config"; then
    echo "  ✓ Relay 1: 'Indicator Light', default OFF, input detached"
fi

# -----------------------------------------------------------------------------
# CREATE/CONFIGURE VIRTUAL BUTTON (ID 200 for HA)
# -----------------------------------------------------------------------------

echo "Step 5: Configuring Virtual Button (ID $VIRTUAL_BUTTON_ID for HA integration)..."

# Check if virtual component exists
VIRTUAL_STATUS=$(rpc_call "Virtual.GetStatus?id=$VIRTUAL_BUTTON_ID" 2>/dev/null || echo '{"error":{}}')

if echo "$VIRTUAL_STATUS" | grep -q '"error"'; then
    echo "  Creating Virtual Button $VIRTUAL_BUTTON_ID..."
    CREATE_RESULT=$(rpc_call "Virtual.Add" "{\"type\": \"button\", \"id\": $VIRTUAL_BUTTON_ID}")
    if check_error "$CREATE_RESULT" "Virtual Button creation"; then
        echo "  ✓ Virtual Button $VIRTUAL_BUTTON_ID created"
    fi
else
    echo "  Virtual Button $VIRTUAL_BUTTON_ID already exists"
fi

# Configure the virtual button
VIRTUAL_CONFIG="{
    \"id\": $VIRTUAL_BUTTON_ID,
    \"config\": {
        \"name\": \"HA Toggle Button\"
    }
}"
RESULT=$(rpc_call "Virtual.SetConfig" "$VIRTUAL_CONFIG")
check_error "$RESULT" "Virtual Button config" || true
echo "  ✓ Virtual Button configured for Home Assistant integration"

# -----------------------------------------------------------------------------
# CONFIGURE MQTT (if broker specified)
# -----------------------------------------------------------------------------

if [ -n "$MQTT_BROKER" ]; then
    echo "Step 6: Configuring MQTT..."
    
    MQTT_CONFIG="{
        \"config\": {
            \"enable\": true,
            \"server\": \"$MQTT_BROKER:1883\",
            \"client_id\": \"$DEVICE_ID\",
            \"user\": null,
            \"pass\": null,
            \"ssl_ca\": null,
            \"topic_prefix\": \"$DEVICE_ID\",
            \"rpc_ntf\": true,
            \"status_ntf\": true
        }
    }"
    RESULT=$(rpc_call "MQTT.SetConfig" "$MQTT_CONFIG")
    if check_error "$RESULT" "MQTT config"; then
        echo "  ✓ MQTT configured: broker=$MQTT_BROKER"
    fi
else
    echo "Step 6: Skipping MQTT configuration (no broker specified)"
    echo "  To configure MQTT, run: $0 $DEVICE_HOST <mqtt_broker_ip>"
fi
echo ""

# -----------------------------------------------------------------------------
# CONFIGURE RPC SETTINGS
# -----------------------------------------------------------------------------

echo "Step 7: Configuring RPC/System settings..."

# Ensure scripting is enabled
SYS_CONFIG='{
    "config": {
        "device": {
            "name": "'"$DEVICE_NAME"'"
        }
    }
}'
RESULT=$(rpc_call "Sys.SetConfig" "$SYS_CONFIG")
check_error "$RESULT" "System config" || true
echo "  ✓ Device name set to: $DEVICE_NAME"
echo ""

# -----------------------------------------------------------------------------
# UPLOAD AND ENABLE SCRIPT
# -----------------------------------------------------------------------------

echo "Step 8: Uploading control script..."

if [ ! -f "$SCRIPT_FILE" ]; then
    echo "ERROR: Script file not found: $SCRIPT_FILE"
    exit 1
fi

# Substitute cloud Worker placeholders if config is available
SCRIPT_CONTENT=$(cat "$SCRIPT_FILE")
if [ -n "$WORKER_URL" ] && [ -n "$WEBHOOK_SECRET" ]; then
    SCRIPT_CONTENT="${SCRIPT_CONTENT//__WORKER_URL__/$WORKER_URL}"
    SCRIPT_CONTENT="${SCRIPT_CONTENT//__WORKER_SECRET__/$WEBHOOK_SECRET}"
    echo "  ✓ Cloud Worker URL injected: $WORKER_URL"
else
    echo "  ⚠ Cloud config not found — Worker webhook will be inactive"
    echo "    (run deploy-cloud.sh first, then re-run this script)"
    # Leave placeholders — script will still work, HTTP.POST will just fail silently
fi

# Check if script slot exists
SCRIPT_STATUS=$(rpc_call "Script.GetStatus?id=$SCRIPT_ID" 2>/dev/null || echo '{"error":{}}')

if echo "$SCRIPT_STATUS" | grep -q '"error"'; then
    echo "  Creating script slot $SCRIPT_ID..."
    rpc_call "Script.Create" '{"name": "Primary Control Logic"}' > /dev/null
fi

# Stop script if running
echo "  Stopping existing script..."
rpc_call "Script.Stop?id=$SCRIPT_ID" > /dev/null 2>&1 || true
sleep 1

# Clear and upload script in chunks
echo "  Uploading script code..."
rpc_call "Script.PutCode" "{\"id\": $SCRIPT_ID, \"code\": \"\"}" > /dev/null

CHUNK_SIZE=1400
CONTENT_LENGTH=${#SCRIPT_CONTENT}
OFFSET=0

while [ $OFFSET -lt $CONTENT_LENGTH ]; do
    CHUNK="${SCRIPT_CONTENT:$OFFSET:$CHUNK_SIZE}"
    CHUNK_ESCAPED=$(echo -n "$CHUNK" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    
    if [ $OFFSET -eq 0 ]; then
        RESULT=$(rpc_call "Script.PutCode" "{\"id\": $SCRIPT_ID, \"code\": $CHUNK_ESCAPED}")
    else
        RESULT=$(rpc_call "Script.PutCode" "{\"id\": $SCRIPT_ID, \"code\": $CHUNK_ESCAPED, \"append\": true}")
    fi
    
    if echo "$RESULT" | grep -q '"error"'; then
        echo "ERROR uploading chunk at offset $OFFSET:"
        echo "$RESULT"
        exit 1
    fi
    
    OFFSET=$((OFFSET + CHUNK_SIZE))
    echo -n "."
done
echo ""
echo "  ✓ Script uploaded (${CONTENT_LENGTH} bytes)"

# Enable script to run on startup
echo "  Enabling script to run on startup..."
rpc_call "Script.SetConfig" "{\"id\": $SCRIPT_ID, \"config\": {\"enable\": true}}" > /dev/null
echo "  ✓ Script enabled"

# Start script
echo "  Starting script..."
rpc_call "Script.Start?id=$SCRIPT_ID" > /dev/null
sleep 2

# Verify script is running
STATUS=$(rpc_call "Script.GetStatus?id=$SCRIPT_ID")
if echo "$STATUS" | grep -q '"running":true'; then
    echo "  ✓ Script is running"
else
    echo "  ⚠ Warning: Script may not be running"
    echo "    Status: $STATUS"
fi
echo ""

# -----------------------------------------------------------------------------
# FINAL VERIFICATION
# -----------------------------------------------------------------------------

echo "Step 9: Final verification..."

echo "  Checking all configurations..."

# Verify inputs
INPUT0=$(rpc_call "Input.GetConfig?id=0")
echo "  Input 0: $(echo "$INPUT0" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"type={d.get('type','?')}, name={d.get('name','?')}\")" 2>/dev/null || echo "check manually")"

# Verify switches
SWITCH0=$(rpc_call "Switch.GetConfig?id=0")
echo "  Switch 0: $(echo "$SWITCH0" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"initial_state={d.get('initial_state','?')}, name={d.get('name','?')}\")" 2>/dev/null || echo "check manually")"

SWITCH1=$(rpc_call "Switch.GetConfig?id=1")
echo "  Switch 1: $(echo "$SWITCH1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"initial_state={d.get('initial_state','?')}, name={d.get('name','?')}\")" 2>/dev/null || echo "check manually")"

# Verify MQTT
MQTT=$(rpc_call "MQTT.GetStatus")
MQTT_CONNECTED=$(echo "$MQTT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('connected', False))" 2>/dev/null || echo "?")
echo "  MQTT connected: $MQTT_CONNECTED"

echo ""
echo "=============================================="
echo "  DEPLOYMENT COMPLETE"
echo "=============================================="
echo ""
echo "Configured:"
echo "  ✓ Input 0: Button mode (RC Button)"
echo "  ✓ Relay 0: Main Contactor, default OFF"
echo "  ✓ Relay 1: Indicator Light, default OFF"
echo "  ✓ Virtual Button $VIRTUAL_BUTTON_ID: HA integration"
echo "  ✓ Script: Primary Control Logic"
echo ""
echo "To test:"
echo "  1. Press RC button - should toggle sauna"
echo "  2. Call REST API:"
echo "     curl 'http://$DEVICE_HOST/rpc/Button.Trigger?id=$VIRTUAL_BUTTON_ID&event=single_push'"
echo "  3. Check MQTT topics (if configured)"
echo ""
echo "For BTHome BLU Button pairing, use the Shelly web UI:"
echo "  http://$DEVICE_HOST"
