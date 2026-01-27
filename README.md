# Sauna Control System

A safety-critical control system for an electric sauna heater, implementing multiple layers of protection to ensure the heater can never fail to a permanently-on state.

**This project is frontend-agnostic.** It exposes MQTT and REST APIs that can be consumed by Home Assistant, Node-RED, custom apps, or any other system.

## Safety Goals

1. **Maximum 1-hour runtime** - Heater NEVER runs for more than 1 hour continuously
2. **Fail-safe design** - System fails to OFF state on any component failure
3. **Redundant safety** - Two independent contactors in series, controlled by separate devices
4. **Remote control** - WiFi-accessible via documented API
5. **Monitoring** - Real-time state and timer via MQTT

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         SAUNA CONTROL SYSTEM                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐            │
│  │   INPUTS     │     │  CONTROLLERS │     │   OUTPUTS    │            │
│  ├──────────────┤     ├──────────────┤     ├──────────────┤            │
│  │ RC Button    │────▶│   Primary    │────▶│ Main         │            │
│  │ BLU Button   │────▶│   Shelly     │     │ Contactor    │────┐       │
│  │ REST API     │────▶│   Pro 2      │────▶│ Indicator    │    │       │
│  │ MQTT         │     └──────────────┘     └──────────────┘    │       │
│  └──────────────┘            │                                  │       │
│                              │ (Sense line)                     │       │
│                              ▼                                  │       │
│                       ┌──────────────┐     ┌──────────────┐    │       │
│                       │  Secondary   │────▶│ Safety       │────┤       │
│                       │  Shelly      │     │ Contactor    │    │       │
│                       │  Pro 2       │     └──────────────┘    │       │
│                       └──────────────┘                         │       │
│                                                                ▼       │
│                                                         ┌──────────┐   │
│                                                         │  HEATER  │   │
│                                                         └──────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Both contactors must be ON for the heater to receive power. Either device can independently cut power.**

## Hardware Version

**Current Version:** 1.0 (see `hardware/HARDWARE_VERSION`)

All device IDs, pin mappings, and configurations are defined in the hardware version file. When hardware changes, create a new version.

| Component | Device ID | Role |
|-----------|-----------|------|
| Primary Shelly Pro 2 | `shellypro2-0cb815fcaff4` | Main control logic, 1-hour timer, user interface |
| Secondary Shelly Pro 2 | `shellypro2-0cb815fc96dc` | Safety backup, contactor feedback monitoring, weld detection |
| Temperature Sensor | `shellyplus2pm-3c8a1fe85f54` | Indoor/outdoor temperature monitoring |

See [hardware/versions/v1.0.yaml](hardware/versions/v1.0.yaml) for complete configuration.
See [hardware/versions/schematic-v1.0.pdf](hardware/versions/schematic-v1.0.pdf) for wiring schematic.

## API Reference

**See [docs/api.md](docs/api.md) for full API documentation.**

### Quick Reference

| Interface | Endpoint | Purpose |
|-----------|----------|---------|
| MQTT | `sauna/{device_id}/state` | ON/OFF state (boolean) |
| MQTT | `sauna/{device_id}/timer_raw` | Remaining seconds |
| REST | `POST /rpc/Script.Eval?id=1&code=...` | Toggle sauna |
| REST | `GET /rpc/Switch.GetStatus?id=0` | Get relay state |

### Toggle Example

```bash
curl -X POST "http://shellypro2-0cb815fcaff4.local/rpc/Script.Eval?id=1&code=Shelly.emitEvent(%7Binfo:%7Bevent:'ha_toggle'%7D%7D)"
```

## Quick Start: Redeployment

### 1. Deploy Shelly Scripts

```bash
./scripts/deploy-primary.sh
./scripts/deploy-secondary.sh
```

### 2. Configure Shelly Firmware Settings

