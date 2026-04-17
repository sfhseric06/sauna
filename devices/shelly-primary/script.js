// =============================================================================
// SAUNA PRIMARY CONTROLLER SCRIPT
// =============================================================================
// Managed by git - source: devices/shelly-primary/script.js
// Deploy with: ./scripts/deploy-primary.sh  (substitutes WORKER_URL/SECRET)
// Version: 1.1.4
//
// Responsibilities:
//   - 1-hour session timer with automatic shutoff
//   - MQTT state publishing for Home Assistant
//   - Cloud Worker webhook for SMS/dashboard/Grafana
//   - Toggle from: physical button, BLU RC button, HA virtual button
//   - External relay sync: detects relay changes from any source (cloud control
//     panel, HA direct, etc.) and keeps session tracking in sync
// =============================================================================

const SCRIPT_VERSION = "1.1.4";

// --- Configuration ---

const SHELLY_DEVICE_ID      = "shellypro2-0cb815fcaff4";
const SAUNA_DURATION_MS     = 3600000;           // 1 hour
const MAX_DURATION_S        = SAUNA_DURATION_MS / 1000;
const MAIN_RELAY_ID         = 0;                 // Main contactor
const INDICATOR_RELAY_ID    = 1;                 // Indicator light
const BLU_BUTTON_1_COMPONENT = 'bthomedevice:200';
const BLU_BUTTON_1_INDEX    = 0;
const INIT_DELAY_MS         = 4000;
const HA_TOGGLE_EVENT       = 'ha_toggle';
const REPORT_INTERVAL_MS    = 30000;             // 30 sec MQTT publish cadence
const INPUT_DEBOUNCE_MS     = 500;

// Replaced at deploy time by deploy-primary.sh
const WORKER_URL    = "__WORKER_URL__";
const WORKER_SECRET = "__WORKER_SECRET__";

// --- MQTT topics ---
const TOPIC_STATE = "sauna/" + SHELLY_DEVICE_ID + "/state";
const TOPIC_TIMER = "sauna/" + SHELLY_DEVICE_ID + "/timer_raw";

// --- State ---
let isSessionActive    = false;
let sessionStartTime   = 0;       // uptime seconds at session start
let currentOffTimer    = null;
let reportTimerId      = null;
let isControlReady     = false;
let isInputDebouncing  = false;
let isScriptControlling = false;  // true while script's own Switch.Set calls are in flight

// --- Helpers ---

function getUptime() {
    return Shelly.getComponentStatus("sys").uptime;
}

// --- Status publishing ---

// Publishes current state to MQTT and the cloud Worker.
// Called on session start/stop, every 30 sec during a session, and on boot.
function publishStatus() {
    let remainingS = 0;
    if (isSessionActive && sessionStartTime !== 0) {
        remainingS = MAX_DURATION_S - Math.floor(getUptime() - sessionStartTime);
        if (remainingS < 0) remainingS = 0;
    }

    MQTT.publish(TOPIC_TIMER, JSON.stringify(Math.round(remainingS)), 1, true);
    MQTT.publish(TOPIC_STATE, JSON.stringify(isSessionActive), 1, true);
    print("Status: active=", isSessionActive, " remaining=", Math.round(remainingS), "s  version=", SCRIPT_VERSION);

    Shelly.call("HTTP.POST", {
        url: WORKER_URL + "/event",
        content_type: "application/json",
        body: JSON.stringify({
            secret:        WORKER_SECRET,
            sessionActive: isSessionActive,
            remainingS:    Math.round(remainingS),
            uptimeS:       Math.round(getUptime()),
        }),
    }, function(result, error_code) {
        if (error_code !== 0) print("Worker webhook failed (non-critical):", error_code);
    });
}

// --- Relay control ---

// Sets both relays (main contactor + indicator) in sequence.
// Calls finalCallback(true) on success, finalCallback(false) on any failure.
// Sets isScriptControlling while in flight so the status handler ignores our own changes.
function setPrimaryRelay(turnOn, finalCallback) {
    isScriptControlling = true;
    let mainCmd      = { id: MAIN_RELAY_ID,      on: turnOn };
    let indicatorCmd = { id: INDICATOR_RELAY_ID, on: turnOn };
    let action       = turnOn ? "ON" : "OFF";

    function done(success) {
        isScriptControlling = false;
        finalCallback(success);
    }

    function setIndicator() {
        Shelly.call('Switch.Set', indicatorCmd, function(result, error_code, error_message) {
            if (error_code === 0) {
                print("Indicator relay", action);
                done(true);
            } else {
                print("ERROR: indicator relay failed:", error_code, error_message);
                done(false);
            }
        });
    }

    Shelly.call('Switch.Set', mainCmd, function(result, error_code, error_message) {
        if (error_code === 0) {
            print("Main relay", action);
            setIndicator();
        } else {
            print("ERROR: main relay failed:", error_code, error_message);
            done(false);
        }
    });
}

