// Shelly Script for Primary Sauna Control (Script Slot 4)
// This script manages the main contactor (Relay 0) with a 1-hour safety timer
// and reports the remaining time to KVS for Home Assistant display.

// --- Configuration Constants ---

// Unique identifier for MQTT topics (must match HA config)
let SHELLY_DEVICE_ID = "shellypro2-0cb815fcaff4"; 

// Time in milliseconds for the maximum sauna run duration
let SAUNA_DURATION_MS = 3600000; // 1 Hour
const MAX_DURATION_S = SAUNA_DURATION_MS / 1000; // Max duration in seconds
const MAIN_RELAY_ID = 0; // ID of the relay controlling the main contactor
const INDICATOR_RELAY_ID = 1; // ID of the secondary relay (likely an indicator light)

// The system instruction to show the current status to the console.
let STATUS_INSTRUCTION = "Sauna is currently ON. Safety Cutoff is backed up by Safety Device, which is entirely separate from this script";

// The specific component ID for BLU Button 1 on the paired BTHome device.
const BLU_BUTTON_1_COMPONENT = 'bthomedevice:200';
// The specific index for Button 1 within the BTHome component (usually 0).
const BLU_BUTTON_1_INDEX = 0;
// Initialization delay (milliseconds) to ensure device RPC services are ready
const INIT_DELAY_MS = 4000; 

// Event name used by the Virtual Button Action from Home Assistant (HA)
const HA_TOGGLE_EVENT = 'ha_toggle';
// The ID of the virtual switch component you created in the Shelly UI (e.g., switch:100)
const HA_VIRTUAL_SWITCH_ID = 200; 
// Interval for reporting remaining time to KVS
const REPORT_INTERVAL_MS = 30000; // 30 seconds (REDUCED FREQUENCY FOR STABILITY)

// NEW: Debounce time to prevent input spamming and RPC overload
const INPUT_DEBOUNCE_MS = 500; // 500ms delay between processing inputs

// --- State Variables ---
// Timer responsible for the current session's automatic OFF sequence
let currentOffTimer = null; 
// Flag to ensure user input is only processed after the script is fully initialized
let isControlReady = false; 

// --- CRITICAL STATE MANAGEMENT FIX ---
let isSessionActive = false; // Tracks whether the session is considered ON/running
let reportTimerId = null; // Timer for KVS reporting
// NOTE: sessionStartTime is now tracked in SECONDS (using Shelly.getUptime())
let sessionStartTime = 0; 
// NEW: Debounce flag to manage input rate limiting
let isInputDebouncing = false;

// --- MQTT Topic Definitions (NEW) ---
const TOPIC_STATE = "sauna/" + SHELLY_DEVICE_ID + "/state";
const TOPIC_TIMER = "sauna/" + SHELLY_DEVICE_ID + "/timer_raw";


/**
 * Calculates the remaining session time and reports it via MQTT.
 * Reports time in seconds. 
 */
function publishStatus() {
    let remainingS = 0;

    if (isSessionActive && sessionStartTime !== 0) {
        // CRITICAL FIX: Calculate elapsed time using Shelly.getUptime() (in seconds)
        // This is a reliable monotonic counter that does not require NTP synchronization.
        let elapsedS = Math.floor(getUptime() - sessionStartTime);
        remainingS = MAX_DURATION_S - elapsedS;
        if (remainingS < 0) remainingS = 0;
    }
    
    // --- DEBUGGING STATEMENTS ---
    print("DEBUG Timer: Elapsed S:", Math.floor(getUptime() - sessionStartTime));
    print("DEBUG Timer: Remaining S:", Math.round(remainingS));
    // ---------------------------

    // Publish remaining time via MQTT
    let timePayload = JSON.stringify(Math.round(remainingS));
    MQTT.publish(TOPIC_TIMER, timePayload, 1, true); // QoS 1, Retain True

    // Publish ON/OFF state via MQTT (this is the key state for HA)
    let statePayload = JSON.stringify(isSessionActive);
    MQTT.publish(TOPIC_STATE, statePayload, 1, true); // QoS 1, Retain True

    print("MQTT Status Published: State=", isSessionActive, " Time=", Math.round(remainingS), "s");
}


function getUptime() {
    // Get uptime in seconds from the system component status
    return Shelly.getComponentStatus("sys").uptime
}
// --- RELAY CONTROL ---



