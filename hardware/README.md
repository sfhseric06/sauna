# Hardware Configuration

This directory contains hardware-specific configuration for the sauna control system.

## Hardware Versioning

**Current Version:** See `HARDWARE_VERSION` file

All firmware, scripts, and Home Assistant configurations reference the hardware version to ensure consistency. When hardware changes (new devices, different wiring, updated schematic), a new version is created.

## Directory Structure

```
hardware/
├── HARDWARE_VERSION          # Current active version (e.g., "1.0")
├── devices.sh                # Shell wrapper - parses YAML for bash scripts
├── README.md                 # This file
└── versions/
    ├── v1.0.yaml             # Hardware config for version 1.0 (SOURCE OF TRUTH)
    ├── schematic-v1.0.pdf    # Schematic for version 1.0
    └── ...                   # Future versions
```

## Hardware Configuration File

Each version has a YAML file (`v{VERSION}.yaml`) containing:

- **Device identifiers** - Shelly device IDs, MAC addresses, hostnames
- **Pin mappings** - What each input/output is connected to
- **MQTT topics** - Topic structure for this hardware
- **Safety parameters** - Timeouts, thresholds
- **Temperature sensors** - Entity IDs, locations

## Single Source of Truth: `versions/vX.X.yaml`

The YAML file is the **single source of truth** for all hardware configuration. The `devices.sh` script dynamically parses it to provide shell variables.

**To add or change a device:** Edit the YAML file only. No need to update `devices.sh`.

```yaml
# In versions/v1.0.yaml
devices:
  primary_controller:
    model: "Shelly Pro 2"
    device_id: "shellypro2-0cb815fcaff4"
    hostname: "shellypro2-0cb815fcaff4.local"
    mac_address: "0C:B8:15:FC:AF:F4"
    role: "Main control logic"
```

## Using Device Info in Scripts

Scripts source `devices.sh` which parses the YAML and exports shell variables:

```bash
# Source the manifest in any script
source "$SCRIPT_DIR/../hardware/devices.sh"

# Use variables (automatically parsed from YAML)
echo "Primary: $PRIMARY_HOSTNAME"    # shellypro2-0cb815fcaff4.local
echo "MAC: $PRIMARY_MAC"             # 0CB815FCAFF4
echo "Device ID: $PRIMARY_DEVICE_ID" # shellypro2-0cb815fcaff4
echo "BLE remote: $BLU_RC4_MAC"      # 7CC6B69EA488
```

**Why mDNS hostnames?**
- Based on MAC addresses (permanent identifiers)
- Auto-discovered on the network (no static IP configuration needed)
- Work reliably across reboots and DHCP changes

**Discover devices on network:**
```bash
./scripts/discover-devices.sh        # Check expected devices
./scripts/discover-devices.sh --scan # Also scan for unexpected devices
```

## How Components Reference Hardware

### Deploy Scripts

The deploy scripts source the device manifest:

```bash
# In deploy-primary.sh
source "$SCRIPT_DIR/../hardware/devices.sh"
DEVICE_HOST="${1:-$PRIMARY_HOSTNAME}"  # Default from manifest, override via argument
```

### Shelly Scripts

Device IDs are configured as constants at the top of each script:

```javascript
// In shelly_primary_script.js
let SHELLY_DEVICE_ID = "shellypro2-0cb815fcaff4";  // From hardware/versions/v1.0.yaml
```

### Home Assistant Config

The HA package references device IDs for MQTT topics and REST endpoints:

```yaml
# In sauna_system.yaml
state_topic: "sauna/shellypro2-0cb815fcaff4/state"  # From hardware config
```

## Creating a New Hardware Version

When hardware changes (e.g., replacing a Shelly device with a new one):

### Step 1: Create version config file

```bash
cp versions/v1.0.yaml versions/v2.0.yaml
```

### Step 2: Edit the YAML with new device info

```yaml
# In versions/v2.0.yaml - update device IDs
devices:
  primary_controller:
    device_id: "shellypro2-NEWMACADDRESS"
    hostname: "shellypro2-NEWMACADDRESS.local"
    mac_address: "XX:XX:XX:XX:XX:XX"
    # ... update all devices as needed
```

**How to find new device IDs:**
1. Power on the new Shelly device
2. Connect to its WiFi AP (ShellyPro2-XXXXXX)
3. Note the MAC suffix from the AP name
4. Or run `./scripts/discover-devices.sh --scan` to find it on your network

### Step 3: Add schematic (if changed)

```bash
cp new-schematic.pdf versions/schematic-v2.0.pdf
```

### Step 4: Switch to the new version

```bash
echo "2.0" > HARDWARE_VERSION
```

All scripts automatically use v2.0 device definitions (parsed from YAML).

### Step 5: Verify

```bash
./scripts/discover-devices.sh
```

### Step 6: Update dependent files

- Shelly scripts (if device IDs are hardcoded in JS)
- Home Assistant config (entity IDs, MQTT topics)

### Rollback

To switch back to v1.0:
```bash
echo "1.0" > HARDWARE_VERSION
```

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-26 | Initial documented configuration |

## Schematic Notes

The schematic (`schematic-v{VERSION}.pdf`) is the **source of truth** for physical wiring. The YAML config file documents the logical mapping but the schematic shows actual connections.

If the schematic and YAML disagree, **trust the schematic** and update the YAML.