// --- Session management ---

function startSession() {
    if (currentOffTimer) Timer.clear(currentOffTimer);

    setPrimaryRelay(true, function(success) {
        if (!success) {
            print("Activation failed - relay error. State remains OFF.");
            return;
        }
        let now = getUptime();
        if (typeof now !== 'number' || now <= 0) {
            print("CRITICAL: invalid uptime. Session aborted.");
            return;
        }
        isSessionActive  = true;
        sessionStartTime = now;
        currentOffTimer  = Timer.set(SAUNA_DURATION_MS, false, stopAndTurnOff);
        if (reportTimerId) Timer.clear(reportTimerId);
        publishStatus();
        reportTimerId = Timer.set(REPORT_INTERVAL_MS, true, publishStatus);
        print("Session started. Timer:", SAUNA_DURATION_MS / 60000, "min");
    });
}

function stopAndTurnOff() {
    print("Stopping session.");
    setPrimaryRelay(false, function(success) {
        if (!success) {
            print("Deactivation failed - relay error. Retrying on next tick.");
            return;
        }
        if (currentOffTimer) { Timer.clear(currentOffTimer); currentOffTimer = null; }
        if (reportTimerId)   { Timer.clear(reportTimerId);   reportTimerId   = null; }
        isSessionActive  = false;
        sessionStartTime = 0;
        publishStatus();
        print("Session ended.");
    });
}

// Sync session tracking when relay was changed externally (cloud control panel,
// HA direct control, etc.) without going through this script's toggle.
function syncExternalRelayOn() {
    print("Relay ON detected externally - syncing session state.");
    isSessionActive  = true;
    sessionStartTime = getUptime();
    if (currentOffTimer) Timer.clear(currentOffTimer);
    currentOffTimer = Timer.set(SAUNA_DURATION_MS, false, stopAndTurnOff);
    if (reportTimerId) Timer.clear(reportTimerId);
    // Mirror indicator light (relay 1) - status handler only watches switch:0 so no double-trigger
    Shelly.call('Switch.Set', { id: INDICATOR_RELAY_ID, on: true }, null);
    publishStatus();
    reportTimerId = Timer.set(REPORT_INTERVAL_MS, true, publishStatus);
}

function syncExternalRelayOff() {
    print("Relay OFF detected externally - syncing session state.");
    if (currentOffTimer) { Timer.clear(currentOffTimer); currentOffTimer = null; }
    if (reportTimerId)   { Timer.clear(reportTimerId);   reportTimerId   = null; }
    isSessionActive  = false;
    sessionStartTime = 0;
    Shelly.call('Switch.Set', { id: INDICATOR_RELAY_ID, on: false }, null);
    publishStatus();
}

// --- Toggle handler ---

function handleToggle() {
    if (isInputDebouncing) { print("Ignored: debouncing."); return; }
    if (!isControlReady)   { print("Ignored: not ready."); return; }

    isInputDebouncing = true;
    Timer.set(INPUT_DEBOUNCE_MS, false, function() { isInputDebouncing = false; });

    if (isSessionActive) {
        print("Toggle: ON -> OFF");
        stopAndTurnOff();
    } else {
        print("Toggle: OFF -> ON");
        startSession();
    }
}

// --- Initialization ---

function initializeControl() {
    // Watch for relay state changes from ANY source (script, cloud, HA, firmware auto-off).
    // isScriptControlling gates out our own Switch.Set calls to prevent double-triggering.
    Shelly.addStatusHandler(function(status) {
        if (!isControlReady)     return;
        if (isScriptControlling) return;
        if (status.component !== 'switch:0') return;
        if (!status.delta || status.delta.output === undefined) return;

        let relayOn = status.delta.output;
        if (relayOn && !isSessionActive) {
            syncExternalRelayOn();
        } else if (!relayOn && isSessionActive) {
            syncExternalRelayOff();
        }
    });

    // Watch for toggle events from physical button, BLU remote, and HA.
    Shelly.addEventHandler(function(event) {
        let isPhysical = (event.component === 'input:0' && event.info.event === 'btn_down');
        let isBLU      = (event.component === BLU_BUTTON_1_COMPONENT &&
                          event.info.event === 'single_push' &&
                          event.info.idx === BLU_BUTTON_1_INDEX);
        let isHA       = (event.component === 'button:200' && event.info.event === 'single_push') ||
                         (event.info.event === HA_TOGGLE_EVENT);

        if (isPhysical || isBLU || isHA) {
            let source = isPhysical ? "physical button" : isBLU ? "BLU remote" : "HA toggle";
            print("Toggle from:", source);
            handleToggle();
        }
    });

    isControlReady = true;
    print("Primary script ready. Version:", SCRIPT_VERSION);
    publishStatus();
}

print("Primary script v" + SCRIPT_VERSION + " - init in " + INIT_DELAY_MS + "ms");
Timer.set(INIT_DELAY_MS, false, initializeControl);