/**
 * Executes the command to turn the Primary Relay ON or OFF, and reports success via a callback.
 * * CRITICAL FIX: The three RPC calls are now chained sequentially using callbacks 
 * to prevent the "Too many calls in progress" error.
 * * @param {boolean} turnOn - true to turn ON, false to turn OFF.
 * * @param {function(boolean)} finalCallback - Function to execute when RPC chain completes, 
 * takes 'true' on success, 'false' on failure.
 */
function setPrimaryRelay(turnOn, finalCallback) {
    let mainCommand = { id: MAIN_RELAY_ID, on: turnOn };
    let indicatorCommand = { id: INDICATOR_RELAY_ID, on: turnOn };
    let action = turnOn ? "ACTIVATED" : "DEACTIVATED";
    
    /**
     * Step 3: Turn on/off the second output (indicator light)
     */
    function setIndicatorRelay() {
        Shelly.call('Switch.Set', indicatorCommand, function(result, error_code, error_message) {
            if (error_code === 0) {
                print("Relay " + result.id + " " + action);
                // SUCCESS: Final step succeeded, publish the state
                MQTT.publish(TOPIC_STATE, JSON.stringify(turnOn), 1, true); 
                finalCallback(true); // REPORT SUCCESS to the caller
            } else {
                print("ERROR controlling indicator relay (Switch.Set failed). Code:", error_code, "Error:", error_message);
                // FAILURE: Do NOT publish the state.
                finalCallback(false); // REPORT FAILURE to the caller
            }
        });
    }

    /**
     * Step 2: Close/Open the primary contactor
     */
    function setMainRelay() {
        Shelly.call('Switch.Set', mainCommand, function(result, error_code, error_message) {
            if (error_code === 0) {
                print("Relay " + result.id + " " + action);
                if (turnOn && result.id === MAIN_RELAY_ID) {
                    print(STATUS_INSTRUCTION);
                }
                // SUCCESS: Move to the next step
                setIndicatorRelay();
            } else {
                print("ERROR controlling main relay (Switch.Set failed). Code:", error_code, "Error:", error_message);
                // FAILURE: Stop the chain and prevent subsequent MQTT publish
                finalCallback(false); // REPORT FAILURE to the caller
            }
        });
    }
    
    // Step 1: Start the relay control chain
    setMainRelay();
}

/**
 * Stops the current operating timer and sets the Primary Relay to OFF.
 * Internal state and timers are only cleared if the relays successfully switch off.
 */
function stopAndTurnOff() {
    print("Attempting to stop session and turn Primary Relay OFF.");
    
    // 4. Attempt to turn off relays
    setPrimaryRelay(false, function(success) {
        if (!success) {
            print("Deactivation failed due to relay error. Internal state remains ON (Running).");
            // If relays fail to turn off, we leave isSessionActive=true and timers running
            // to re-attempt turn-off on next tick or user interaction.
            return;
        }
        
        // --- RELAY SUCCESS LOGIC (moved here) ---
        print("Session successfully ended. Clearing internal state and timers.");
        
        // 1. Clear main session timer
        if (currentOffTimer) {
            Timer.clear(currentOffTimer);
            currentOffTimer = null;
        }
        
        // 2. Clear reporting timer
        if (reportTimerId) {
            Timer.clear(reportTimerId);
            reportTimerId = null;
        }
        
        // 3. CRITICAL STATE UPDATE (NOW HAPPENS HERE)
        isSessionActive = false;
        sessionStartTime = 0; // Reset start time
        
        // Report final 0 status to MQTT
        publishStatus();
    });
}

/**
 * Starts a new session timer and activates the Primary Relay.
 * Internal state and timers are only set if the relays successfully switch on.
 */
