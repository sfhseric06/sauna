// =============================================================================
// SAUNA SECONDARY CONTROLLER SCRIPT
// =============================================================================
// Managed by git - source: devices/shelly-secondary/script.js
// Deploy with: ./scripts/deploy-secondary.sh
// Version: 1.0.0
//
// Responsibilities:
//   - Series safety contactor - closes only when primary contactor is engaged
//   - 1-hour max-duration auto-off (independent of primary)
//   - Weld fault detection: if primary stays on >65 min after auto-off, cuts power
//   - Boot-state recovery: resumes safety sequence if rebooted while sauna running
// =============================================================================

const SCRIPT_VERSION = "1.0.0";

// --- Configuration Constants (Secondary Device) ---
// Relay ID for the Safety Contactor (Channel 0 of the Pro 2 PM)
const SAFETY_RELAY_ID = 0;
// Input SW2: Senses Primary Contactor Output (Sensing high means Primary is ON)
const PRIMARY_OUTPUT_SENSE_INPUT = 'input:1';
// Input SW1: Senses Secondary Contactor Output (Sensing high means BOTH are ON)
const SECONDARY_OUTPUT_SENSE_INPUT = 'input:0';

// Safety Contactor check timeout (1 second for immediate engagement feedback)
const SAFETY_CONTACTOR_CHECK_MS = 1000;
// Max session duration (1 hour) for the secondary safety relay
const SAFETY_MAX_DURATION_MS = 3600000; // 1 hour

// CRITICAL WELD CHECK THRESHOLD: 1 hour and 5 minutes (3600000ms + 300000ms)
// If SW2 remains high this long, the Primary is welded.
const WELD_FAULT_THRESHOLD_MS = 3900000;

// --- State Variables ---
let safetyTimer = null; // Max duration timer (1 hour)
let weldFaultTimerId = null; // Single-shot timer for the 1hr 5min weld check
let isSafetyRelayOn = false;

// --- Core Safety Functions ---

/**
 * Sets the state of the Secondary (Safety) Relay and updates the local state flag.
 * @param {boolean} turnOn - true to turn ON, false to turn OFF.
 */
function setSafetyRelay(turnOn) {
    let command = {
        id: SAFETY_RELAY_ID,
        on: turnOn,
    };

    Shelly.call('Switch.Set', command, function(result, error_code, error_message) {
        if (error_code === 0) {
            isSafetyRelayOn = turnOn;
            print("Safety Relay " + (turnOn ? "ACTIVATED" : "DEACTIVATED"));
        } else {
            print("CRITICAL ERROR: Failed to control Safety Relay. Code:", error_code, "Error:", error_message);
            // If we attempted to turn ON and failed, try to shut it down again (fail-safe)
            if (turnOn) {
                setSafetyRelay(false);
            }
        }
    });
}

/**
 * Checks if the secondary contactor (SW1) engaged after the safety relay was turned on.
 * Called 1 second after turning on the safety relay.
 */
function checkContactorFeedback() {
    Shelly.call('Input.GetStatus', { id: 0 }, function(result) {
        if (result && result.state === false) {
            print("!!! CRITICAL SAFETY FAULT !!! Secondary Contactor (SW1) did not engage.");
            setSafetyRelay(false);
            if (weldFaultTimerId) {
                Timer.clear(weldFaultTimerId);
                weldFaultTimerId = null;
            }
        } else {
            print("Safety Contactor Feedback (SW1) confirmed ON within 1 second.");
        }
    });
}

/**
 * Executes the Weld Fault Shutdown. Called only by the WELD_FAULT_THRESHOLD_MS timer.
 */
function checkLongRunWeldFault() {
    print("!!! CRITICAL WELD FAILURE DETECTED !!!");
    print("Primary Output (SW2) has been continuously HIGH for " + (WELD_FAULT_THRESHOLD_MS / 60000).toFixed(1) + " minutes.");
    print("Initiating Safety Shutdown due to Confirmed Primary Weld Fault.");
    setSafetyRelay(false);
    weldFaultTimerId = null;
}


// --- Main Control Logic ---

/**
 * Starts the Safety Contactor Sequence when the Primary Contactor engages (SW2 goes HIGH).
 */
function handlePrimaryOn() {
    print("Primary Contactor engaged (SW2 HIGH). Starting Safety Sequence.");

    // 1. Turn on the Safety Contactor
    setSafetyRelay(true);

    // 2. Start the immediate feedback check (SW1 must go HIGH within 1 second)
    Timer.set(SAFETY_CONTACTOR_CHECK_MS, false, checkContactorFeedback);

    // 3. Start the 1-hour maximum duration timer
    if (safetyTimer) Timer.clear(safetyTimer);
    safetyTimer = Timer.set(SAFETY_MAX_DURATION_MS, false, function() {
        print("Safety Max Duration reached. Shutting down Safety Relay.");
        setSafetyRelay(false);
        safetyTimer = null;
        // IMPORTANT: Do NOT clear weldFaultTimerId here. Let it keep running for 5 more
        // minutes to detect whether the Primary contactor is welded (SW2 stays HIGH).
        // handlePrimaryOff will clear it if the Primary turns off normally.
    });

    // 4. Start the weld fault timer (fires 65 min after Primary turns on)
    if (weldFaultTimerId) Timer.clear(weldFaultTimerId);
    print("Starting weld fault detection timer for " + (WELD_FAULT_THRESHOLD_MS / 60000).toFixed(1) + " minutes.");
    weldFaultTimerId = Timer.set(WELD_FAULT_THRESHOLD_MS, false, checkLongRunWeldFault);
}

/**
 * Handles the Primary Contactor turning OFF (SW2 goes LOW).
 * Shuts down the Safety Contactor and clears all dependent timers.
 */
function handlePrimaryOff() {
    print("Primary Contactor disengaged (SW2 LOW). Shutting down Safety Sequence.");

    if (safetyTimer) {
        Timer.clear(safetyTimer);
        safetyTimer = null;
    }
    // Primary turned off normally - no weld, cancel the weld check.
    if (weldFaultTimerId) {
        Timer.clear(weldFaultTimerId);
        weldFaultTimerId = null;
    }

    setSafetyRelay(false);
}


// --- Event Listener ---
function init() {
    // Monitor input:1 (SW2, wired to Primary Output) for state transitions.
    Shelly.addEventHandler(function(event) {
        if (event.component !== PRIMARY_OUTPUT_SENSE_INPUT) return;

        if (event.info.state === true) {
            handlePrimaryOn();
        } else if (event.info.state === false) {
            handlePrimaryOff();
        }
    });

    // Boot-state recovery: if SW2 is already HIGH when we start (e.g. secondary rebooted
    // while sauna was running), immediately start the safety sequence. Without this, the
    // safety relay would stay off until the next SW2 transition.
    Shelly.call('Input.GetStatus', { id: 1 }, function(result) {
        if (result && result.state === true) {
            print("Boot: SW2 already HIGH - sauna was running before reboot. Starting Safety Sequence.");
            handlePrimaryOn();
        } else {
            print("Boot: SW2 LOW. Sauna is off.");
        }
    });

    print("Secondary Safety Logic Initialized. Version:", SCRIPT_VERSION, "- Monitoring SW2 for Primary Contactor state.");
}

init();
