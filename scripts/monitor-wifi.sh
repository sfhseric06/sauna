#!/bin/bash
# =============================================================================
# WIFI SIGNAL STRENGTH MONITOR
# =============================================================================
# Continuously monitors WiFi signal strength (RSSI) of all Shelly devices.
# Useful for identifying intermittent connectivity issues.
#
# Usage: ./monitor-wifi.sh [interval_seconds] [duration_minutes]
# Example: ./monitor-wifi.sh 30 60    # Check every 30s for 60 minutes
#          ./monitor-wifi.sh          # Default: every 60s, indefinitely
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../hardware/devices.sh"

INTERVAL="${1:-60}"
DURATION="${2:-0}"  # 0 = indefinite
LOG_FILE="${3:-$SCRIPT_DIR/../logs/wifi-monitor-$(date +%Y%m%d-%H%M%S).csv}"

# Create logs directory
mkdir -p "$(dirname "$LOG_FILE")"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=============================================="
echo "  WIFI SIGNAL STRENGTH MONITOR"
echo "=============================================="
echo "Interval: ${INTERVAL}s"
echo "Duration: $([ "$DURATION" -eq 0 ] && echo "Indefinite (Ctrl+C to stop)" || echo "${DURATION} minutes")"
echo "Log file: $LOG_FILE"
echo ""
echo "RSSI Guide:"
echo "  > -50 dBm  : Excellent (green)"
echo "  -50 to -60 : Good (green)"
echo "  -60 to -70 : Fair (yellow)"
echo "  -70 to -80 : Weak (red)"
echo "  < -80 dBm  : Very Weak (red, blinking)"
echo ""
echo "Press Ctrl+C to stop monitoring"
echo "=============================================="
echo ""

# CSV header
echo "timestamp,device,hostname,ip,rssi_dbm,quality,uptime_seconds,response_time_ms" > "$LOG_FILE"

get_rssi_color() {
    local rssi=$1
    if [ "$rssi" -ge -50 ]; then
        echo -e "${GREEN}"
    elif [ "$rssi" -ge -60 ]; then
        echo -e "${GREEN}"
    elif [ "$rssi" -ge -70 ]; then
        echo -e "${YELLOW}"
    elif [ "$rssi" -ge -80 ]; then
        echo -e "${RED}"
    else
        echo -e "${RED}"
    fi
}

get_rssi_quality() {
    local rssi=$1
    if [ "$rssi" -ge -50 ]; then
        echo "Excellent"
    elif [ "$rssi" -ge -60 ]; then
        echo "Good"
    elif [ "$rssi" -ge -70 ]; then
        echo "Fair"
    elif [ "$rssi" -ge -80 ]; then
        echo "Weak"
    else
        echo "VeryWeak"
    fi
}

check_device() {
    local name="$1"
    local host="$2"
    local api="${3:-gen2}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local start_time=$(python3 -c "import time; print(int(time.time()*1000))")
    
    if [ "$api" = "gen1" ]; then
        local response=$(curl -s --connect-timeout 5 "http://$host/status" 2>/dev/null)
    else
        local response=$(curl -s --connect-timeout 5 "http://$host/rpc/Shelly.GetStatus" 2>/dev/null)
    fi
    
    local end_time=$(python3 -c "import time; print(int(time.time()*1000))")
    local response_time=$((end_time - start_time))
    
    if [ -z "$response" ]; then
        printf "%-20s %-40s %s\n" "$name" "$host" "${RED}OFFLINE${NC}"
        echo "$timestamp,$name,$host,,,,,$response_time" >> "$LOG_FILE"
        return 1
    fi
    
    # Parse response
    local result=$(python3 << PYTHON - "$response" "$api"
import sys, json
try:
    data = json.loads(sys.argv[1])
    api = sys.argv[2]
    
    if api == "gen1":
        wifi = data.get('wifi_sta', {})
        rssi = wifi.get('rssi', 'N/A')
        ip = wifi.get('ip', 'N/A')
        uptime = data.get('uptime', 0)
    else:
        wifi = data.get('wifi', {})
        rssi = wifi.get('rssi', 'N/A')
        ip = wifi.get('sta_ip', 'N/A')
        uptime = data.get('sys', {}).get('uptime', 0)
    
    print(f"{rssi}|{ip}|{uptime}")
except:
    print("error|error|0")
PYTHON
)
    
    local rssi=$(echo "$result" | cut -d'|' -f1)
    local ip=$(echo "$result" | cut -d'|' -f2)
    local uptime=$(echo "$result" | cut -d'|' -f3)
    
    if [ "$rssi" = "error" ]; then
        printf "%-20s %-40s %s\n" "$name" "$host" "${YELLOW}PARSE ERROR${NC}"
        return 1
    fi
    
    local quality=$(get_rssi_quality "$rssi")
    local color=$(get_rssi_color "$rssi")
    
    printf "%-20s %-18s %s%-4d dBm %-10s${NC} %4dms\n" \
        "$name" "$ip" "$color" "$rssi" "($quality)" "$response_time"
    
    echo "$timestamp,$name,$host,$ip,$rssi,$quality,$uptime,$response_time" >> "$LOG_FILE"
}

# Calculate end time if duration specified
if [ "$DURATION" -gt 0 ]; then
    END_TIME=$(($(date +%s) + DURATION * 60))
fi

ITERATION=0
while true; do
    ITERATION=$((ITERATION + 1))
    
    echo -e "${CYAN}--- $(date '+%Y-%m-%d %H:%M:%S') (check #$ITERATION) ---${NC}"
    
    check_device "Primary" "$PRIMARY_HOSTNAME" "gen2"
    check_device "Secondary" "$SECONDARY_HOSTNAME" "gen2"
    check_device "LED Strip" "$LED_STRIP_HOSTNAME" "gen1"
    check_device "HVAC" "$HVAC_HOSTNAME" "gen2"
    check_device "Exterior" "$EXTERIOR_HOSTNAME" "gen2"
    
    echo ""
    
    # Check if duration exceeded
    if [ "$DURATION" -gt 0 ] && [ "$(date +%s)" -ge "$END_TIME" ]; then
        echo "Duration reached. Stopping."
        break
    fi
    
    sleep "$INTERVAL"
done

echo ""
echo "Log saved to: $LOG_FILE"
echo "To analyze: cat $LOG_FILE | column -t -s','"
