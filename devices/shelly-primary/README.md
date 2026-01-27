# Primary Shelly Pro 2 - Control Device

**Device ID:** `shellypro2-0cb815fcaff4`  
**Role:** Main control logic, timer management, user interface

## Overview

The Primary Shelly handles:
- User input (physical button, BLU button, Home Assistant)
- Main contactor control (Relay 0)
- Indicator light control (Relay 1)
- 1-hour safety timer
- MQTT state reporting

## Relay Assignments

| Relay | Function | Notes |
|-------|----------|-------|
| Relay 0 | Main Contactor | Controls primary power contactor |
| Relay 1 | Indicator Light | Visual status indicator |

## Input Assignments

| Input | Function | Notes |
|-------|----------|-------|
| Input 0 | RC Button | Physical momentary switch |

## Complete Deployment

The deploy script configures **everything** via RPC - no manual Web UI configuration needed:

```bash
# Full deployment (script + all firmware settings)
../../scripts/deploy-primary.sh

# With MQTT broker
../../scripts/deploy-primary.sh shellypro2-0cb815fcaff4.local 192.168.1.100
```

This configures:
- Input 0 as Button (momentary) mode
- Relay 0 & 1 to default OFF
- Virtual Button 200 for Home Assistant
- MQTT connection (if broker specified)
- Script upload and enable

### Manual Deployment (Alternative)

If you prefer manual configuration via Web UI:

1. Navigate to `http://shellypro2-0cb815fcaff4.local`
2. Configure inputs, relays, and MQTT per the Firmware Settings section below
3. Go to **Scripts** → Create new → Paste `script.js` → Enable "Run on startup"

## Firmware Settings

**CRITICAL:** These settings must be configured via the Shelly Web UI. They persist across reboots but are NOT part of the script.

### Access Settings

1. Navigate to `http://shellypro2-0cb815fcaff4.local`
2. Log in if authentication is enabled

### Required Settings

#### Input 0 Configuration
- **Mode:** Button (Momentary)
- **Reverse:** As needed for your hardware

#### Relay 0 (Main Contactor)
- **Name:** "Main Contactor"
- **Power on default:** **OFF** ⚠️ CRITICAL
- **Auto off:** Disabled (handled by script)

#### Relay 1 (Indicator)
- **Name:** "Indicator"
- **Power on default:** **OFF**

#### Scripts
- **Enable scripting:** Yes
- **Script 4 (or your slot):** Enable "Run on startup"

#### MQTT (Required for HA Integration)
- **Enable MQTT:** Yes
- **Server:** Your MQTT broker address
- **Client ID:** `shellypro2-0cb815fcaff4` (or auto)
- **User/Pass:** As configured on your broker

#### Virtual Button (for Home Assistant)
- **Create Virtual Button with ID 200**
- This allows HA to trigger toggles via REST:
  ```
  http://shellypro2-0cb815fcaff4.local/rpc/Button.Trigger?id=200&event=single_push
  ```
- The deploy script creates this automatically

#### BTHome (for BLU Button)
- Pair your BLU Button 1 device via Web UI
- Note the component ID assigned (default: `bthomedevice:200`)

## Backup Settings

To backup current device settings:

```bash
# Backup full device config
curl "http://shellypro2-0cb815fcaff4.local/rpc/Shelly.GetConfig" > primary-config-backup.json

# Backup script code
curl "http://shellypro2-0cb815fcaff4.local/rpc/Script.GetCode?id=1" > primary-script-backup.json

# Backup KVS data
curl "http://shellypro2-0cb815fcaff4.local/rpc/KVS.GetMany" > primary-kvs-backup.json
```

## Verify Deployment

After deployment, verify:

1. **Script is running:**
   ```bash
   curl "http://shellypro2-0cb815fcaff4.local/rpc/Script.GetStatus?id=1"
   # Should show "running": true
   ```

2. **MQTT is publishing:**
   ```bash
   mosquitto_sub -h YOUR_BROKER -t "sauna/shellypro2-0cb815fcaff4/#" -v
   ```

3. **Toggle works:**
   - Press physical button → sauna should toggle
   - Check MQTT for state change

## Script Configuration Constants

These values are hardcoded in `script.js`. Modify if your setup differs:

```javascript
let SHELLY_DEVICE_ID = "shellypro2-0cb815fcaff4"; 
let SAUNA_DURATION_MS = 3600000; // 1 Hour
const MAIN_RELAY_ID = 0;
const INDICATOR_RELAY_ID = 1;
const BLU_BUTTON_1_COMPONENT = 'bthomedevice:200';
```

## Troubleshooting

### Script won't start
- Check **Scripts** → ensure "Run on startup" is enabled
- Check console for syntax errors
- Verify MQTT is configured

### Button press not detected
- Verify Input 0 mode is set to "Button"
- Check script console for "Click registered" messages

### MQTT not publishing
- Verify MQTT server settings
- Check MQTT broker logs
- Test with `mosquitto_sub`
