#!/bin/bash
# =============================================================================
# DEVICE MANIFEST - Reads from YAML (Single Source of Truth)
# =============================================================================
# This script parses hardware/versions/vX.X.yaml and exports shell variables.
# The YAML file is the authoritative source for all device information.
#
# Usage: source "$(dirname "$0")/../hardware/devices.sh"
#
# Requires: Python 3 with PyYAML (pip install pyyaml) OR falls back to regex parsing
# =============================================================================

# Determine script location (works when sourced from any directory)
if [ -n "${BASH_SOURCE[0]}" ]; then
    _DEVICES_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    _DEVICES_SH_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Read hardware version
HARDWARE_VERSION=$(cat "$_DEVICES_SH_DIR/HARDWARE_VERSION" 2>/dev/null | tr -d '[:space:]' || echo "1.0")

# Path to YAML config
_YAML_FILE="$_DEVICES_SH_DIR/versions/v${HARDWARE_VERSION}.yaml"

if [ ! -f "$_YAML_FILE" ]; then
    echo "ERROR: Hardware config not found: $_YAML_FILE" >&2
    return 1 2>/dev/null || exit 1
fi

# =============================================================================
# PARSE YAML AND EXPORT VARIABLES
# =============================================================================
# Uses Python to parse YAML and output shell variable assignments

_parse_yaml() {
    local yaml_file="$_YAML_FILE"
    python3 - "$yaml_file" << 'PYTHON_SCRIPT'
import sys
import re

yaml_file = sys.argv[1]

# Simple YAML parser (no external dependencies)
# Handles the specific structure of our hardware config

def parse_yaml_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    
    devices = {}
    current_device = None
    in_devices_section = False
    indent_level = 0
    
    for line in content.split('\n'):
        stripped = line.strip()
        
        # Track if we're in the devices section
        if line.startswith('devices:'):
            in_devices_section = True
            continue
        
        # Exit devices section when we hit another top-level key
        if in_devices_section and line and not line.startswith(' ') and not line.startswith('#'):
            if ':' in line and not line.strip().startswith('#'):
                in_devices_section = False
        
        if not in_devices_section:
            continue
            
        # Skip comments and empty lines
        if not stripped or stripped.startswith('#'):
            continue
        
        # Detect device name (2-space indent, ends with colon, no value)
        if line.startswith('  ') and not line.startswith('    '):
            match = re.match(r'^  ([a-z_0-9]+):\s*$', line)
            if match:
                current_device = match.group(1)
                devices[current_device] = {}
                continue
        
        # Detect device properties (4-space indent)
        if current_device and line.startswith('    ') and not line.startswith('      '):
            match = re.match(r'^    ([a-z_]+):\s*["\']?([^"\'#]+)["\']?\s*(?:#.*)?$', line)
            if match:
                key = match.group(1)
                value = match.group(2).strip().strip('"\'')
                devices[current_device][key] = value
    
    return devices

try:
    devices = parse_yaml_file(yaml_file)
    
    # Output shell variable assignments
    # Map YAML device names to shell variable prefixes
    prefix_map = {
        'primary_controller': 'PRIMARY',
        'secondary_controller': 'SECONDARY', 
        'led_strip': 'LED_STRIP',
        'blu_rc4': 'BLU_RC4',
        'hvac_controller': 'HVAC',
        'exterior_sensor': 'EXTERIOR'
    }
    
    for device_name, props in devices.items():
        prefix = prefix_map.get(device_name, device_name.upper())
        
        if 'device_id' in props:
            print(f'{prefix}_DEVICE_ID="{props["device_id"]}"')
        if 'hostname' in props:
            print(f'{prefix}_HOSTNAME="{props["hostname"]}"')
        if 'mac_address' in props:
            # Normalize MAC (remove colons for consistency)
            mac = props["mac_address"].replace(":", "").upper()
            print(f'{prefix}_MAC="{mac}"')
        if 'model' in props:
            print(f'{prefix}_MODEL="{props["model"]}"')
        if 'role' in props:
            print(f'{prefix}_ROLE="{props["role"]}"')
    
    # Also output device arrays
    wifi_devices = []
    wifi_hostnames = []
    ble_devices = []
    sauna_devices = []
    sauna_hostnames = []
    
    sauna_core = ['primary_controller', 'secondary_controller', 'led_strip']
    
    for device_name, props in devices.items():
        prefix = prefix_map.get(device_name, device_name.upper())
        if 'hostname' in props:
            wifi_devices.append(f'${prefix}_DEVICE_ID')
            wifi_hostnames.append(f'${prefix}_HOSTNAME')
            if device_name in sauna_core:
                sauna_devices.append(f'${prefix}_DEVICE_ID')
                sauna_hostnames.append(f'${prefix}_HOSTNAME')
        elif 'mac_address' in props:
            # Bluetooth-only device
            ble_devices.append(f'${prefix}_MAC')
    
    print(f'SAUNA_DEVICE_IDS=({" ".join(sauna_devices)})')
    print(f'SAUNA_HOSTNAMES=({" ".join(sauna_hostnames)})')
    print(f'ALL_DEVICE_IDS=({" ".join(wifi_devices)})')
    print(f'ALL_HOSTNAMES=({" ".join(wifi_hostnames)})')
    print(f'BLE_DEVICES=({" ".join(ble_devices)})')
    
    # Aliases for backward compatibility
    print('TEMP_SENSOR_DEVICE_ID="$EXTERIOR_DEVICE_ID"')
    print('TEMP_SENSOR_HOSTNAME="$EXTERIOR_HOSTNAME"')
    print('TEMP_SENSOR_MAC="$EXTERIOR_MAC"')
    print('TEMP_SENSOR_MODEL="$EXTERIOR_MODEL"')

except Exception as e:
    print(f'echo "ERROR parsing YAML: {e}" >&2', file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT
}

# Execute the parser and eval the output
eval "$(_parse_yaml)"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Get hostname by role
get_hostname() {
    local role="$1"
    case "$role" in
        primary)        echo "$PRIMARY_HOSTNAME" ;;
        secondary)      echo "$SECONDARY_HOSTNAME" ;;
        led|ledstrip)   echo "$LED_STRIP_HOSTNAME" ;;
        hvac)           echo "$HVAC_HOSTNAME" ;;
        exterior|temp)  echo "$EXTERIOR_HOSTNAME" ;;
        *) echo "" ;;
    esac
}

