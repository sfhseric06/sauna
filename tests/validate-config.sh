#!/bin/bash
# =============================================================================
# VALIDATE DEPLOYED CONFIG AGAINST HARDWARE VERSION
# =============================================================================
# Compares the actual configuration on Shelly devices against the expected
# configuration defined in the hardware version file.
#
# Usage: ./validate-config.sh [hostname]
# Example: ./validate-config.sh shellypro2-0cb815fcaff4.local
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# Source device manifest
source "$PROJECT_ROOT/hardware/devices.sh"

DEVICE_HOST="${1:-$PRIMARY_HOSTNAME}"
OUTPUT_DIR="$PROJECT_ROOT/.validation"

echo "=============================================="
echo "  CONFIGURATION VALIDATION"
echo "=============================================="
echo "Device: $DEVICE_HOST"
echo ""

# Check connectivity
echo "Checking connectivity..."
DEVICE_INFO=$(curl -s --connect-timeout 5 "http://$DEVICE_HOST/rpc/Shelly.GetDeviceInfo" 2>/dev/null)

if [ -z "$DEVICE_INFO" ]; then
    echo "ERROR: Cannot reach device"
    exit 1
fi

DEVICE_ID=$(echo "$DEVICE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','unknown'))" 2>/dev/null || echo "unknown")
echo "Connected to: $DEVICE_ID"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Dump current config
echo "Fetching current configuration..."
CURRENT_CONFIG="$OUTPUT_DIR/${DEVICE_ID}-current.json"

curl -s "http://$DEVICE_HOST/rpc/Shelly.GetConfig" | python3 -m json.tool > "$CURRENT_CONFIG" 2>/dev/null

echo "Current config saved to: $CURRENT_CONFIG"
echo ""

# Compare with expected (from device config.json)
if echo "$DEVICE_ID" | grep -q "fcaff4"; then
    EXPECTED_CONFIG="$PROJECT_ROOT/devices/shelly-primary/config.json"
    DEVICE_TYPE="Primary"
elif echo "$DEVICE_ID" | grep -q "96dc"; then
    EXPECTED_CONFIG="$PROJECT_ROOT/devices/shelly-secondary/config.json"
    DEVICE_TYPE="Secondary"
else
    echo "Unknown device - cannot determine expected config"
    exit 1
fi

echo "Device Type: $DEVICE_TYPE"
echo "Expected Config: $EXPECTED_CONFIG"
echo ""

# Parse and compare key settings
echo "=============================================="
echo "  CONFIGURATION COMPARISON"
echo "=============================================="

python3 << EOF
import json
import sys

# Load current config
with open("$CURRENT_CONFIG") as f:
    current = json.load(f)

# Load expected config  
with open("$EXPECTED_CONFIG") as f:
    expected = json.load(f)

def check(name, actual, expected_val, critical=False):
    prefix = "CRITICAL" if critical else "CHECK"
    if actual == expected_val:
        print(f"  ✓ {name}: {actual}")
        return True
    else:
        print(f"  ✗ {name}: {actual} (expected: {expected_val})")
        return False

errors = 0

print("\n--- Switches ---")
for switch_key, switch_cfg in expected.get("switches", {}).items():
    switch_id = int(switch_key.split(":")[1])
    if f"switch:{switch_id}" in current:
        actual_switch = current[f"switch:{switch_id}"]
        
        # Check initial_state (CRITICAL for safety)
        if not check(
            f"switch:{switch_id} initial_state",
            actual_switch.get("initial_state"),
            switch_cfg.get("initial_state"),
            critical=switch_cfg.get("safety_critical", False)
        ):
            errors += 1
            
        # Check name
        if not check(
            f"switch:{switch_id} name",
            actual_switch.get("name"),
            switch_cfg.get("name")
        ):
            errors += 1

print("\n--- Inputs ---")
for input_key, input_cfg in expected.get("inputs", {}).items():
    input_id = int(input_key.split(":")[1])
    if f"input:{input_id}" in current:
        actual_input = current[f"input:{input_id}"]
        
        if not check(
            f"input:{input_id} type",
            actual_input.get("type"),
            input_cfg.get("type")
        ):
            errors += 1

print("\n--- Scripts ---")
# Note: Script config is separate from Shelly.GetConfig
# Would need Script.GetConfig calls

print("\n--- Summary ---")
if errors == 0:
    print("✓ All checked configurations match expected values")
else:
    print(f"✗ {errors} configuration mismatches found")
    sys.exit(1)
EOF

echo ""
echo "=============================================="
echo "  VALIDATION COMPLETE"
echo "=============================================="
echo ""
echo "Files saved:"
echo "  - $CURRENT_CONFIG"
echo ""
echo "To see full diff, run:"
echo "  diff $EXPECTED_CONFIG $CURRENT_CONFIG"
