#!/bin/bash
# =============================================================================
# DUMP COMPLETE SHELLY CONFIGURATION
# =============================================================================
# Queries all RPC endpoints to show the complete current configuration.
# Useful for:
#   - Understanding what settings exist
#   - Documenting current state before changes
#   - Comparing actual vs expected configuration
#
# Usage: ./dump-shelly-config.sh [hostname] [output_file]
# Example: ./dump-shelly-config.sh shellypro2-0cb815fcaff4.local config-dump.json
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source device manifest
source "$SCRIPT_DIR/../hardware/devices.sh"

DEVICE_HOST="${1:-$PRIMARY_HOSTNAME}"
OUTPUT_FILE="${2:-}"

echo "=============================================="
echo "  SHELLY CONFIGURATION DUMP"
echo "=============================================="
echo "Device: $DEVICE_HOST"
echo ""

# Check connectivity
echo "Checking connectivity..."
if ! curl -s --connect-timeout 5 "http://$DEVICE_HOST/rpc/Shelly.GetStatus" > /dev/null 2>&1; then
    echo "ERROR: Cannot reach $DEVICE_HOST"
    exit 1
fi
echo "✓ Device reachable"
echo ""

# Function to query and display
query_rpc() {
    local endpoint="$1"
    local description="$2"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $description"
    echo "  Endpoint: $endpoint"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    result=$(curl -s "http://$DEVICE_HOST/rpc/$endpoint" 2>/dev/null)
    
    if command -v python3 &> /dev/null; then
        echo "$result" | python3 -m json.tool 2>/dev/null || echo "$result"
    else
        echo "$result"
    fi
    echo ""
}

# If output file specified, redirect everything
if [ -n "$OUTPUT_FILE" ]; then
    exec > >(tee "$OUTPUT_FILE")
fi

# =============================================================================
# DEVICE INFO
# =============================================================================

query_rpc "Shelly.GetDeviceInfo" "DEVICE INFO"

# =============================================================================
# FULL CONFIG (Everything)
# =============================================================================

query_rpc "Shelly.GetConfig" "FULL DEVICE CONFIGURATION"

# =============================================================================
# FULL STATUS
# =============================================================================

query_rpc "Shelly.GetStatus" "CURRENT STATUS"

# =============================================================================
# INDIVIDUAL COMPONENTS (for detail)
# =============================================================================

echo ""
echo "=============================================="
echo "  INDIVIDUAL COMPONENT DETAILS"
echo "=============================================="
echo ""

# Inputs
for id in 0 1; do
    query_rpc "Input.GetConfig?id=$id" "INPUT $id CONFIG"
    query_rpc "Input.GetStatus?id=$id" "INPUT $id STATUS"
done

# Switches
for id in 0 1; do
    query_rpc "Switch.GetConfig?id=$id" "SWITCH $id CONFIG"
    query_rpc "Switch.GetStatus?id=$id" "SWITCH $id STATUS"
done

# Scripts
echo "Checking scripts..."
for id in 1 2 3 4 5; do
    result=$(curl -s "http://$DEVICE_HOST/rpc/Script.GetConfig?id=$id" 2>/dev/null)
    if ! echo "$result" | grep -q '"error"'; then
        query_rpc "Script.GetConfig?id=$id" "SCRIPT $id CONFIG"
        query_rpc "Script.GetStatus?id=$id" "SCRIPT $id STATUS"
    fi
done

# MQTT
query_rpc "MQTT.GetConfig" "MQTT CONFIG"
query_rpc "MQTT.GetStatus" "MQTT STATUS"

# WiFi
query_rpc "WiFi.GetConfig" "WIFI CONFIG"
query_rpc "WiFi.GetStatus" "WIFI STATUS"

# Bluetooth/BTHome
query_rpc "BLE.GetConfig" "BLUETOOTH CONFIG"
query_rpc "BTHome.GetConfig" "BTHOME CONFIG" 2>/dev/null || true

# System
query_rpc "Sys.GetConfig" "SYSTEM CONFIG"
query_rpc "Sys.GetStatus" "SYSTEM STATUS"

# Virtual Components (if any)
echo "Checking virtual components..."
for id in 100 200 201; do
    result=$(curl -s "http://$DEVICE_HOST/rpc/Virtual.GetStatus?id=$id" 2>/dev/null)
    if ! echo "$result" | grep -q '"error"'; then
        query_rpc "Virtual.GetConfig?id=$id" "VIRTUAL $id CONFIG"
    fi
done

# =============================================================================
# ALL AVAILABLE METHODS
# =============================================================================

query_rpc "Shelly.ListMethods" "ALL AVAILABLE RPC METHODS"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "=============================================="
echo "  DUMP COMPLETE"
echo "=============================================="
if [ -n "$OUTPUT_FILE" ]; then
    echo "Output saved to: $OUTPUT_FILE"
fi
echo ""
echo "Key endpoints to understand:"
echo "  - Shelly.GetConfig: Full device config (all components)"
echo "  - Switch.SetConfig: Change relay settings"
echo "  - Input.SetConfig: Change input mode (button/switch)"
echo "  - Script.PutCode: Upload script code"
echo "  - MQTT.SetConfig: Configure MQTT broker"
echo "  - Virtual.Add: Create virtual components"
echo ""
echo "Shelly API Documentation:"
echo "  https://shelly-api-docs.shelly.cloud/gen2/"
