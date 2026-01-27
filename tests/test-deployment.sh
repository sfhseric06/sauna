#!/bin/bash
# =============================================================================
# SAUNA DEPLOYMENT TEST SUITE
# =============================================================================
# Tests deployed configuration and scripts on Shelly devices.
#
# Tests include:
#   1. Connectivity check
#   2. Script syntax validation (local)
#   3. Script running verification
#   4. Configuration validation (compares actual vs expected)
#   5. Functional tests (toggle, state changes)
#   6. Safety feature verification
#
# Usage: ./test-deployment.sh [primary|secondary|all] [--functional]
# Example: ./test-deployment.sh all --functional
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# Source device manifest
source "$PROJECT_ROOT/hardware/devices.sh"

# Device hostnames (from hardware/devices.sh)
PRIMARY_HOST="$PRIMARY_HOSTNAME"
SECONDARY_HOST="$SECONDARY_HOSTNAME"

# Test options
TARGET="${1:-all}"
RUN_FUNCTIONAL="${2:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS
# -----------------------------------------------------------------------------

log_test() {
    echo -e "\n${YELLOW}TEST:${NC} $1"
}

log_pass() {
    echo -e "  ${GREEN}✓ PASS:${NC} $1"
    ((TESTS_PASSED++))
}

log_fail() {
    echo -e "  ${RED}✗ FAIL:${NC} $1"
    ((TESTS_FAILED++))
}

log_skip() {
    echo -e "  ${YELLOW}○ SKIP:${NC} $1"
    ((TESTS_SKIPPED++))
}

rpc_call() {
    local host="$1"
    local endpoint="$2"
    curl -s --connect-timeout 5 "http://$host/rpc/$endpoint" 2>/dev/null
}

rpc_post() {
    local host="$1"
    local endpoint="$2"
    local data="$3"
    curl -s --connect-timeout 5 -X POST "http://$host/rpc/$endpoint" \
        -H "Content-Type: application/json" \
        -d "$data" 2>/dev/null
}

# -----------------------------------------------------------------------------
# LOCAL SYNTAX VALIDATION
# -----------------------------------------------------------------------------

test_js_syntax() {
    local script_file="$1"
    local name="$2"
    
    log_test "JavaScript syntax validation: $name"
    
    if [ ! -f "$script_file" ]; then
        log_fail "Script file not found: $script_file"
        return
    fi
    
    # Use Node.js to check syntax
    if command -v node &> /dev/null; then
        if node --check "$script_file" 2>/dev/null; then
            log_pass "Syntax valid"
        else
            log_fail "Syntax errors detected"
            node --check "$script_file" 2>&1 | head -5
        fi
    else
        log_skip "Node.js not installed - cannot validate syntax"
    fi
}

# -----------------------------------------------------------------------------
# CONNECTIVITY TESTS
# -----------------------------------------------------------------------------

