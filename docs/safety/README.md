# Safety Design Philosophy

## Primary Concern

**The sauna heater must NEVER be able to fail to a permanently-on state.**

An uncontrolled sauna heater poses risks of:
- Fire hazard
- Structural damage
- Extreme overheating
- Energy waste

## Defense in Depth

This system implements multiple independent layers of protection:

### Layer 1: Primary Software Timer (Primary Shelly Script)
- Maximum runtime: **1 hour**
- Enforced by `script.js` on Primary Shelly
- Timer starts when session begins
- Automatically turns off relay after timeout

### Layer 2: Secondary Software Timer (Secondary Shelly Script)
- Maximum runtime: **1 hour**
- Completely independent from Primary
- Monitors sense line from Primary contactor
- Will cut power even if Primary fails

### Layer 3: Series Contactors (Hardware)
- Two contactors wired in series
- Either device can independently cut power
- Even if one contactor welds closed, the other can still open

### Layer 4: Contactor Feedback Verification
- Secondary monitors sense lines
- Detects if contactor fails to engage (fault → shutdown)
- Detects if contactor fails to disengage (weld detection)

### Layer 5: Power-On Defaults (Firmware)
- All relays configured to default OFF on power loss
- After power outage, sauna will NOT auto-restart
- Requires explicit user action to turn on

### Layer 6: Firmware Auto-Off (Optional Backup)
- Shelly firmware supports "auto off" timer
- Can be configured as additional safety net
- Independent of script execution

### Layer 7: Max Power Protection (Secondary)
- Shelly Pro 2 PM has power monitoring
- Can trip if power exceeds threshold
- Hardware-level protection

## Failure Modes Analysis

| Failure | Mitigation |
|---------|------------|
| Primary Shelly crashes | Secondary timer still runs |
| Primary script bug | Secondary operates independently |
| Primary contactor welds | Secondary contactor still opens |
| Secondary Shelly crashes | Primary timer still active |
| Both scripts crash | Firmware auto-off (if configured) |
| Power outage | Relays default to OFF |
| Network failure | Local timers still function |
| Home Assistant down | On-device timers still function |

## What This System Does NOT Protect Against

- Both contactors welding simultaneously (extremely unlikely)
- Wiring errors (installation responsibility)
- Component degradation over time (regular testing needed)
- Deliberate bypass of safety features

## Testing Protocol

**Perform these tests periodically (recommended: monthly)**

### Test 1: Primary Timer Cutoff
1. Start sauna
2. Wait for 1 hour (or temporarily reduce `SAUNA_DURATION_MS` for testing)
3. Verify heater turns off automatically

### Test 2: Secondary Timer Cutoff
1. Disable Primary script
2. Manually close Primary contactor
3. Verify Secondary cuts off after 1 hour

### Test 3: Contactor Feedback
1. Start sauna normally
2. Check Secondary logs for "Feedback confirmed ON"
3. If no feedback, verify wiring

### Test 4: Power Loss Recovery
1. Start sauna
2. Cut power to both Shellys
3. Restore power
4. Verify sauna does NOT auto-restart

## Logging and Monitoring

Both Shellys log important events:
- Session start/stop
- Timer expirations
- Contactor feedback status
- Errors and faults

Monitor via:
- Shelly Web UI console
- MQTT messages
- Home Assistant logs

## Emergency Procedures

### Immediate Shutdown
- Press any control button to toggle off
- Or: Access Shelly Web UI → Turn off relays
- Or: Cut power at breaker

### Suspected Contactor Weld
- If sauna won't turn off via controls
- Immediately cut power at breaker
- Do NOT restore power until contactor is replaced
- Check Secondary Shelly logs for weld detection alerts
