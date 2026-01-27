#!/bin/bash
# =============================================================================
# DIAGNOSE ALL DEVICES
# =============================================================================
# Runs comprehensive diagnostics on all configured Shelly devices.
#
# Usage: ./diagnose-all.sh [--save]
#        --save  Save output to logs directory
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../hardware/devices.sh"

SAVE_LOG=false
if [ "$1" = "--save" ]; then
    SAVE_LOG=true
    LOG_FILE="$SCRIPT_DIR/../logs/diagnostics-$(date +%Y%m%d-%H%M%S).txt"
    mkdir -p "$(dirname "$LOG_FILE")"
fi

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

run_diagnostics() {
    echo "=============================================="
    echo "  FULL SYSTEM DIAGNOSTICS"
    echo "=============================================="
    echo "Hardware Version: $HARDWARE_VERSION"
    echo "Timestamp: $(date)"
    echo ""
    
    echo ""
    echo -e "${CYAN}######################################################${NC}"
    echo -e "${CYAN}# PRIMARY CONTROLLER                                 #${NC}"
    echo -e "${CYAN}######################################################${NC}"
    "$SCRIPT_DIR/diagnose-device.sh" "$PRIMARY_HOSTNAME" "gen2" 2>&1 || true
    
    echo ""
    echo -e "${CYAN}######################################################${NC}"
    echo -e "${CYAN}# SECONDARY CONTROLLER (SAFETY)                      #${NC}"
    echo -e "${CYAN}######################################################${NC}"
    "$SCRIPT_DIR/diagnose-device.sh" "$SECONDARY_HOSTNAME" "gen2" 2>&1 || true
    
    echo ""
    echo -e "${CYAN}######################################################${NC}"
    echo -e "${CYAN}# LED STRIP                                          #${NC}"
    echo -e "${CYAN}######################################################${NC}"
    "$SCRIPT_DIR/diagnose-device.sh" "$LED_STRIP_HOSTNAME" "gen1" 2>&1 || true
    
    echo ""
    echo -e "${CYAN}######################################################${NC}"
    echo -e "${CYAN}# HVAC CONTROLLER                                    #${NC}"
    echo -e "${CYAN}######################################################${NC}"
    "$SCRIPT_DIR/diagnose-device.sh" "$HVAC_HOSTNAME" "gen2" 2>&1 || true
    
    echo ""
    echo -e "${CYAN}######################################################${NC}"
    echo -e "${CYAN}# EXTERIOR / TEMPERATURE SENSOR                      #${NC}"
    echo -e "${CYAN}######################################################${NC}"
    "$SCRIPT_DIR/diagnose-device.sh" "$EXTERIOR_HOSTNAME" "gen2" 2>&1 || true
    
    echo ""
    echo "=============================================="
    echo "  DIAGNOSTICS COMPLETE"
    echo "=============================================="
}

if [ "$SAVE_LOG" = true ]; then
    echo "Saving diagnostics to: $LOG_FILE"
    run_diagnostics | tee "$LOG_FILE"
    echo ""
    echo "Log saved to: $LOG_FILE"
else
    run_diagnostics
fi
