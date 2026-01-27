#!/bin/bash
# =============================================================================
# COMPREHENSIVE DEVICE DIAGNOSTICS
# =============================================================================
# Runs full diagnostics on a single Shelly device.
#
# Usage: ./diagnose-device.sh <hostname> [gen1|gen2]
# Example: ./diagnose-device.sh shellypro2-0cb815fcaff4.local
# =============================================================================

set -e

HOST="${1:-}"
API="${2:-gen2}"

if [ -z "$HOST" ]; then
    echo "Usage: $0 <hostname> [gen1|gen2]"
    echo "Example: $0 shellypro2-0cb815fcaff4.local"
    exit 1
fi

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=============================================="
echo "  COMPREHENSIVE DEVICE DIAGNOSTICS"
echo "=============================================="
echo "Host: $HOST"
echo "API: $API"
echo "Time: $(date)"
echo "=============================================="
echo ""

# -----------------------------------------------------------------------------
# 1. NETWORK DIAGNOSTICS
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== NETWORK DIAGNOSTICS ===${NC}"
echo ""

echo "1. DNS/mDNS Resolution:"
if ping -c 1 -W 2 "$HOST" >/dev/null 2>&1; then
    IP=$(ping -c 1 -W 2 "$HOST" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo -e "   ${GREEN}✓${NC} Resolved to: $IP"
else
    echo -e "   ${RED}✗${NC} FAILED - Cannot resolve hostname"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check if device is powered on"
    echo "  - Check if device is connected to WiFi"
    echo "  - Try: dns-sd -G v4 $HOST"
    echo "  - Check router's DHCP leases"
    exit 1
fi

echo ""
echo "2. Ping Test (latency):"
ping_result=$(ping -c 5 -W 2 "$HOST" 2>/dev/null | tail -1)
if [ -n "$ping_result" ]; then
    echo "   $ping_result"
else
    echo -e "   ${RED}✗${NC} Ping failed"
fi

echo ""
echo "3. HTTP Connectivity:"
start_time=$(python3 -c "import time; print(int(time.time()*1000))")
if [ "$API" = "gen1" ]; then
    http_response=$(curl -s --connect-timeout 5 -w "%{http_code}" "http://$HOST/status" -o /dev/null 2>/dev/null)
else
    http_response=$(curl -s --connect-timeout 5 -w "%{http_code}" "http://$HOST/rpc/Shelly.GetDeviceInfo" -o /dev/null 2>/dev/null)
fi
end_time=$(python3 -c "import time; print(int(time.time()*1000))")
http_time=$((end_time - start_time))

if [ "$http_response" = "200" ]; then
    echo -e "   ${GREEN}✓${NC} HTTP OK (${http_time}ms)"
else
    echo -e "   ${RED}✗${NC} HTTP failed (code: $http_response)"
    exit 1
fi

echo ""

# -----------------------------------------------------------------------------
# 2. DEVICE INFO
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== DEVICE INFORMATION ===${NC}"
echo ""

if [ "$API" = "gen1" ]; then
    settings=$(curl -s --connect-timeout 5 "http://$HOST/settings" 2>/dev/null)
    status=$(curl -s --connect-timeout 5 "http://$HOST/status" 2>/dev/null)
    
    python3 << PYTHON - "$settings" "$status"
import sys, json

settings = json.loads(sys.argv[1])
status = json.loads(sys.argv[2])

print(f"Device Type: {settings.get('device', {}).get('type', 'N/A')}")
print(f"Device ID: {settings.get('device', {}).get('hostname', 'N/A')}")
print(f"MAC: {status.get('mac', 'N/A')}")
print(f"Firmware: {settings.get('fw', 'N/A')}")
print(f"Name: {settings.get('name', 'N/A')}")
PYTHON
else
    info=$(curl -s --connect-timeout 5 "http://$HOST/rpc/Shelly.GetDeviceInfo" 2>/dev/null)
    
    python3 << PYTHON - "$info"
import sys, json

info = json.loads(sys.argv[1])

print(f"Device Type: {info.get('app', 'N/A')}")
print(f"Device ID: {info.get('id', 'N/A')}")
print(f"Model: {info.get('model', 'N/A')}")
print(f"MAC: {info.get('mac', 'N/A')}")
print(f"Firmware: {info.get('fw_id', 'N/A')}")
print(f"Gen: {info.get('gen', 'N/A')}")
PYTHON
fi

echo ""

# -----------------------------------------------------------------------------
# 3. WIFI DIAGNOSTICS
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== WIFI DIAGNOSTICS ===${NC}"
echo ""

if [ "$API" = "gen1" ]; then
    status=$(curl -s --connect-timeout 5 "http://$HOST/status" 2>/dev/null)
    
    python3 << PYTHON - "$status"
import sys, json

status = json.loads(sys.argv[1])
wifi = status.get('wifi_sta', {})

rssi = wifi.get('rssi', 'N/A')
ssid = wifi.get('ssid', 'N/A')
ip = wifi.get('ip', 'N/A')
connected = wifi.get('connected', False)

print(f"SSID: {ssid}")
print(f"Connected: {connected}")
print(f"IP Address: {ip}")
print(f"Signal Strength (RSSI): {rssi} dBm")

if isinstance(rssi, int):
    if rssi >= -50:
        quality = "Excellent"
        status_color = "✓"
    elif rssi >= -60:
        quality = "Good"
        status_color = "✓"
    elif rssi >= -70:
        quality = "Fair"
        status_color = "⚠"
    elif rssi >= -80:
        quality = "Weak - May cause disconnects!"
        status_color = "✗"
    else:
        quality = "Very Weak - WILL cause disconnects!"
        status_color = "✗"
    print(f"Signal Quality: {status_color} {quality}")
PYTHON
else
    status=$(curl -s --connect-timeout 5 "http://$HOST/rpc/Shelly.GetStatus" 2>/dev/null)
    config=$(curl -s --connect-timeout 5 "http://$HOST/rpc/Shelly.GetConfig" 2>/dev/null)
    
    python3 << PYTHON - "$status" "$config"
import sys, json

status = json.loads(sys.argv[1])
config = json.loads(sys.argv[2])

wifi_status = status.get('wifi', {})
wifi_config = config.get('wifi', {}).get('sta', {})

rssi = wifi_status.get('rssi', 'N/A')
ssid = wifi_status.get('ssid', 'N/A')
ip = wifi_status.get('sta_ip', 'N/A')
status_str = wifi_status.get('status', 'N/A')

print(f"SSID: {ssid}")
print(f"Status: {status_str}")
print(f"IP Address: {ip}")
print(f"Signal Strength (RSSI): {rssi} dBm")

if isinstance(rssi, int):
    if rssi >= -50:
        quality = "Excellent"
        status_icon = "✓"
    elif rssi >= -60:
        quality = "Good"
        status_icon = "✓"
    elif rssi >= -70:
        quality = "Fair"
        status_icon = "⚠"
    elif rssi >= -80:
        quality = "Weak - May cause disconnects!"
        status_icon = "✗"
    else:
        quality = "Very Weak - WILL cause disconnects!"
        status_icon = "✗"
    print(f"Signal Quality: {status_icon} {quality}")

# Check for static IP
if wifi_config.get('ipv4mode') == 'static':
    print(f"IP Mode: Static")
else:
    print(f"IP Mode: DHCP (consider static for stability)")
PYTHON
fi

echo ""

# -----------------------------------------------------------------------------
# 4. SYSTEM HEALTH
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== SYSTEM HEALTH ===${NC}"
echo ""

if [ "$API" = "gen1" ]; then
    status=$(curl -s --connect-timeout 5 "http://$HOST/status" 2>/dev/null)
    
    python3 << PYTHON - "$status"
import sys, json

status = json.loads(sys.argv[1])

uptime = status.get('uptime', 0)
hours = uptime // 3600
minutes = (uptime % 3600) // 60
days = hours // 24
hours = hours % 24

print(f"Uptime: {days}d {hours}h {minutes}m ({uptime} seconds)")

if uptime < 3600:
    print("⚠️  WARNING: Device rebooted in the last hour!")
elif uptime < 86400:
    print("ℹ️  Device rebooted in the last 24 hours")

ram_total = status.get('ram_total', 0)
ram_free = status.get('ram_free', 0)
if ram_total > 0:
    ram_pct = ((ram_total - ram_free) / ram_total) * 100
    print(f"RAM: {ram_free} free of {ram_total} ({ram_pct:.1f}% used)")

fs_size = status.get('fs_size', 0)
fs_free = status.get('fs_free', 0)
if fs_size > 0:
    fs_pct = ((fs_size - fs_free) / fs_size) * 100
    print(f"Filesystem: {fs_free} free of {fs_size} ({fs_pct:.1f}% used)")

# Temperature
temp = status.get('temperature', status.get('tmp', {}).get('tC'))
if temp:
    print(f"Device Temperature: {temp}°C", end='')
    if temp > 60:
        print(" ⚠️  HIGH!")
    elif temp > 50:
        print(" (warm)")
    else:
        print(" (normal)")
PYTHON
else
    status=$(curl -s --connect-timeout 5 "http://$HOST/rpc/Shelly.GetStatus" 2>/dev/null)
    
    python3 << PYTHON - "$status"
import sys, json

status = json.loads(sys.argv[1])
sys_status = status.get('sys', {})

uptime = sys_status.get('uptime', 0)
hours = uptime // 3600
minutes = (uptime % 3600) // 60
days = hours // 24
hours = hours % 24

print(f"Uptime: {days}d {hours}h {minutes}m ({uptime} seconds)")

if uptime < 3600:
    print("⚠️  WARNING: Device rebooted in the last hour!")
elif uptime < 86400:
    print("ℹ️  Device rebooted in the last 24 hours")

ram_free = sys_status.get('ram_free', 'N/A')
ram_size = sys_status.get('ram_size', 0)
print(f"RAM Free: {ram_free} bytes")

fs_free = sys_status.get('fs_free', 'N/A')
fs_size = sys_status.get('fs_size', 0)
print(f"Filesystem Free: {fs_free} bytes")

# Check for temperature in switch components
for key, value in status.items():
    if isinstance(value, dict) and 'temperature' in value:
        temp = value['temperature'].get('tC')
        if temp is not None:
            print(f"Device Temperature: {temp}°C", end='')
            if temp > 60:
                print(" ⚠️  HIGH!")
            elif temp > 50:
                print(" (warm)")
            else:
                print(" (normal)")
            break

# Available updates
if sys_status.get('available_updates'):
    print(f"⚠️  Firmware update available!")
PYTHON
fi

echo ""

# -----------------------------------------------------------------------------
# 5. COMPONENT STATUS
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== COMPONENT STATUS ===${NC}"
echo ""

if [ "$API" = "gen2" ]; then
    status=$(curl -s --connect-timeout 5 "http://$HOST/rpc/Shelly.GetStatus" 2>/dev/null)
    
    python3 << PYTHON - "$status"
import sys, json

status = json.loads(sys.argv[1])

# Switches
for key, value in status.items():
    if key.startswith('switch:'):
        idx = key.split(':')[1]
        output = value.get('output', 'N/A')
        power = value.get('apower', 'N/A')
        voltage = value.get('voltage', 'N/A')
        temp = value.get('temperature', {}).get('tC', 'N/A')
        print(f"Switch {idx}: output={output}, power={power}W, voltage={voltage}V, temp={temp}°C")

# Inputs
for key, value in status.items():
    if key.startswith('input:'):
        idx = key.split(':')[1]
        state = value.get('state', 'N/A')
        print(f"Input {idx}: state={state}")

# Scripts
for key, value in status.items():
    if key.startswith('script:'):
        idx = key.split(':')[1]
        running = value.get('running', False)
        errors = value.get('errors', [])
        print(f"Script {idx}: running={running}", end='')
        if errors:
            print(f" ⚠️  ERRORS: {errors}")
        else:
            print()

# MQTT
mqtt = status.get('mqtt', {})
if mqtt:
    connected = mqtt.get('connected', False)
    print(f"MQTT: connected={connected}")

# Cloud
cloud = status.get('cloud', {})
if cloud:
    connected = cloud.get('connected', False)
    print(f"Cloud: connected={connected}")
PYTHON
fi

echo ""

# -----------------------------------------------------------------------------
# 6. RECOMMENDATIONS
# -----------------------------------------------------------------------------
echo -e "${CYAN}=== RECOMMENDATIONS ===${NC}"
echo ""

if [ "$API" = "gen2" ]; then
    status=$(curl -s --connect-timeout 5 "http://$HOST/rpc/Shelly.GetStatus" 2>/dev/null)
    
    python3 << PYTHON - "$status"
import sys, json

status = json.loads(sys.argv[1])

recommendations = []

# Check RSSI
wifi = status.get('wifi', {})
rssi = wifi.get('rssi', 0)
if rssi < -70:
    recommendations.append(f"⚠️  WiFi signal is weak ({rssi} dBm). Consider:")
    recommendations.append("   - Moving router closer or adding a repeater")
    recommendations.append("   - Using the ethernet port (Shelly Pro 2 only)")
    recommendations.append("   - Checking for 2.4GHz band congestion")

# Check uptime
uptime = status.get('sys', {}).get('uptime', 0)
if uptime < 86400:
    recommendations.append(f"ℹ️  Device rebooted recently. Monitor for stability.")

# Check for script errors
for key, value in status.items():
    if key.startswith('script:') and value.get('errors'):
        recommendations.append(f"⚠️  Script has errors - check logs")

# Check temperature
for key, value in status.items():
    if isinstance(value, dict) and 'temperature' in value:
        temp = value.get('temperature', {}).get('tC', 0)
        if temp and temp > 50:
            recommendations.append(f"⚠️  Device running warm ({temp}°C). Check ventilation.")

if not recommendations:
    print("✓ No issues detected. Device appears healthy.")
else:
    for rec in recommendations:
        print(rec)
PYTHON
fi

echo ""
echo "=============================================="
echo "  DIAGNOSTICS COMPLETE"
echo "=============================================="