# Get device ID by role
get_device_id() {
    local role="$1"
    case "$role" in
        primary)        echo "$PRIMARY_DEVICE_ID" ;;
        secondary)      echo "$SECONDARY_DEVICE_ID" ;;
        led|ledstrip)   echo "$LED_STRIP_DEVICE_ID" ;;
        hvac)           echo "$HVAC_DEVICE_ID" ;;
        exterior|temp)  echo "$EXTERIOR_DEVICE_ID" ;;
        *) echo "" ;;
    esac
}

# Get MAC by role
get_mac() {
    local role="$1"
    case "$role" in
        primary)        echo "$PRIMARY_MAC" ;;
        secondary)      echo "$SECONDARY_MAC" ;;
        led|ledstrip)   echo "$LED_STRIP_MAC" ;;
        hvac)           echo "$HVAC_MAC" ;;
        exterior|temp)  echo "$EXTERIOR_MAC" ;;
        blurc4)         echo "$BLU_RC4_MAC" ;;
        *) echo "" ;;
    esac
}

# Check if a hostname is reachable (quick ping via HTTP)
is_device_reachable() {
    local hostname="$1"
    curl -s --connect-timeout 2 "http://$hostname/rpc/Shelly.GetDeviceInfo" >/dev/null 2>&1
}

# Resolve hostname to IP (useful for debugging)
resolve_hostname() {
    local hostname="$1"
    if command -v dns-sd &>/dev/null; then
        dns-sd -G v4 "$hostname" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
    elif command -v getent &>/dev/null; then
        getent hosts "$hostname" 2>/dev/null | awk '{print $1}'
    else
        ping -c 1 -W 1 "$hostname" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}
