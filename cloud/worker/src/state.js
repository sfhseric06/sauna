/**
 * Session state helpers — shared across SMS, control panel, events, and cron.
 *
 * State schema (KV key: "state"):
 * {
 *   sessionActive:    bool        — true = confirmed session in progress
 *   sessionCount:     number      — total confirmed sessions ever
 *   sessionHotSince:  ms|null     — when relay-on + temp≥90°F was first detected (cleared on cool-down)
 *   sessionEndedAt:   ms|null     — when last confirmed session ended (for gap detection)
 *   sessionStart:     ms|null     — when current confirmed session started
 *   sessionDurationS: number      — expected duration (default 3600), set by cloud command
 *   remainingS:       number      — set by primary Shelly script webhook (authoritative when fresh)
 *   ts:               ms          — when this record was last written
 * }
 *
 * Session lifecycle (all evaluated in scheduled.js with 5-min temperature data):
 *   1. Relay ON + temp ≥ 90°F   → set sessionHotSince if not set
 *   2. Hot for ≥ 20 min         → confirm session:
 *        if sessionEndedAt < 30 min ago → continuation (no count increment)
 *        else                           → new session (increment sessionCount)
 *   3. Relay OFF or temp < 90°F → clear sessionHotSince;
 *        if sessionActive → set sessionEndedAt, sessionActive=false
 *
 * remainingS priority:
 *   1. Primary script webhook value — if posted within last 2 minutes, trust it
 *   2. Computed from sessionStart   — fallback for cloud-initiated sessions
 *   3. Zero                         — session inactive or no data
 */

const SESSION_DURATION_S    = 3600;    // 60 min — matches primary script timer
const SCRIPT_FRESHNESS_MS   = 120_000; // trust script's remainingS for 2 min after last webhook
export const HOT_TEMP_F         = 90;      // °F threshold to count as a real session
export const WARMUP_MS          = 20 * 60 * 1000; // must be hot for 20 min to confirm session
export const GAP_MS             = 30 * 60 * 1000; // gap < 30 min = continuation, not new session

export function computeRemainingS(state) {
  if (!state?.sessionActive) return 0;

  // Script webhook value is authoritative when recent
  if (state.remainingS > 0 && state.ts && (Date.now() - state.ts) < SCRIPT_FRESHNESS_MS) {
    return Math.round(state.remainingS);
  }

  // Fall back to computing from sessionStart (cloud-initiated sessions)
  if (state.sessionStart) {
    const elapsedS = (Date.now() - state.sessionStart) / 1000;
    return Math.max(0, Math.round((state.sessionDurationS ?? SESSION_DURATION_S) - elapsedS));
  }

  return 0;
}

export async function readState(env) {
  const raw = await env.SAUNA_KV.get('state');
  return raw ? JSON.parse(raw) : null;
}

// Evaluate session state given current relay + temperature readings.
// Called from scheduled.js after each poll. Mutates and persists KV state.
// Returns updated state.
export async function evaluateSession(env, relayOn, indoorTempF) {
  const now   = Date.now();
  const state = await readState(env) ?? {};

  const isHot = relayOn && indoorTempF != null && indoorTempF >= HOT_TEMP_F;

  let { sessionActive, sessionCount, sessionHotSince, sessionEndedAt, sessionStart } = state;
  sessionCount = sessionCount ?? 0;

  if (isHot) {
    // Start tracking warmup window if not already
    if (!sessionHotSince) {
      sessionHotSince = now;
      console.log(`Session: hot detected (${indoorTempF}°F), warming up...`);
    }

    // Confirm session after sustained heat
    if (!sessionActive && (now - sessionHotSince) >= WARMUP_MS) {
      const isContinuation = sessionEndedAt && (now - sessionEndedAt) < GAP_MS;
      if (!isContinuation) {
        sessionCount += 1;
        console.log(`Session: confirmed new session #${sessionCount}`);
      } else {
        console.log(`Session: confirmed continuation (gap < 30 min)`);
      }
      sessionActive   = true;
      sessionStart    = sessionStart ?? now;
      sessionEndedAt  = null;
    }
  } else {
    // Relay off or cooled down — end session and reset warmup
    if (sessionActive) {
      sessionEndedAt = now;
      sessionActive  = false;
      sessionStart   = null;
      console.log(`Session: ended (relay=${relayOn}, temp=${indoorTempF}°F)`);
    }
    sessionHotSince = null;
  }

  const next = {
    ...state,
    sessionActive,
    sessionCount,
    sessionHotSince: sessionHotSince ?? null,
    sessionEndedAt:  sessionEndedAt  ?? null,
    sessionStart:    sessionStart    ?? null,
    sessionDurationS: state.sessionDurationS ?? SESSION_DURATION_S,
    ts: now,
  };

  await env.SAUNA_KV.put('state', JSON.stringify(next));
  return next;
}

// Called when sauna is turned ON via cloud command — sets relay, does not touch sessionCount.
export async function startSession(env) {
  const state = await readState(env) ?? {};
  const next = {
    ...state,
    sessionDurationS: SESSION_DURATION_S,
    remainingS:       SESSION_DURATION_S,
    ts:               Date.now(),
  };
  await env.SAUNA_KV.put('state', JSON.stringify(next));
  return next;
}

// Called when sauna is turned OFF via cloud command.
export async function endSession(env) {
  const state = await readState(env) ?? {};
  const next = {
    ...state,
    sessionActive: false,
    remainingS:    0,
    ts:            Date.now(),
  };
  await env.SAUNA_KV.put('state', JSON.stringify(next));
  return next;
}
