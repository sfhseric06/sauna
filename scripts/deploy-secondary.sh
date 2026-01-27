#!/bin/bash
# =============================================================================
# COMPLETE DEPLOYMENT SCRIPT FOR SECONDARY SHELLY PRO 2 (SAFETY DEVICE)
# =============================================================================
# This script configures EVERYTHING needed on the Secondary Shelly:
#   - Input modes (Switch for sense lines)
#   - Relay defaults (OFF on power restore) - CRITICAL SAFETY
#   - Script upload and enable
#
# Usage: ./deploy-secondary.sh [hostname]
# Example: ./deploy-secondary.sh shellypro2-0cb815fc96dc.local
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source device manifest
source "$SCRIPT_DIR/../hardware/devices.sh"

# -----------------------------------------------------------------------------
# CONFIGURATION
# Defaults are loaded from hardware/devices.sh - override with arguments
# -----------------------------------------------------------------------------
DEVICE_HOST="${1:-$SECONDARY_HOSTNAME}"
SCRIPT_FILE="$SCRIPT_DIR/../devices/shelly-secondary/script.js"
SCRIPT_ID="1"

# Device configuration
DEVICE_NAME="Sauna Safety Controller"

echo "=============================================="
echo "  SECONDARY SHELLY COMPLETE DEPLOYMENT"
echo "  (SAFETY DEVICE)"
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
# SCRIPT COMPLETENESS CHECK
# -----------------------------------------------------------------------------

echo "Step 2: Checking script completeness..."
if [ ! -f "$SCRIPT_FILE" ]; then
    echo "ERROR: Script file not found: $SCRIPT_FILE"
    exit 1
fi

LINE_COUNT=$(wc -l < "$SCRIPT_FILE" | tr -d ' ')
if [ "$LINE_COUNT" -lt 100 ]; then
    echo ""
    echo "  ⚠️  WARNING: Secondary script appears INCOMPLETE ($LINE_COUNT lines)"
    echo "     The safety script should have ~150+ lines including:"
    echo "     - Input event handlers for sense lines"
    echo "     - Safety relay control logic"  
    echo "     - Weld detection timeout"
    echo ""
    echo "     Deploying an incomplete safety script is DANGEROUS!"
    echo ""
    read -p "     Continue anyway? (type 'yes' to confirm): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Deployment aborted."
        exit 1
    fi
fi
echo "  ✓ Script file found ($LINE_COUNT lines)"
echo ""

# -----------------------------------------------------------------------------
# CONFIGURE INPUT 0 (SW1 - Secondary Contactor Feedback)
# -----------------------------------------------------------------------------

echo "Step 3: Configuring Input 0 (Secondary Contactor Sense - SW1)..."
INPUT0_CONFIG='{
    "id": 0,
    "config": {
        "name": "SW1 Secondary Sense",
        "type": "switch",
        "enable": true
    }
}'
RESULT=$(rpc_call "Input.SetConfig" "$INPUT0_CONFIG")
if check_error "$RESULT" "Input 0 config"; then
    echo "  ✓ Input 0: Switch mode, monitors secondary contactor feedback"
fi

# -----------------------------------------------------------------------------
# CONFIGURE INPUT 1 (SW2 - Primary Contactor Sense)
# -----------------------------------------------------------------------------

echo "Step 4: Configuring Input 1 (Primary Contactor Sense - SW2)..."
INPUT1_CONFIG='{
    "id": 1,
    "config": {
        "name": "SW2 Primary Sense",
        "type": "switch",
        "enable": true
    }
}'
RESULT=$(rpc_call "Input.SetConfig" "$INPUT1_CONFIG")
if check_error "$RESULT" "Input 1 config"; then
    echo "  ✓ Input 1: Switch mode, monitors primary contactor output"
fi

# -----------------------------------------------------------------------------
# CONFIGURE RELAY 0 (Safety Contactor) - CRITICAL SAFETY SETTINGS
# -----------------------------------------------------------------------------

echo "Step 5: Configuring Relay 0 (Safety Contactor) - CRITICAL..."
SWITCH0_CONFIG='{
    "id": 0,
    "config": {
        "name": "Safety Contactor",
        "in_mode": "detached",
        "initial_state": "off",
        "auto_on": false,
        "auto_off": true,
        "auto_off_delay": 3660
    }
}'
# auto_off_delay: 3660 seconds = 61 minutes (backup safety cutoff)

