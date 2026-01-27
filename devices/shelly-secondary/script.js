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
 * Checks if the secondary contactor (SW1) engaged after the safety relay (Output 1) was turned on.
 * Called 1 second after turning on the safety relay.
 * This is a check on the *Secondary* contactor, not the Primary weld check.
 */
function checkContactorFeedback() {
    // Check input:0 (SW1) status
    Shelly.call('Input.GetStatus', { id: 0 }, function(result) {
        // result.state corresponds to the state of input:0 (SW1)
        if (result && result.state === false) {
            print("!!! CRITICAL SAFETY FAULT !!! Secondary Contactor (SW1) did not engage.");
            setSafetyRelay(false); // Immediately shut down the safety relay
            // Stop the long-run weld timer as we are shutting down
            if (weldFaultTimerId) Timer.clear(weldFaultTimerId);
            
            // TODO: Add notification logic (e.g., set an auxiliary output or flash lights)
        } else {
            print("Safety Contactor Feedback (SW1) confirmed ON within 1 second.");
        }
    });
}

/**
