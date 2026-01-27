#!/bin/bash
# =============================================================================
# NETWORK DEBUGGING TOOLS
# =============================================================================
# Advanced network diagnostics for troubleshooting device connectivity.
#
# Usage: ./network-debug.sh <hostname>
# Example: ./network-debug.sh shellypro2-0cb815fcaff4.local
# =============================================================================

HOST="${1:-}"

if [ -z "$HOST" ]; then
    echo "Usage: $0 <hostname>"
    exit 1
fi

# Colors
CYAN='\033[0;36m'
NC='\033[0m'

echo "=============================================="
echo "  NETWORK DEBUGGING"
echo "=============================================="
echo "Target: $HOST"
echo ""

# -----------------------------------------------------------------------------
# 1. mDNS/Bonjour Resolution
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== mDNS Resolution ===${NC}"

echo "1. Using ping (basic resolution):"
if ping -c 1 -W 2 "$HOST" >/dev/null 2>&1; then
    IP=$(ping -c 1 -W 2 "$HOST" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "   ✓ Resolved: $IP"
else
    echo "   ✗ Failed to resolve via ping"
fi

echo ""
echo "2. Using dns-sd (macOS mDNS):"
if command -v dns-sd &>/dev/null; then
    echo "   Running dns-sd lookup (5 second timeout)..."
    timeout 5 dns-sd -G v4 "$HOST" 2>/dev/null | head -10 || echo "   (timeout or no result)"
else
    echo "   dns-sd not available (not macOS?)"
fi

echo ""
echo "3. Using avahi-resolve (Linux mDNS):"
if command -v avahi-resolve &>/dev/null; then
    avahi-resolve -n "$HOST" 2>/dev/null || echo "   (failed or not available)"
else
    echo "   avahi-resolve not available"
fi

echo ""

# -----------------------------------------------------------------------------
# 2. ARP Table
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== ARP Table (recent network contacts) ===${NC}"
arp -a 2>/dev/null | grep -i shelly || echo "No Shelly devices in ARP table"
echo ""

# -----------------------------------------------------------------------------
# 3. Route to device
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== Route Tracing ===${NC}"
if [ -n "$IP" ]; then
    echo "Tracing route to $IP..."
    traceroute -m 5 -w 2 "$IP" 2>/dev/null || echo "(traceroute failed)"
else
    echo "Cannot trace - IP not resolved"
fi
echo ""

# -----------------------------------------------------------------------------
# 4. Port scan
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== Port Scan ===${NC}"
if [ -n "$IP" ]; then
    echo "Checking common Shelly ports on $IP..."
    
    check_port() {
        local port=$1
        local desc=$2
        if nc -z -w 2 "$IP" "$port" 2>/dev/null; then
            echo "   ✓ Port $port ($desc) - OPEN"
        else
            echo "   ✗ Port $port ($desc) - closed/filtered"
        fi
    }
    
    check_port 80 "HTTP"
    check_port 443 "HTTPS"
    check_port 1883 "MQTT"
    check_port 8883 "MQTT/TLS"
    check_port 5683 "CoAP"
else
    echo "Cannot scan - IP not resolved"
fi
echo ""

# -----------------------------------------------------------------------------
# 5. HTTP Debug
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== HTTP Debug ===${NC}"
if [ -n "$IP" ]; then
    echo "Testing HTTP connection with verbose output..."
    curl -v --connect-timeout 5 "http://$IP/rpc/Shelly.GetDeviceInfo" 2>&1 | head -30
else
    echo "Cannot test HTTP - IP not resolved"
fi
echo ""

# -----------------------------------------------------------------------------
# 6. Continuous ping
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== Continuous Ping Test (10 pings) ===${NC}"
if [ -n "$IP" ]; then
    ping -c 10 "$IP" 2>/dev/null || echo "Ping failed"
else
    echo "Cannot ping - IP not resolved"
fi
echo ""

# -----------------------------------------------------------------------------
# 7. WiFi channel info (if device responds)
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== WiFi Configuration (from device) ===${NC}"
if [ -n "$IP" ]; then
    wifi_config=$(curl -s --connect-timeout 5 "http://$IP/rpc/WiFi.GetStatus" 2>/dev/null)
    if [ -n "$wifi_config" ]; then
        echo "$wifi_config" | python3 -m json.tool 2>/dev/null || echo "$wifi_config"
    else
        echo "Could not fetch WiFi config from device"
    fi
fi
echo ""

echo "=============================================="
echo "  DEBUGGING COMPLETE"
echo "=============================================="
echo ""
echo "If device is unreachable, try:"
echo "  1. Check if device is powered on"
echo "  2. Check router's DHCP leases for the MAC address"
echo "  3. Try accessing via IP directly if known"
echo "  4. Reboot the device (power cycle)"
echo "  5. Check for IP conflicts in your network"
