# Troubleshooting Guide

## Quick Diagnostics

### Check Device Status
```bash
# Primary Shelly
curl "http://shellypro2-0cb815fcaff4.local/rpc/Shelly.GetStatus"

# Secondary Shelly
curl "http://shellypro2-0cb815fc96dc.local/rpc/Shelly.GetStatus"
```

### Check Script Status
```bash
# Primary script
curl "http://shellypro2-0cb815fcaff4.local/rpc/Script.GetStatus?id=1"

# Secondary script
curl "http://shellypro2-0cb815fc96dc.local/rpc/Script.GetStatus?id=1"
```

---

## Common Issues

### Sauna Won't Turn On

**Symptoms:** Button press does nothing, no relay click

**Check:**
1. **Is the Primary script running?**
   ```bash
   curl "http://shellypro2-0cb815fcaff4.local/rpc/Script.GetStatus?id=1"
   ```
   Look for `"running": true`

2. **Is Input 0 detecting the button?**
   - Check Shelly Web UI → Inputs section
   - Press button and watch for state change

3. **Is the script initialized?**
   - Check script console for "Primary Control Script Initialized"
   - Script has 4-second init delay on boot

4. **Check for debounce lockout:**
   - Script ignores rapid button presses
   - Wait 1 second and try again

### Sauna Won't Turn Off

**Symptoms:** Button press doesn't stop sauna, timer doesn't work

**IMMEDIATE ACTION:** Cut power at breaker if sauna won't respond

**Check:**
1. **Is `isSessionActive` true?**
   - Check script console output

2. **Is the relay actually stuck?**
   - Check Shelly Web UI → Relays section
   - Try manually toggling via UI

3. **Contactor may be welded:**
   - If software says OFF but heater runs
   - Cut power immediately
   - Replace contactor

### Timer Shows Wrong Value

**Symptoms:** Home Assistant shows incorrect remaining time

**Check:**
1. **Is MQTT connected?**
   ```bash
   mosquitto_sub -h YOUR_BROKER -t "sauna/shellypro2-0cb815fcaff4/timer_raw" -v
   ```

2. **Is KVS being updated?**
   ```bash
   curl "http://shellypro2-0cb815fcaff4.local/rpc/KVS.Get?key=sauna_remaining_time"
   ```

3. **Check `sessionStartTime`:**
   - Script uses `Shelly.getUptime()` for timing
   - If device rebooted mid-session, timing may be off

### Home Assistant Toggle Doesn't Work

**Symptoms:** HA button does nothing

**Check:**
1. **Test REST command directly:**
   ```bash
   curl -X POST "http://shellypro2-0cb815fcaff4.local/rpc/Script.Eval?id=1&code=Shelly.emitEvent({info:{event:'ha_toggle'}})"
   ```

2. **Check HA logs for errors:**
   - Developer Tools → Logs
   - Look for REST command failures

3. **Verify device is reachable:**
   ```bash
   ping shellypro2-0cb815fcaff4.local
   ```

4. **mDNS issues?**
   - Try using IP address instead of `.local` hostname
   - Update URLs in `sauna_system.yaml`

### BLU Button Doesn't Work

**Symptoms:** Bluetooth button presses ignored

**Check:**
1. **Is BTHome device paired?**
   - Check Shelly Web UI → BTHome section

2. **Check component ID:**
   - Script expects `bthomedevice:200`
   - Verify actual component ID in UI
   - Update script if different

3. **Check button index:**
   - Script expects `idx: 0` for Button 1
   - Multi-button devices may use different indexes

### Secondary Safety Fault

**Symptoms:** Secondary shuts down unexpectedly

**Check script console for:**

- **"Secondary Contactor (SW1) did not engage"**
  - Contactor failed to close
  - Check wiring to safety contactor
  - Check contactor coil/mechanism

- **"Primary contactor welded"**
  - SW2 stayed HIGH for >1hr 5min
  - Primary contactor may be stuck closed
  - **Do not restore power until fixed**

### Both Devices Can't Communicate

**Symptoms:** Secondary doesn't follow Primary

**Note:** The devices communicate via HARDWARE sense lines, not network.

**Check:**
1. **Wiring to sense inputs:**
   - SW2 (Secondary Input 1) should sense Primary contactor output
   
2. **Input configuration:**
   - Inputs should NOT be "detached"
   - Mode should be "Switch"

---

## Diagnostic Commands

### Full Status Dump
```bash
# Save complete device status
curl "http://shellypro2-0cb815fcaff4.local/rpc/Shelly.GetStatus" | jq . > primary-status.json
curl "http://shellypro2-0cb815fc96dc.local/rpc/Shelly.GetStatus" | jq . > secondary-status.json
```

### Check Relay States
```bash
curl "http://shellypro2-0cb815fcaff4.local/rpc/Switch.GetStatus?id=0"  # Main contactor
curl "http://shellypro2-0cb815fcaff4.local/rpc/Switch.GetStatus?id=1"  # Indicator
curl "http://shellypro2-0cb815fc96dc.local/rpc/Switch.GetStatus?id=0"  # Safety contactor
```

### Check Input States
```bash
curl "http://shellypro2-0cb815fcaff4.local/rpc/Input.GetStatus?id=0"  # RC Button
curl "http://shellypro2-0cb815fc96dc.local/rpc/Input.GetStatus?id=0"  # SW1 (secondary sense)
curl "http://shellypro2-0cb815fc96dc.local/rpc/Input.GetStatus?id=1"  # SW2 (primary sense)
```

### View Script Console (Recent Output)
```bash
# Via WebSocket - use browser dev tools or wscat
wscat -c ws://shellypro2-0cb815fcaff4.local/debug/log
```

### Force Relay Off (Emergency)
```bash
# Primary main contactor
curl "http://shellypro2-0cb815fcaff4.local/rpc/Switch.Set?id=0&on=false"

# Secondary safety contactor
curl "http://shellypro2-0cb815fc96dc.local/rpc/Switch.Set?id=0&on=false"
```

---

## Recovery Procedures

### Script Won't Start
1. Check for syntax errors in Web UI
2. Re-upload script from this repo
3. Ensure "Run on startup" is enabled
4. Reboot device

### Factory Reset (Last Resort)
1. **Backup settings first!**
2. Hold device button for 10+ seconds
3. Reconfigure all settings from this repo's documentation
4. Re-upload scripts

### After Power Outage
1. Verify both devices are online
2. Check scripts are running
3. Verify relay states are OFF
4. Test toggle function before use
