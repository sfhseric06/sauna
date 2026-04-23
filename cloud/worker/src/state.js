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
 *   sessionPeakTempF: number|null — highest indoor temp recorded during current session
 *   sessionDurationS: number      — expected duration (default 3600), set by cloud command
 *   remainingS:       number      — set by primary Shelly script webhook (authoritative when fresh)
 *   ts:               ms          — when this record was last written
 * }
 *
 * Leaderboard schema (KV key: "leaderboard"):
 * {
 *   entries: [
 *     { session: number, peakTempF: number, date: "YYYY-MM-DD" },
 *     ...
 *   ]  — all sessions, sorted by peakTempF descending
 * }
 *
 * Session lifecycle (all evaluated in scheduled.js with 5-min temperature data):
 *   1. Relay ON + temp ≥ 90°F   → set sessionHotSince if not set
 *   2. Hot for ≥ 20 min         → confirm session:
 *        if sessionEndedAt < 30 min ago → continuation (no count increment)
 *        else                           → new session (increment sessionCount)
 *   3. While active: track sessionPeakTempF (max of all readings)
 *   4. Relay OFF or temp < 90°F → save peak temp to leaderboard, clear sessionHotSince
 */

const SESSION_DURATION_S  = 3600;           // 60 min — matches primary script timer
const SCRIPT_FRESHNESS_MS = 120_000;        // trust script's remainingS for 2 min after last webhook
export const HOT_TEMP_F   = 90;             // °F threshold to count as a real session
export const WARMUP_MS    = 20 * 60 * 1000; // must be hot for 20 min to confirm session
export const GAP_MS       = 30 * 60 * 1000; // gap < 30 min = continuation, not new session

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

export async function readLeaderboard(env) {
  const raw = await env.SAUNA_KV.get('leaderboard');
  return raw ? JSON.parse(raw) : { entries: [] };
}

// Save completed session to the leaderboard and return energy used (kWh).
async function recordSession(env, sessionCount, peakTempF, sessionStart, sessionEndTs) {
  // Energy: 6kW heater, measured in kWh
  const durationH      = sessionStart ? (sessionEndTs - sessionStart) / 3_600_000 : 1.5;
  const sessionKwh     = Math.round(durationH * 6 * 10) / 10;

  if (peakTempF != null && peakTempF >= HOT_TEMP_F) {
    const lb   = await readLeaderboard(env);
    const date = new Date(sessionEndTs).toISOString().slice(0, 10);
    lb.entries = lb.entries.filter(e => e.session !== sessionCount);
    lb.entries.push({ session: sessionCount, peakTempF: Math.round(peakTempF * 10) / 10, date, kWh: sessionKwh });
    lb.entries.sort((a, b) => b.peakTempF - a.peakTempF);
    await env.SAUNA_KV.put('leaderboard', JSON.stringify(lb));
    console.log(`Leaderboard: session #${sessionCount} — ${peakTempF}°F peak, ${sessionKwh} kWh`);
  }

  return sessionKwh;
}

