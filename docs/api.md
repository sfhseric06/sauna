# Sauna Control API

This document defines the interfaces exposed by the sauna control system. Any frontend (Home Assistant, Node-RED, custom apps, etc.) can integrate using these APIs.

## Overview

The sauna system exposes control and monitoring via:
- **MQTT** - Real-time state and timer updates
- **REST/RPC** - Direct device control via Shelly HTTP API
- **Physical inputs** - Button, Bluetooth (BLU Button)

## Device Endpoints

| Device | Hostname | IP Discovery |
|--------|----------|--------------|
| Primary Shelly | `shellypro2-0cb815fcaff4.local` | mDNS |
| Secondary Shelly | `shellypro2-0cb815fc96dc.local` | mDNS |

## MQTT Interface

### Broker Requirements

The Primary Shelly must be configured to connect to an MQTT broker. Configure via Shelly Web UI → Settings → MQTT.

### Topics Published

| Topic | Payload | QoS | Retained | Description |
|-------|---------|-----|----------|-------------|
| `sauna/shellypro2-0cb815fcaff4/state` | `true` / `false` | 1 | Yes | Sauna ON/OFF state |
| `sauna/shellypro2-0cb815fcaff4/timer_raw` | Integer (seconds) | 1 | Yes | Remaining session time |

### Example: Subscribe to State

```bash
mosquitto_sub -h YOUR_BROKER -t "sauna/shellypro2-0cb815fcaff4/#" -v
```

Output:
```
sauna/shellypro2-0cb815fcaff4/state true
sauna/shellypro2-0cb815fcaff4/timer_raw 3420
```

### State Interpretation

| `state` | `timer_raw` | Meaning |
|---------|-------------|---------|
| `true` | > 0 | Sauna running, N seconds remaining |
| `true` | 0 | Session ending (about to turn off) |
| `false` | 0 | Sauna off |

## REST/RPC Interface

The Shelly devices expose an HTTP RPC API for direct control.

### Toggle Sauna (On/Off)

Emits a toggle event to the Primary Shelly script. The script handles the state machine logic.

```http
POST http://shellypro2-0cb815fcaff4.local/rpc/Script.Eval?id=1&code=Shelly.emitEvent({info:{event:'ha_toggle'}})
```

**Response:** `{"result": null}` (event is async)

**Curl example:**
```bash
curl -X POST "http://shellypro2-0cb815fcaff4.local/rpc/Script.Eval?id=1&code=Shelly.emitEvent(%7Binfo:%7Bevent:'ha_toggle'%7D%7D)"
```

### Get Current State

Query the MQTT-published state via KVS (Key-Value Store) or relay status:

**Relay status (direct hardware state):**
```http
GET http://shellypro2-0cb815fcaff4.local/rpc/Switch.GetStatus?id=0
```

Response:
```json
{
  "id": 0,
  "source": "script",
  "output": true,
  "temperature": { "tC": 45.2, "tF": 113.4 }
}
```

### Get Remaining Time

Subscribe to MQTT for real-time timer updates:

```bash
mosquitto_sub -h YOUR_BROKER -t "sauna/shellypro2-0cb815fcaff4/timer_raw"
```

**Note:** The script publishes remaining time to MQTT every 30 seconds. KVS is NOT used.

### Direct Relay Control (Emergency/Testing)

**Turn off main contactor:**
```http
GET http://shellypro2-0cb815fcaff4.local/rpc/Switch.Set?id=0&on=false
```

**Turn off safety contactor:**
```http
GET http://shellypro2-0cb815fc96dc.local/rpc/Switch.Set?id=0&on=false
```

⚠️ **Warning:** Direct relay control bypasses script logic. Use toggle event for normal operation.

## Physical Inputs

### RC Button (Wired)

- Connected to: Primary Shelly Input 0
- Type: Momentary (button mode)
- Action: Single press toggles sauna state

### BLU Button (Bluetooth)

- Paired with: Primary Shelly via BTHome
- Component ID: `bthomedevice:200` (verify in your setup)
- Action: Single push toggles sauna state

## Integration Examples

### Home Assistant (REST)

```yaml
rest_command:
  sauna_toggle:
    url: "http://shellypro2-0cb815fcaff4.local/rpc/Script.Eval?id=1&code=Shelly.emitEvent({info:{event:'ha_toggle'}})"
    method: post

sensor:
  - platform: mqtt
    name: "Sauna State"
    state_topic: "sauna/shellypro2-0cb815fcaff4/state"
    value_template: "{{ 'on' if value_json else 'off' }}"
```

### Node-RED

```json
{
  "id": "sauna_toggle",
  "type": "http request",
  "method": "POST",
  "url": "http://shellypro2-0cb815fcaff4.local/rpc/Script.Eval?id=1&code=Shelly.emitEvent({info:{event:'ha_toggle'}})"
}
```

### Python

```python
import requests

def toggle_sauna():
    url = "http://shellypro2-0cb815fcaff4.local/rpc/Script.Eval"
    params = {
        "id": 1,
        "code": "Shelly.emitEvent({info:{event:'ha_toggle'}})"
    }
    response = requests.post(url, params=params)
    return response.ok

def get_sauna_state():
    url = "http://shellypro2-0cb815fcaff4.local/rpc/Switch.GetStatus"
    response = requests.get(url, params={"id": 0})
    return response.json().get("output", False)
```

### curl (Shell)

```bash
# Toggle
curl -X POST "http://shellypro2-0cb815fcaff4.local/rpc/Script.Eval?id=1&code=Shelly.emitEvent(%7Binfo:%7Bevent:'ha_toggle'%7D%7D)"

# Get state
curl "http://shellypro2-0cb815fcaff4.local/rpc/Switch.GetStatus?id=0" | jq '.output'
```

## Event Flow

```
┌─────────────┐
│   Toggle    │  (REST, MQTT command, Button, BLU)
│   Request   │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────────────────┐
│              PRIMARY SHELLY SCRIPT              │
│                                                 │
│  1. Receive event (ha_toggle / btn_down / etc) │
│  2. Toggle internal state                       │
│  3. Control Relay 0 (main contactor)           │
│  4. Start/stop 1-hour timer                    │
│  5. Publish state to MQTT                       │
└──────┬──────────────────────────────────────────┘
       │
       │ (Hardware sense line)
       ▼
┌─────────────────────────────────────────────────┐
│             SECONDARY SHELLY SCRIPT             │
│                                                 │
│  1. Detect primary contactor state via Input 1 │
│  2. Mirror state on Relay 0 (safety contactor) │
│  3. Run independent 1-hour safety timer         │
└─────────────────────────────────────────────────┘
```

## Error Handling

| Scenario | Expected Behavior |
|----------|-------------------|
| Device unreachable | REST calls timeout (5s default) |
| MQTT broker down | State not published, but local control works |
| Script not running | Toggle events ignored, direct relay control still works |
| Rapid toggles | Debounced (500ms) - excess events ignored |

## Rate Limits

- **Input debounce:** 500ms between toggle events
- **MQTT publish:** Every 30 seconds during active session
- **REST API:** No hard limit, but avoid rapid polling (>1/sec)
