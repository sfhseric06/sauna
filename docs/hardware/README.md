# Hardware Documentation

## Schematic & Configuration

**See `/hardware/` directory** for:
- Current hardware version (`HARDWARE_VERSION`)
- Version-specific configuration (`versions/v{VERSION}.yaml`)
- Schematics (`versions/schematic-v{VERSION}.pdf`)

The `/hardware/` directory is the **source of truth** for all hardware-specific parameters including device IDs, pin mappings, and wiring.

## System Overview

The sauna heater is controlled through two contactors in series:

```
┌─────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌────────┐
│  MAINS  │────▶│ MAIN CONTACTOR  │────▶│ SAFETY CONTACTOR│────▶│ HEATER │
│  POWER  │     │ (Primary Shelly)│     │(Secondary Shelly)│     │        │
└─────────┘     └─────────────────┘     └─────────────────┘     └────────┘
```

**Both contactors must be closed for power to reach the heater.**

## Current Hardware (v1.0)

| Component | Device | Role |
|-----------|--------|------|
| Primary Controller | Shelly Pro 2 | Main control logic, 1-hour timer |
| Secondary Controller | Shelly Pro 2 | Safety backup, weld detection |
| Temperature Sensor | Shelly Plus 2PM | Indoor/outdoor temperature |

See `hardware/versions/v1.0.yaml` for complete device IDs and pin mappings.

## Wiring Summary

### Primary Shelly Pro 2

| Terminal | Connection | Notes |
|----------|------------|-------|
| Input 0 (SW1) | RC Button | Momentary to common |
| Relay 0 (O1) | Main Contactor coil | Controls primary power |
| Relay 1 (O2) | Indicator Light | Status indicator |

### Secondary Shelly Pro 2

| Terminal | Connection | Notes |
|----------|------------|-------|
| Input 0 (SW1) | Secondary contactor feedback | Senses when BOTH contactors are ON |
| Input 1 (SW2) | Primary contactor output sense | Senses when Primary is ON |
| Relay 0 (O1) | Safety Contactor coil | Controls backup power |

## Safety Design

See [/docs/safety/README.md](/docs/safety/README.md) for safety philosophy.

Key points:
1. **Series contactors** - Both must close for heater power
2. **Independent controllers** - Each Shelly runs its own safety timer
3. **Sense feedback** - Secondary verifies contactors actually engaged
4. **Fail-safe defaults** - All relays default OFF on power loss

## Important Notes

- Consult an electrician for high-voltage wiring
- Use appropriately rated contactors for heater load
- Ensure proper grounding
- Test safety cutoffs before regular use