Each Shelly device requires specific firmware settings configured via the Web UI.
- [Primary Shelly Settings](devices/shelly-primary/README.md#firmware-settings)
- [Secondary Shelly Settings](devices/shelly-secondary/README.md#firmware-settings)

### 3. Configure MQTT Broker

Configure both Shellys to connect to your MQTT broker via their Web UI.

### 4. Integrate with Your Frontend

Use the [API documentation](docs/api.md) to integrate with:
- Home Assistant (see separate `homeassistant-config` repo)
- Node-RED
- Custom applications
- Any MQTT-compatible system

## Directory Structure

```
sauna/
├── README.md                     # This file
├── TODO.md                       # Project tasks and known issues
├── hardware/
│   ├── HARDWARE_VERSION          # Current active version (e.g., "1.0")
│   ├── devices.sh                # Shell manifest (parses YAML)
│   ├── README.md                 # Hardware versioning guide
│   └── versions/
│       ├── v1.0.yaml             # Device IDs, pin mappings, safety params
│       └── schematic-v1.0.pdf    # Wiring schematic
├── devices/
│   ├── shelly-primary/
│   │   ├── README.md             # Deployment & settings guide
│   │   ├── config.json           # Expected firmware configuration
│   │   └── script.js             # Primary control script
│   └── shelly-secondary/
│       ├── README.md             # Deployment & settings guide
│       ├── config.json           # Expected firmware configuration
│       └── script.js             # Secondary safety script (INCOMPLETE)
├── scripts/
│   ├── deploy-primary.sh         # Full deployment (script + firmware settings)
│   ├── deploy-secondary.sh       # Full deployment (script + firmware settings)
│   ├── backup-settings.sh        # Backup device settings
│   ├── discover-devices.sh       # Find devices on network
│   ├── dump-shelly-config.sh     # Dump live device config
│   ├── diagnose-device.sh        # Device diagnostics
│   ├── diagnose-all.sh           # All devices diagnostics
│   ├── check-health.sh           # Quick health check
│   ├── monitor-wifi.sh           # WiFi signal monitoring
│   └── network-debug.sh          # Network troubleshooting
├── tests/
│   ├── README.md                 # Test documentation
│   ├── lint-scripts.sh           # Local JS linting
│   ├── test-deployment.sh        # Deployment verification
│   └── validate-config.sh        # Config validation
└── docs/
    ├── api.md                    # API reference (MQTT, REST)
    ├── hardware/
    │   └── README.md             # Legacy wiring overview
    ├── safety/
    │   └── README.md             # Safety design philosophy
    └── troubleshooting.md
```

## Control Interfaces

| Interface | Method | Notes |
|-----------|--------|-------|
| Physical RC Button | Wired to Primary Shelly Input 0 | Momentary switch |
| BLU Button | Bluetooth via BTHome | Paired with Primary Shelly |
| REST API | HTTP POST to Shelly | Any HTTP client |
| MQTT | Publish/Subscribe | Any MQTT client |

## Safety Features

1. **Primary 1-hour timer** (software) - Script enforces max runtime
2. **Secondary 1-hour timer** (software) - Independent backup timer
3. **Contactor feedback sensing** - Detects if contactors fail to engage/disengage
4. **Weld detection** - Monitors for welded contactor condition (1hr 5min threshold)
5. **Power-on defaults** - All relays default to OFF on power loss
6. **Series contactors** - Two contactors in series; both must be ON for heater power

## Frontend Integrations

This sauna system can be controlled by any frontend that supports MQTT or REST:

| Frontend | Integration Method | Notes |
|----------|-------------------|-------|
| Home Assistant | MQTT sensors + REST commands | See `homeassistant_sauna_config` repo |
| Node-RED | MQTT nodes + HTTP request | Full flexibility |
| Custom Web App | REST API | Direct HTTP calls |
| iOS Shortcuts | REST API | Quick toggles |
| Command Line | curl | Scripting |

## Testing

See [tests/README.md](tests/README.md) for full documentation.

### Lint Scripts Locally (Before Deployment)

```bash
./tests/lint-scripts.sh
```

### Test Deployed Configuration

```bash
# Test all devices
./tests/test-deployment.sh all

# Test with functional tests (actually toggles the sauna!)
./tests/test-deployment.sh all --functional
```

### Validate Config Against Expected

```bash
./tests/validate-config.sh shellypro2-0cb815fcaff4.local
```

### Dump Current Device Config

```bash
./scripts/dump-shelly-config.sh shellypro2-0cb815fcaff4.local
```

## Maintenance

- **Backup settings regularly** - Run `scripts/backup-settings.sh`
- **Test safety features** - Periodically verify contactors disengage properly
- **Check for firmware updates** - Keep Shelly firmware current
- **Run tests after changes** - `./scripts/test-deployment.sh all`

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common issues.