RESULT=$(rpc_call "Switch.SetConfig" "$SWITCH0_CONFIG")
if check_error "$RESULT" "Switch 0 config"; then
    echo "  ✓ Relay 0: 'Safety Contactor'"
    echo "    - Default: OFF (CRITICAL - fail-safe)"
    echo "    - Auto-off: 61 minutes (firmware backup timer)"
    echo "    - Input: Detached (controlled by script)"
fi
echo ""

# -----------------------------------------------------------------------------
# CONFIGURE SYSTEM/DEVICE NAME
# -----------------------------------------------------------------------------

echo "Step 6: Configuring system settings..."
SYS_CONFIG='{
    "config": {
        "device": {
            "name": "'"$DEVICE_NAME"'"
        }
    }
}'
RESULT=$(rpc_call "Sys.SetConfig" "$SYS_CONFIG")
check_error "$RESULT" "System config" || true
echo "  ✓ Device name: $DEVICE_NAME"
echo ""

# -----------------------------------------------------------------------------
# UPLOAD AND ENABLE SCRIPT
# -----------------------------------------------------------------------------

echo "Step 7: Uploading safety script..."

SCRIPT_CONTENT=$(cat "$SCRIPT_FILE")

# Check if script slot exists
SCRIPT_STATUS=$(rpc_call "Script.GetStatus?id=$SCRIPT_ID" 2>/dev/null || echo '{"error":{}}')

if echo "$SCRIPT_STATUS" | grep -q '"error"'; then
    echo "  Creating script slot $SCRIPT_ID..."
    rpc_call "Script.Create" '{"name": "Secondary Safety Logic"}' > /dev/null
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

echo "Step 8: Final verification..."

echo "  Checking safety-critical configurations..."

# Verify switch 0 default state
SWITCH0=$(rpc_call "Switch.GetConfig?id=0")
INITIAL_STATE=$(echo "$SWITCH0" | python3 -c "import sys,json; print(json.load(sys.stdin).get('initial_state','?'))" 2>/dev/null || echo "?")
AUTO_OFF=$(echo "$SWITCH0" | python3 -c "import sys,json; print(json.load(sys.stdin).get('auto_off_delay','?'))" 2>/dev/null || echo "?")

if [ "$INITIAL_STATE" = "off" ]; then
    echo "  ✓ SAFETY CHECK: Relay 0 defaults to OFF"
else
    echo "  ⚠ SAFETY WARNING: Relay 0 initial_state is '$INITIAL_STATE' (should be 'off')"
fi

echo "  ✓ Auto-off backup timer: ${AUTO_OFF}s"

# Verify inputs
INPUT0=$(rpc_call "Input.GetConfig?id=0")
INPUT1=$(rpc_call "Input.GetConfig?id=1")
echo "  Input 0 (SW1): $(echo "$INPUT0" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"type={d.get('type','?')}\")" 2>/dev/null || echo "?")"
echo "  Input 1 (SW2): $(echo "$INPUT1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"type={d.get('type','?')}\")" 2>/dev/null || echo "?")"

echo ""
echo "=============================================="
echo "  DEPLOYMENT COMPLETE"
echo "=============================================="
echo ""
echo "Configured (SAFETY DEVICE):"
echo "  ✓ Input 0 (SW1): Secondary contactor feedback sense"
echo "  ✓ Input 1 (SW2): Primary contactor output sense"
echo "  ✓ Relay 0: Safety Contactor"
echo "    - Default OFF (fail-safe)"
echo "    - Auto-off at 61 minutes (firmware backup)"
echo "  ✓ Script: Secondary Safety Logic"
echo ""
echo "Safety features:"
echo "  1. Relay defaults to OFF on power loss"
echo "  2. Firmware auto-off at 61 minutes (backup)"
echo "  3. Script monitors SW2 to follow Primary"
echo "  4. Script has independent 1-hour timer"
echo "  5. Weld detection at 1hr 5min"
echo ""
echo "⚠️  IMPORTANT: Verify the secondary script is complete!"
echo "   The script should handle:"
echo "   - SW2 state change events"
echo "   - Safety relay mirroring"
echo "   - Contactor feedback verification"
echo "   - Weld detection timeout"
