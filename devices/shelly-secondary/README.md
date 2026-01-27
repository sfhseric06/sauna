# Secondary Shelly Pro 2 - Safety Device

**Device ID:** `shellypro2-0cb815fc96dc`  
**Role:** Safety backup, contactor feedback monitoring, weld detection

## Overview

The Secondary Shelly provides an independent safety layer:
- Controls safety contactor (in series with main contactor)
- Monitors primary contactor output via sense line
- Independent 1-hour safety timer
- Weld detection (1hr 5min threshold)
- Contactor engagement feedback verification

## Safety Philosophy

**This device operates independently of the Primary Shelly.** Even if the Primary Shelly fails or its script crashes, the Secondary will:
1. Cut power after 1 hour maximum
2. Detect welded contactors
3. Verify contactor engagement feedback

## Relay Assignments

| Relay | Function | Notes |
|-------|----------|-------|
| Relay 0 | Safety Contactor | Secondary power contactor (in series with main) |

## Input Assignments

| Input | Function | Notes |
|-------|----------|-------|
| Input 0 (SW1) | Secondary Contactor Sense | HIGH = Both contactors ON |
| Input 1 (SW2) | Primary Contactor Sense | HIGH = Primary is ON |

## Script Deployment

### Option 1: Web UI

1. Navigate to `http://shellypro2-0cb815fc96dc.local` (or device IP)
2. Go to **Scripts** section
3. Create a new script (or edit existing)
4. Copy contents of `script.js` into the editor
5. Save and enable "Run on startup"

### Option 2: Deploy Script (Automated)

```bash
../../scripts/deploy-secondary.sh
```

## Firmware Settings

**CRITICAL:** These settings must be configured via the Shelly Web UI.

### Access Settings

1. Navigate to `http://shellypro2-0cb815fc96dc.local`
2. Log in if authentication is enabled

### Required Settings

#### Input 0 (SW1 - Secondary Sense)
- **Mode:** Switch (maintains state reading)
- **Do NOT detach** - Script monitors this input

#### Input 1 (SW2 - Primary Sense)
- **Mode:** Switch
- **Do NOT detach** - Script monitors this input

#### Relay 0 (Safety Contactor)
- **Name:** "Safety Contactor"
- **Power on default:** **OFF** ⚠️ CRITICAL
- **Auto off:** Optional backup (set to 3660 seconds = 61 minutes)

#### Safety Settings
- **Max Power Protection:** Enable as additional backup
- Configure to trip at appropriate threshold for your heater

#### Scripts
- **Enable scripting:** Yes
- **Script:** Enable "Run on startup"

## Script Logic

```
┌─────────────────────────────────────────────────────────────────┐
│                   SECONDARY SAFETY LOGIC                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  [Primary Sense (SW2) goes HIGH]                               │
│           │                                                     │
│           ▼                                                     │
│  ┌─────────────────┐                                           │
│  │ Turn ON Safety  │                                           │
│  │ Contactor       │                                           │
│  └────────┬────────┘                                           │
│           │                                                     │
│           ▼  (after 1 second)                                  │
│  ┌─────────────────┐     ┌─────────────────┐                   │
│  │ Check SW1       │────▶│ SW1 HIGH?       │                   │
│  │ (feedback)      │     │ (Contactor OK)  │                   │
│  └─────────────────┘     └────────┬────────┘                   │
│                                   │                             │
│           ┌───────────────────────┴───────────────────┐        │
│           │ NO                                    YES │        │
│           ▼                                           ▼        │
│  ┌─────────────────┐                    ┌─────────────────┐    │
│  │ FAULT: Contactor│                    │ Start 1hr timer │    │
│  │ didn't engage   │                    │ Start weld timer│    │
│  │ → SHUT DOWN     │                    └─────────────────┘    │
│  └─────────────────┘                                           │
│                                                                 │
│  [Primary Sense (SW2) goes LOW] OR [1hr timer expires]         │
│           │                                                     │
│           ▼                                                     │
│  ┌─────────────────┐                                           │
│  │ Turn OFF Safety │                                           │
│  │ Contactor       │                                           │
│  └─────────────────┘                                           │
│                                                                 │
│  [Weld timer (1hr 5min) expires while SW2 still HIGH]          │
│           │                                                     │
│           ▼                                                     │
│  ┌─────────────────┐                                           │
│  │ FAULT: Primary  │                                           │
│  │ contactor welded│                                           │
│  │ → ALERT         │                                           │
│  └─────────────────┘                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Backup Settings

```bash
# Backup full device config
curl "http://shellypro2-0cb815fc96dc.local/rpc/Shelly.GetConfig" > secondary-config-backup.json

# Backup script code
curl "http://shellypro2-0cb815fc96dc.local/rpc/Script.GetCode?id=1" > secondary-script-backup.json
```

## Verify Deployment

1. **Script is running:**
   ```bash
   curl "http://shellypro2-0cb815fc96dc.local/rpc/Script.GetStatus?id=1"
   ```

2. **Inputs are readable:**
   ```bash
   curl "http://shellypro2-0cb815fc96dc.local/rpc/Input.GetStatus?id=0"
   curl "http://shellypro2-0cb815fc96dc.local/rpc/Input.GetStatus?id=1"
   ```

## Script Configuration Constants

```javascript
const SAFETY_RELAY_ID = 0; 
const PRIMARY_OUTPUT_SENSE_INPUT = 'input:1';  // SW2
const SECONDARY_OUTPUT_SENSE_INPUT = 'input:0'; // SW1
const SAFETY_MAX_DURATION_MS = 3600000; // 1 hour
const WELD_FAULT_THRESHOLD_MS = 3900000; // 1hr 5min
```

## ⚠️ Known Issue

**The current `script.js` appears incomplete** (ends mid-comment at line 71). Verify you have the complete script before deployment. The script should include:
- Input event handlers for SW2 state changes
- Logic to turn safety relay ON when primary sense goes HIGH
- Logic to turn safety relay OFF when primary sense goes LOW or timer expires
- Weld detection timeout handler
