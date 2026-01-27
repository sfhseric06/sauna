#!/bin/bash
# =============================================================================
# DISCOVER AND VERIFY SAUNA DEVICES
# =============================================================================
# Scans for Shelly devices on the network and verifies they match the
# expected hardware configuration.
#
# Usage: ./discover-devices.sh [--scan]
#   --scan  Also scan network for unexpected Shelly devices
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../hardware/devices.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=============================================="
echo "  SAUNA DEVICE DISCOVERY"
echo "=============================================="
echo "Hardware Version: $HARDWARE_VERSION"
echo ""

# -----------------------------------------------------------------------------
# Check expected devices
# -----------------------------------------------------------------------------

check_device() {
    local name="$1"
    local hostname="$2"
    local expected_id="$3"
    local model="$4"
    
    echo -e "${CYAN}Checking:${NC} $name"
    echo "  Hostname: $hostname"
    echo "  Expected ID: $expected_id"
    
    # Try to reach device
    local response=$(curl -s --connect-timeout 3 "http://$hostname/rpc/Shelly.GetDeviceInfo" 2>/dev/null)
    
    if [ -z "$response" ]; then
        echo -e "  ${RED}✗ NOT REACHABLE${NC}"
        
        # Try to resolve hostname
        local ip=$(resolve_hostname "$hostname")
        if [ -n "$ip" ]; then
            echo "    Resolved to IP: $ip (but HTTP failed)"
        else
            echo "    Could not resolve hostname"
        fi
        echo ""
        return 1
    fi
    
    # Parse response
    local actual_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','?'))" 2>/dev/null || echo "?")
    local actual_model=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model','?'))" 2>/dev/null || echo "?")
    local actual_mac=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('mac','?'))" 2>/dev/null || echo "?")
    local fw_version=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('fw_id','?'))" 2>/dev/null || echo "?")
    local ip=$(resolve_hostname "$hostname")
    
    echo -e "  ${GREEN}✓ ONLINE${NC}"
    echo "    Device ID: $actual_id"
    echo "    Model: $actual_model"
    echo "    MAC: $actual_mac"
    echo "    IP: ${ip:-unknown}"
    echo "    Firmware: $fw_version"
    
    # Verify identity
    if [ "$actual_id" != "$expected_id" ]; then
        echo -e "    ${RED}⚠ WARNING: Device ID mismatch!${NC}"
        echo "      Expected: $expected_id"
        echo "      Got: $actual_id"
    fi
    
    echo ""
    return 0
}

echo "=== SAUNA CORE DEVICES ==="
echo ""

ONLINE=0
OFFLINE=0

if check_device "Primary Controller" "$PRIMARY_HOSTNAME" "$PRIMARY_DEVICE_ID" "$PRIMARY_MODEL"; then
    ((ONLINE++))
else
    ((OFFLINE++))
fi

if check_device "Secondary Controller (Safety)" "$SECONDARY_HOSTNAME" "$SECONDARY_DEVICE_ID" "$SECONDARY_MODEL"; then
    ((ONLINE++))
else
    ((OFFLINE++))
fi

if check_device "LED Strip Light" "$LED_STRIP_HOSTNAME" "$LED_STRIP_DEVICE_ID" "$LED_STRIP_MODEL"; then
    ((ONLINE++))
else
    ((OFFLINE++))
fi

echo ""
echo "=== AUXILIARY DEVICES ==="
echo ""

if check_device "HVAC Controller" "$HVAC_HOSTNAME" "$HVAC_DEVICE_ID" "$HVAC_MODEL"; then
    ((ONLINE++))
else
    ((OFFLINE++))
fi

if check_device "Exterior Light / Temp Sensor" "$EXTERIOR_HOSTNAME" "$EXTERIOR_DEVICE_ID" "$EXTERIOR_MODEL"; then
    ((ONLINE++))
else
    ((OFFLINE++))
fi

echo ""
echo "=== BLUETOOTH DEVICES ==="
echo ""
echo -e "${CYAN}BLU RC Button 4${NC}"
echo "  MAC: $BLU_RC4_MAC"
echo "  Model: $BLU_RC4_MODEL"
echo -e "  ${YELLOW}○ Bluetooth-only (pairs with Primary controller)${NC}"
echo ""

# -----------------------------------------------------------------------------
# Network scan for other Shelly devices (optional)
# -----------------------------------------------------------------------------

if [ "$1" = "--scan" ]; then
    echo "--- Network Scan ---"
    echo ""
    echo "Scanning for other Shelly devices on local network..."
    echo "(This may take a moment)"
    echo ""
    
    # Use dns-sd to discover Shelly devices (macOS)
    if command -v dns-sd &>/dev/null; then
        echo "Using mDNS discovery..."
        
        # Run dns-sd in background for 5 seconds
        timeout 5 dns-sd -B _http._tcp local 2>/dev/null | grep -i shelly | while read line; do
            echo "  Found: $line"
        done || true
        
        echo ""
        echo "Note: For comprehensive scanning, you can also try:"
        echo "  nmap -sn 192.168.1.0/24 | grep -i shelly"
        echo ""
    else
        echo "dns-sd not available. Try manual scan:"
        echo "  nmap -sn <your-subnet>/24"
        echo ""
    fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo "=============================================="
echo "  SUMMARY"
echo "=============================================="
echo -e "  ${GREEN}Online:${NC}  $ONLINE devices"
echo -e "  ${RED}Offline:${NC} $OFFLINE devices"
echo ""

if [ $OFFLINE -gt 0 ]; then
    echo -e "${YELLOW}Some devices are offline. Check:${NC}"
    echo "  1. Device is powered on"
    echo "  2. Device is connected to WiFi"
    echo "  3. Your computer is on the same network"
    echo "  4. mDNS/Bonjour is working (try: ping shellypro2-xxx.local)"
    echo ""
    exit 1
fi

echo -e "${GREEN}All expected devices are online!${NC}"