test_connectivity() {
    local host="$1"
    local name="$2"
    
    log_test "Connectivity: $name ($host)"
    
    local result=$(rpc_call "$host" "Shelly.GetDeviceInfo")
    
    if [ -n "$result" ] && ! echo "$result" | grep -q '"error"'; then
        local device_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','?'))" 2>/dev/null || echo "?")
        log_pass "Connected - Device ID: $device_id"
        return 0
    else
        log_fail "Cannot reach device"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# SCRIPT STATUS TESTS
# -----------------------------------------------------------------------------

test_script_running() {
    local host="$1"
    local name="$2"
    local script_id="${3:-1}"
    
    log_test "Script running: $name (slot $script_id)"
    
    local status=$(rpc_call "$host" "Script.GetStatus?id=$script_id")
    
    if [ -z "$status" ]; then
        log_fail "Could not get script status"
        return 1
    fi
    
    local running=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('running', False))" 2>/dev/null || echo "false")
    
    if [ "$running" = "True" ] || [ "$running" = "true" ]; then
        log_pass "Script is running"
        return 0
    else
        log_fail "Script is NOT running"
        echo "    Status: $status"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# CONFIGURATION VALIDATION TESTS
# -----------------------------------------------------------------------------

test_switch_config() {
    local host="$1"
    local name="$2"
    local switch_id="$3"
    local expected_initial="$4"
    local expected_name="$5"
    
    log_test "Switch $switch_id config: $name"
    
    local config=$(rpc_call "$host" "Switch.GetConfig?id=$switch_id")
    
    if [ -z "$config" ]; then
        log_fail "Could not get switch config"
        return 1
    fi
    
    local actual_initial=$(echo "$config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('initial_state','?'))" 2>/dev/null || echo "?")
    local actual_name=$(echo "$config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','?'))" 2>/dev/null || echo "?")
    
    local passed=true
    
    if [ "$actual_initial" = "$expected_initial" ]; then
        log_pass "initial_state = '$actual_initial' (expected: '$expected_initial')"
    else
        log_fail "initial_state = '$actual_initial' (expected: '$expected_initial')"
        passed=false
    fi
    
    if [ "$actual_name" = "$expected_name" ]; then
        log_pass "name = '$actual_name'"
    else
        log_fail "name = '$actual_name' (expected: '$expected_name')"
        passed=false
    fi
    
    $passed
}

test_input_config() {
    local host="$1"
    local name="$2"
    local input_id="$3"
    local expected_type="$4"
    
    log_test "Input $input_id config: $name"
    
    local config=$(rpc_call "$host" "Input.GetConfig?id=$input_id")
    
    if [ -z "$config" ]; then
        log_fail "Could not get input config"
        return 1
    fi
    
    local actual_type=$(echo "$config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type','?'))" 2>/dev/null || echo "?")
    
    if [ "$actual_type" = "$expected_type" ]; then
        log_pass "type = '$actual_type' (expected: '$expected_type')"
        return 0
    else
        log_fail "type = '$actual_type' (expected: '$expected_type')"
        return 1
    fi
}

test_virtual_button() {
    local host="$1"
    local name="$2"
    local button_id="$3"
    
    log_test "Virtual Button $button_id: $name"
    
    local status=$(rpc_call "$host" "Virtual.GetStatus?id=$button_id")
    
    if [ -z "$status" ] || echo "$status" | grep -q '"error"'; then
        log_fail "Virtual Button $button_id does not exist"
        return 1
    else
        log_pass "Virtual Button $button_id exists"
        return 0
    fi
}

test_mqtt_connection() {
    local host="$1"
    local name="$2"
    
    log_test "MQTT connection: $name"
    
    local status=$(rpc_call "$host" "MQTT.GetStatus")
    
    if [ -z "$status" ]; then
        log_fail "Could not get MQTT status"
        return 1
    fi
    
    local connected=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('connected', False))" 2>/dev/null || echo "false")
    
    if [ "$connected" = "True" ] || [ "$connected" = "true" ]; then
        log_pass "MQTT connected"
        return 0
    else
        log_skip "MQTT not connected (may not be configured)"
        return 0
    fi
}

# -----------------------------------------------------------------------------
# FUNCTIONAL TESTS (require --functional flag)
# -----------------------------------------------------------------------------

test_toggle_functional() {
    local host="$1"
    local name="$2"
    
    log_test "FUNCTIONAL: Toggle via Virtual Button ($name)"
    
    # Get initial state
    local initial_state=$(rpc_call "$host" "Switch.GetStatus?id=0" | python3 -c "import sys,json; print(json.load(sys.stdin).get('output', False))" 2>/dev/null || echo "?")
    echo "    Initial relay 0 state: $initial_state"
    
    # Trigger virtual button
    echo "    Triggering Virtual Button 200..."
    local trigger_result=$(rpc_call "$host" "Button.Trigger?id=200&event=single_push")
    
    # Wait for state change
    sleep 2
    
    # Get new state
    local new_state=$(rpc_call "$host" "Switch.GetStatus?id=0" | python3 -c "import sys,json; print(json.load(sys.stdin).get('output', False))" 2>/dev/null || echo "?")
    echo "    New relay 0 state: $new_state"
    
    if [ "$initial_state" != "$new_state" ]; then
        log_pass "State changed from $initial_state to $new_state"
        
        # Toggle back
        echo "    Toggling back..."
        rpc_call "$host" "Button.Trigger?id=200&event=single_push" > /dev/null
        sleep 2
        
        local final_state=$(rpc_call "$host" "Switch.GetStatus?id=0" | python3 -c "import sys,json; print(json.load(sys.stdin).get('output', False))" 2>/dev/null || echo "?")
        echo "    Final relay 0 state: $final_state"
        
        if [ "$final_state" = "$initial_state" ]; then
            log_pass "Successfully toggled back to original state"
        else
            log_fail "Did not return to original state"
        fi
        
        return 0
    else
        log_fail "State did not change after toggle"
        return 1
    fi
}

