#!/bin/bash
# =============================================================================
# QUICK HEALTH CHECK
# =============================================================================
# Fast status check of all devices - ideal for cron jobs or quick monitoring.
# Returns exit code 0 if all devices healthy, 1 if any issues.
#
# Usage: ./check-health.sh [--json] [--quiet]
#        --json   Output as JSON
#        --quiet  Only output on errors
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../hardware/devices.sh"

OUTPUT_JSON=false
QUIET=false

for arg in "$@"; do
    case $arg in
        --json) OUTPUT_JSON=true ;;
        --quiet) QUIET=true ;;
    esac
done

# Colors (disabled for JSON output)
if [ "$OUTPUT_JSON" = true ]; then
    RED=''
    YELLOW=''
    GREEN=''
    NC=''
else
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    NC='\033[0m'
fi

ISSUES=0
RESULTS=()

check_device() {
    local name="$1"
    local host="$2"
    local api="${3:-gen2}"
    
    local status="offline"
    local rssi=""
    local uptime=""
    local issue=""
    
    # Try to get status
    if [ "$api" = "gen1" ]; then
        response=$(curl -s --connect-timeout 3 "http://$host/status" 2>/dev/null)
    else
        response=$(curl -s --connect-timeout 3 "http://$host/rpc/Shelly.GetStatus" 2>/dev/null)
    fi
    
    if [ -n "$response" ]; then
        status="online"
        
        # Parse RSSI and uptime
        result=$(python3 << PYTHON - "$response" "$api" 2>/dev/null || echo "||"
import sys, json
try:
    data = json.loads(sys.argv[1])
    api = sys.argv[2]
    
    if api == "gen1":
        rssi = data.get('wifi_sta', {}).get('rssi', '')
        uptime = data.get('uptime', 0)
    else:
        rssi = data.get('wifi', {}).get('rssi', '')
        uptime = data.get('sys', {}).get('uptime', 0)
    
    print(f"{rssi}|{uptime}")
except:
    print("|")
PYTHON
)
        rssi=$(echo "$result" | cut -d'|' -f1)
        uptime=$(echo "$result" | cut -d'|' -f2)
        
        # Check for issues
        if [ -n "$rssi" ] && [ "$rssi" -lt -75 ] 2>/dev/null; then
            issue="weak_wifi"
            ((ISSUES++))
        fi
        
        if [ -n "$uptime" ] && [ "$uptime" -lt 3600 ] 2>/dev/null; then
            issue="${issue:+$issue,}recent_reboot"
            ((ISSUES++))
        fi
    else
        ((ISSUES++))
        issue="unreachable"
    fi
    
    RESULTS+=("{\"name\":\"$name\",\"host\":\"$host\",\"status\":\"$status\",\"rssi\":\"$rssi\",\"uptime\":\"$uptime\",\"issue\":\"$issue\"}")
    
    # Console output (unless JSON mode)
    if [ "$OUTPUT_JSON" = false ] && [ "$QUIET" = false ]; then
        if [ "$status" = "online" ]; then
            if [ -n "$issue" ]; then
                printf "%-20s ${YELLOW}%-8s${NC} RSSI: %-4s  Issues: %s\n" "$name" "$status" "$rssi" "$issue"
            else
                printf "%-20s ${GREEN}%-8s${NC} RSSI: %-4s\n" "$name" "$status" "$rssi"
            fi
        else
            printf "%-20s ${RED}%-8s${NC}\n" "$name" "$status"
        fi
    fi
}

# Header
if [ "$OUTPUT_JSON" = false ] && [ "$QUIET" = false ]; then
    echo "=== Quick Health Check ($(date '+%H:%M:%S')) ==="
    echo ""
fi

# Check all devices
check_device "Primary" "$PRIMARY_HOSTNAME" "gen2"
check_device "Secondary" "$SECONDARY_HOSTNAME" "gen2"
check_device "LED Strip" "$LED_STRIP_HOSTNAME" "gen1"
check_device "HVAC" "$HVAC_HOSTNAME" "gen2"
check_device "Exterior" "$EXTERIOR_HOSTNAME" "gen2"

# Output
if [ "$OUTPUT_JSON" = true ]; then
    echo "{\"timestamp\":\"$(date -Iseconds)\",\"issues\":$ISSUES,\"devices\":[$(IFS=,; echo "${RESULTS[*]}")]}"
elif [ "$QUIET" = false ]; then
    echo ""
    if [ $ISSUES -eq 0 ]; then
        echo -e "${GREEN}✓ All devices healthy${NC}"
    else
        echo -e "${YELLOW}⚠ $ISSUES issue(s) detected${NC}"
    fi
fi

exit $ISSUES
