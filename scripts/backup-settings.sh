#!/bin/bash
# Backup Shelly device settings and scripts
# Usage: ./backup-settings.sh [backup_dir]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source device manifest
source "$SCRIPT_DIR/../hardware/devices.sh"

BACKUP_DIR="${1:-$SCRIPT_DIR/../backups/$(date +%Y%m%d_%H%M%S)}"

# Device hostnames from manifest
PRIMARY_HOST="$PRIMARY_HOSTNAME"
SECONDARY_HOST="$SECONDARY_HOSTNAME"

echo "=== Sauna System Backup ==="
echo "Backup directory: $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR"

backup_device() {
    local HOST=$1
    local NAME=$2
    local DIR="$BACKUP_DIR/$NAME"
    
    echo "Backing up $NAME ($HOST)..."
    mkdir -p "$DIR"
    
    # Check connectivity
    if ! curl -s --connect-timeout 5 "http://$HOST/rpc/Shelly.GetStatus" > /dev/null 2>&1; then
        echo "  ⚠ WARNING: Cannot reach $HOST - skipping"
        return
    fi
    
    # Device info
    echo "  - Device info..."
    curl -s "http://$HOST/rpc/Shelly.GetDeviceInfo" > "$DIR/device-info.json" 2>/dev/null || echo "{}" > "$DIR/device-info.json"
    
    # Full config
    echo "  - Full configuration..."
    curl -s "http://$HOST/rpc/Shelly.GetConfig" > "$DIR/config.json" 2>/dev/null || echo "{}" > "$DIR/config.json"
    
    # Full status
    echo "  - Current status..."
    curl -s "http://$HOST/rpc/Shelly.GetStatus" > "$DIR/status.json" 2>/dev/null || echo "{}" > "$DIR/status.json"
    
    # Scripts
    echo "  - Scripts..."
    mkdir -p "$DIR/scripts"
    
    # Try to backup scripts 1-5
    for i in 1 2 3 4 5; do
        SCRIPT_STATUS=$(curl -s "http://$HOST/rpc/Script.GetStatus?id=$i" 2>/dev/null || echo '{"error":{}}')
        if ! echo "$SCRIPT_STATUS" | grep -q '"error"'; then
            echo "    - Script $i..."
            echo "$SCRIPT_STATUS" > "$DIR/scripts/script-$i-status.json"
            
            # Get script code
            curl -s "http://$HOST/rpc/Script.GetCode?id=$i" > "$DIR/scripts/script-$i-code.json" 2>/dev/null || true
            
            # Get script config
            curl -s "http://$HOST/rpc/Script.GetConfig?id=$i" > "$DIR/scripts/script-$i-config.json" 2>/dev/null || true
        fi
    done
    
    # KVS data (if any)
    echo "  - KVS data..."
    curl -s "http://$HOST/rpc/KVS.GetMany" > "$DIR/kvs.json" 2>/dev/null || echo "{}" > "$DIR/kvs.json"
    
    # Input configurations
    echo "  - Input configs..."
    for i in 0 1; do
        curl -s "http://$HOST/rpc/Input.GetConfig?id=$i" > "$DIR/input-$i-config.json" 2>/dev/null || true
    done
    
    # Switch/Relay configurations
    echo "  - Relay configs..."
    for i in 0 1 2; do
        curl -s "http://$HOST/rpc/Switch.GetConfig?id=$i" > "$DIR/switch-$i-config.json" 2>/dev/null || true
    done
    
    # MQTT config
    echo "  - MQTT config..."
    curl -s "http://$HOST/rpc/MQTT.GetConfig" > "$DIR/mqtt-config.json" 2>/dev/null || echo "{}" > "$DIR/mqtt-config.json"
    
    # WiFi config (be careful with credentials)
    echo "  - WiFi config..."
    curl -s "http://$HOST/rpc/WiFi.GetConfig" > "$DIR/wifi-config.json" 2>/dev/null || echo "{}" > "$DIR/wifi-config.json"
    
    # BTHome config (if available)
    echo "  - BTHome config..."
    curl -s "http://$HOST/rpc/BTHome.GetConfig" > "$DIR/bthome-config.json" 2>/dev/null || echo "{}" > "$DIR/bthome-config.json"
    
    echo "  ✓ $NAME backup complete"
}

# Backup both devices
backup_device "$PRIMARY_HOST" "primary"
backup_device "$SECONDARY_HOST" "secondary"

# Create summary
echo ""
echo "Creating backup summary..."
cat > "$BACKUP_DIR/README.md" << EOF
# Sauna System Backup

**Created:** $(date)

## Contents

- \`primary/\` - Primary Shelly Pro 2 ($PRIMARY_HOST)
- \`secondary/\` - Secondary Shelly Pro 2 ($SECONDARY_HOST)

## Restore Instructions

### Restore Script Code

\`\`\`bash
# Extract code from backup
cat primary/scripts/script-1-code.json | jq -r '.data' > restored-script.js

# Upload to device (use deploy scripts for full process)
../../scripts/deploy-primary.sh
\`\`\`

### Restore Device Config

Most settings need to be restored via the Shelly Web UI. Use the backed-up 
JSON files as reference for the values to configure.

Key files:
- \`config.json\` - Full device configuration
- \`switch-*-config.json\` - Relay settings (power on default, etc.)
- \`input-*-config.json\` - Input mode settings
- \`mqtt-config.json\` - MQTT broker settings

## Notes

- WiFi credentials in \`wifi-config.json\` may be partially masked
- MQTT passwords may be masked
- Some settings require device-specific restore via RPC
EOF

echo "✓ Summary created"

# Calculate backup size
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
FILE_COUNT=$(find "$BACKUP_DIR" -type f | wc -l | tr -d ' ')

echo ""
echo "=== Backup Complete ==="
echo "Location: $BACKUP_DIR"
echo "Size: $BACKUP_SIZE"
echo "Files: $FILE_COUNT"
echo ""
echo "To restore, see $BACKUP_DIR/README.md"