test_safety_default_off() {
    local host="$1"
    local name="$2"
    
    log_test "SAFETY: Relay defaults to OFF ($name)"
    
    local config=$(rpc_call "$host" "Switch.GetConfig?id=0")
    local initial_state=$(echo "$config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('initial_state','?'))" 2>/dev/null || echo "?")
    
    if [ "$initial_state" = "off" ]; then
        log_pass "Relay 0 initial_state is 'off' - SAFE"
        return 0
    else
        log_fail "SAFETY VIOLATION: Relay 0 initial_state is '$initial_state' - should be 'off'"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# TEST SUITES
# -----------------------------------------------------------------------------

run_primary_tests() {
    echo ""
    echo "=============================================="
    echo "  PRIMARY SHELLY TESTS"
    echo "=============================================="
    
    # Local syntax check
    test_js_syntax "$PROJECT_ROOT/devices/shelly-primary/script.js" "Primary script"
    
    # Connectivity
    if ! test_connectivity "$PRIMARY_HOST" "Primary Shelly"; then
        echo "  Skipping remaining tests - device unreachable"
        return 1
    fi
    
    # Script status
    test_script_running "$PRIMARY_HOST" "Primary Shelly" 1
    
    # Configuration validation
    test_input_config "$PRIMARY_HOST" "Primary - RC Button" 0 "button"
    test_switch_config "$PRIMARY_HOST" "Primary - Main Contactor" 0 "off" "Main Contactor"
    test_switch_config "$PRIMARY_HOST" "Primary - Indicator" 1 "off" "Indicator Light"
    test_virtual_button "$PRIMARY_HOST" "Primary - HA Button" 200
    test_mqtt_connection "$PRIMARY_HOST" "Primary Shelly"
    
    # Safety checks
    test_safety_default_off "$PRIMARY_HOST" "Primary Shelly"
    
    # Functional tests (if requested)
    if [ "$RUN_FUNCTIONAL" = "--functional" ]; then
        test_toggle_functional "$PRIMARY_HOST" "Primary Shelly"
    fi
}

run_secondary_tests() {
    echo ""
    echo "=============================================="
    echo "  SECONDARY SHELLY TESTS (SAFETY DEVICE)"
    echo "=============================================="
    
    # Local syntax check
    test_js_syntax "$PROJECT_ROOT/devices/shelly-secondary/script.js" "Secondary script"
    
    # Connectivity
    if ! test_connectivity "$SECONDARY_HOST" "Secondary Shelly"; then
        echo "  Skipping remaining tests - device unreachable"
        return 1
    fi
    
    # Script status
    test_script_running "$SECONDARY_HOST" "Secondary Shelly" 1
    
    # Configuration validation
    test_input_config "$SECONDARY_HOST" "Secondary - SW1 Sense" 0 "switch"
    test_input_config "$SECONDARY_HOST" "Secondary - SW2 Sense" 1 "switch"
    test_switch_config "$SECONDARY_HOST" "Secondary - Safety Contactor" 0 "off" "Safety Contactor"
    
    # CRITICAL: Safety checks
    test_safety_default_off "$SECONDARY_HOST" "Secondary Shelly (CRITICAL)"
    
    # Check auto-off backup
    log_test "SAFETY: Auto-off backup timer"
    local config=$(rpc_call "$SECONDARY_HOST" "Switch.GetConfig?id=0")
    local auto_off=$(echo "$config" | python3 -c "import sys,json; c=json.load(sys.stdin); print(c.get('auto_off_delay', 0) if c.get('auto_off', False) else 0)" 2>/dev/null || echo "0")
    
    if [ "$auto_off" -gt 3600 ]; then
        log_pass "Auto-off enabled at ${auto_off}s (> 1 hour)"
    else
        log_fail "Auto-off not configured or too short: ${auto_off}s"
    fi
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

echo "=============================================="
echo "  SAUNA DEPLOYMENT TEST SUITE"
echo "=============================================="
echo "Hardware Version: $HARDWARE_VERSION"
echo "Primary: $PRIMARY_HOST"
echo "Secondary: $SECONDARY_HOST"
echo "Target: $TARGET"
echo "Functional Tests: $([ "$RUN_FUNCTIONAL" = "--functional" ] && echo "YES" || echo "NO")"

case "$TARGET" in
    primary)
        run_primary_tests
        ;;
    secondary)
        run_secondary_tests
        ;;
    all)
        run_primary_tests
        run_secondary_tests
        ;;
    *)
        echo "Usage: $0 [primary|secondary|all] [--functional]"
        exit 1
        ;;
esac

# Summary
echo ""
echo "=============================================="
echo "  TEST SUMMARY"
echo "=============================================="
echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
echo -e "  ${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
