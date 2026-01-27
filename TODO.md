# Sauna Project - TODO

## CRITICAL: Safety Script Gaps

**Priority: HIGH - Complete before relying on system**

### Secondary Script is INCOMPLETE

The file `devices/shelly-secondary/script.js` cuts off at line 71 mid-function. Missing:

- [ ] **Independent 1-hour timer** - Start when SW2 (Primary sense) goes HIGH
- [ ] **Weld detection logic** - If SW2 stays HIGH > 65 min after safety relay turns OFF, primary contactor is welded
- [ ] **Complete feedback verification** - Verify SW1 goes HIGH within 1 second of engaging relay
- [ ] **State reporting** - Publish safety status to MQTT for HA monitoring

**Current safety coverage without complete secondary script:**
```
Primary Timer (script) → 60 min
        ↓ (if fails)
Secondary Timer (script) → BROKEN ❌
        ↓ (if fails)  
Firmware Auto-Off → 61 min ✅ (last resort)
```

### Primary Script Improvements

- [ ] **Add retry logic to `stopAndTurnOff()`** - If RPC fails, currently no retry; state stuck "ON"
- [ ] **Add watchdog heartbeat** - Periodic "I'm alive" to MQTT for crash detection

### Verify Firmware Safety Settings

Run on live device to confirm firmware backup is configured:
```bash
curl "http://shellypro2-0cb815fc96dc.local/rpc/Switch.GetConfig?id=0"
```
Verify: `auto_off: true`, `auto_off_delay: 3660`

---

## Home Assistant Integration Issues

See detailed analysis in: `../homeassistant_sauna_config/TODO.md`

**Summary of HA issues:**
1. Toggle method may be broken (Button.Trigger vs ha_toggle event)
2. Secondary Shelly (safety) not monitored
3. No device availability monitoring
4. No MQTT fallback polling
5. Schedule duration not implemented
6. LED strip not integrated

---

## WiFi Connectivity

**Status:** All devices have weak WiFi signal (-76 to -80 dBm)

**Diagnostic tools created:**
- `scripts/check-health.sh` - Quick status check
- `scripts/monitor-wifi.sh` - Continuous monitoring with CSV log
- `scripts/diagnose-device.sh` - Full device diagnostics
- `scripts/diagnose-all.sh` - All devices at once
- `scripts/network-debug.sh` - Deep network troubleshooting

**Solutions to consider:**
1. Add WiFi extender/mesh node near sauna
2. Use Shelly Pro 2 ethernet port
3. Assign static IPs via DHCP reservation

---

## Script Improvements

### Primary Script (`devices/shelly-primary/script.js`)

- [ ] Add handler for Virtual Button 200 events (if keeping Button.Trigger method)
- [ ] Or document that Script.Eval with `ha_toggle` is the canonical method

### Secondary Script (`devices/shelly-secondary/script.js`)

- [ ] Script is incomplete (noted in conversation history)
- [ ] Need to complete safety logic implementation

---

## Documentation

- [ ] Clarify canonical toggle method in `docs/api.md`
- [ ] Remove KVS references (not used, MQTT only)
- [ ] Ensure script, HA config, and API docs all agree

---

## Git Commits

- [x] Initial commit for `sauna` repo ✅ Pushed
- [x] Initial commit for `homeassistant_sauna_config` repo ✅ Pushed