function startSession() {
    // 1. Clear any existing main timer (safeguard)
    if (currentOffTimer) {
        Timer.clear(currentOffTimer);
    }
    
    // 3. Attempt to activate the Primary Relay (which signals/powers the Safety Device)
    setPrimaryRelay(true, function(success) {
        if (!success) {
            print("Activation failed due to relay error. Internal state remains OFF.");
            return;
        }

        // --- RELAY SUCCESS LOGIC (moved here) ---
        let now = getUptime();
        
        // Double check that uptime returns a positive number, though it should always.
        if (typeof now !== 'number' || now <= 0) {
            print("CRITICAL ERROR: Shelly.getUptime() returned invalid time. Session aborted after successful relay switch.");
            // We can't safely proceed with the timer, even though the relay is on.
            return; 
        }

        // 2. CRITICAL STATE UPDATE (NOW HAPPENS HERE)
        isSessionActive = true;
        sessionStartTime = now; // Record exact start time in SECONDS
        
        // 4. Set the new timer for the sauna duration (e.g., 1 hour)
        let durationMinutes = (SAUNA_DURATION_MS / 60000).toFixed(1);
        print("Starting session timer for " + durationMinutes + " minutes.");

        // Shelly Timer takes duration in milliseconds. The 'false' argument means the timer runs once.
        currentOffTimer = Timer.set(SAUNA_DURATION_MS, false, stopAndTurnOff);
        
        // 5. Start the MQTT reporting timer
        if (reportTimerId) Timer.clear(reportTimerId);
        publishStatus(); // Initial report
        reportTimerId = Timer.set(REPORT_INTERVAL_MS, true, publishStatus); 
    });
}

/**
 * Handles a single button press (Physical Input, BLU Button, or HA Webhook).
 * Toggles the sauna state (ON if OFF, OFF if ON).
 */
function handleToggle() {
    // 1. RATE LIMITING: If currently debouncing (input spamming), IGNORE the event.
    if (isInputDebouncing) {
        print("Input ignored: Debouncing in progress.");
        return;
    }

    // CONTROL FLAG: If the script is not yet ready, ignore the input event
    if (!isControlReady) {
        print("Control script not fully initialized. Ignoring input.");
        return;
    }
    
    // 2. START DEBOUNCE: Lock the input processing flag
    isInputDebouncing = true;
    // Set a timer to unlock the input flag after the debounce interval
    Timer.set(INPUT_DEBOUNCE_MS, false, function() {
        isInputDebouncing = false;
        print("Input debounce finished. Ready for next input.");
    });
    
    // 3. EXECUTE TOGGLE LOGIC: 
    // We rely on isSessionActive as the definitive state now.
    if (isSessionActive) {
        print("Sauna is currently ON. User click detected: Turning OFF.");
        stopAndTurnOff();
    } else {
        // If the timer is null, the sauna is OFF.
        print("Sauna is currently OFF. User click detected: Turning ON.");
        startSession();
    }
}

function initializeControl() {
    // --- Event Handler (Triggered by physical switch, BTHome, or HA) ---

    Shelly.addEventHandler(function(event) {
        
        // 1. Check for Physical Input (input:0) using the standard 'btn_down' event
        let isPhysicalInputTrigger = (event.component === 'input:0' && event.info.event === 'btn_down');
        
        // 2. Check for Paired BTHome Device (BLU Button 1 only)
        let isBTHomeButton1Trigger = (
            event.component === BLU_BUTTON_1_COMPONENT && 
            event.info.event === 'single_push' &&
            event.info.idx === BLU_BUTTON_1_INDEX
        );

        // 3. Check for Home Assistant RPC/Eval injection (using the confirmed event property)
        let isHATrigger = (event.info.event === HA_TOGGLE_EVENT);

        // Trigger if ANY of the allowed inputs/events occur
        let isTriggerEvent = isPhysicalInputTrigger || isBTHomeButton1Trigger || isHATrigger;

        if (isTriggerEvent) {
            
            // Log the source of the event for debugging
            if (isBTHomeButton1Trigger) {
                print("Click registered from BLU Button 1 (" + event.component + ").");
            } else if (isPhysicalInputTrigger) {
                print("Click registered from physical input (" + event.component + ").");
            } else if (isHATrigger) {
                print("Click registered from VIRTUAL input (HA Toggle).");

            }
            
            // Handle the toggle action only when the control system is ready
            handleToggle();
        }
    });

    // Mark the control system as fully ready to process events
    isControlReady = true;
    print("Primary Control Script Initialized and ready to process input.");

    publishStatus(); 
}

// Start the initialization process after a short delay to allow device services to boot up.
print("Primary Control Script starting initialization sequence with a " + INIT_DELAY_MS + "ms delay...");
Timer.set(INIT_DELAY_MS, false, initializeControl);