// Evaluate session state given current relay + temperature readings.
// Called from scheduled.js after each poll. Persists state only when it changed.
// Returns { state, changed } — caller skips write if !changed.
export async function evaluateSession(env, relayOn, indoorTempF) {
  const now   = Date.now();
  const state = await readState(env) ?? {};

  const isHot = relayOn && indoorTempF != null && indoorTempF >= HOT_TEMP_F;

  let { sessionActive, sessionCount, sessionHotSince, sessionEndedAt, sessionStart, sessionPeakTempF, energyKwhTotal, energyKwhMonth, energyKwhMonthYM } = state;
  sessionCount   = sessionCount   ?? 0;
  energyKwhTotal = energyKwhTotal ?? 0;
  energyKwhMonth = energyKwhMonth ?? 0;

  // Reset monthly counter when the calendar month rolls over
  const currentMonthYM = new Date(now).toISOString().slice(0, 7); // "YYYY-MM"
  if (energyKwhMonthYM && energyKwhMonthYM !== currentMonthYM) {
    energyKwhMonth = 0;
  }
  energyKwhMonthYM = currentMonthYM;

  if (isHot) {
    // Start tracking warmup window if not already
    if (!sessionHotSince) {
      sessionHotSince  = now;
      sessionPeakTempF = indoorTempF;
      console.log(`Session: hot detected (${indoorTempF}°F), warming up...`);
    }

    // Confirm session after sustained heat
    if (!sessionActive && (now - sessionHotSince) >= WARMUP_MS) {
      const isContinuation = sessionEndedAt && (now - sessionEndedAt) < GAP_MS;
      if (!isContinuation) {
        sessionCount += 1;
        sessionPeakTempF = indoorTempF; // reset peak for new session
        console.log(`Session: confirmed new session #${sessionCount}`);
      } else {
        console.log(`Session: confirmed continuation (gap < 30 min)`);
      }
      sessionActive  = true;
      sessionStart   = sessionStart ?? now;
      sessionEndedAt = null;
    }

    // Track peak temperature throughout active session
    if (sessionActive && indoorTempF != null) {
      if (sessionPeakTempF == null || indoorTempF > sessionPeakTempF) {
        sessionPeakTempF = indoorTempF;
      }
    }
  } else if (!relayOn) {
    // Relay is definitively OFF — end session and clear warmup state.
    if (sessionActive) {
      const sessionKwh = await recordSession(env, sessionCount, sessionPeakTempF, sessionStart, now);
      energyKwhTotal  += sessionKwh;
      energyKwhMonth   = Math.round((energyKwhMonth + sessionKwh) * 10) / 10;
      sessionEndedAt   = now;
      sessionActive    = false;
      sessionStart     = null;
      console.log(`Session: ended — peak ${sessionPeakTempF}°F, ${sessionKwh} kWh, total ${energyKwhTotal} kWh`);
    }
    sessionHotSince  = null;
    sessionPeakTempF = null;
  } else if (indoorTempF !== null) {
    // Relay is ON but temperature is confirmed below threshold — genuinely cooled down.
    if (sessionActive) {
      const sessionKwh = await recordSession(env, sessionCount, sessionPeakTempF, sessionStart, now);
      energyKwhTotal  += sessionKwh;
      energyKwhMonth   = Math.round((energyKwhMonth + sessionKwh) * 10) / 10;
      sessionEndedAt   = now;
      sessionActive    = false;
      sessionStart     = null;
      console.log(`Session: ended (cooled) — peak ${sessionPeakTempF}°F, ${sessionKwh} kWh, total ${energyKwhTotal} kWh`);
    }
    sessionHotSince  = null;
    sessionPeakTempF = null;
  } else {
    // Relay is ON but temperature sensor is offline (indoorTempF = null).
    // Hold current warmup/session state — don't reset the timer just because HVAC is unreachable.
    console.log(`Session: HVAC sensor offline, holding state (relayOn=${relayOn}, sessionHotSince=${sessionHotSince})`);
  }

  const next = {
    ...state,
    sessionActive,
    sessionCount,
    sessionHotSince:  sessionHotSince  ?? null,
    sessionEndedAt:   sessionEndedAt   ?? null,
    sessionStart:     sessionStart     ?? null,
    sessionPeakTempF: sessionPeakTempF ?? null,
    energyKwhTotal,
    energyKwhMonth,
    energyKwhMonthYM,
    sessionDurationS: state.sessionDurationS ?? SESSION_DURATION_S,
    ts: now,
  };

  // Detect meaningful changes — skip the KV write on idle ticks to save write ops.
  const changed = (
    state.sessionActive    !== next.sessionActive    ||
    state.sessionCount     !== next.sessionCount     ||
    state.sessionHotSince  !== next.sessionHotSince  ||
    state.sessionPeakTempF !== next.sessionPeakTempF ||
    state.sessionEndedAt   !== next.sessionEndedAt   ||
    state.energyKwhTotal   !== next.energyKwhTotal   ||
    state.energyKwhMonth   !== next.energyKwhMonth
  );

  if (changed) await env.SAUNA_KV.put('state', JSON.stringify(next));
  return { state: next, changed };
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
