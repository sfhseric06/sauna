/**
 * Event handler — receives state webhooks from the primary Shelly script.
 * Also serves the /status endpoint for Grafana and debugging.
 */

import { writeMetrics } from './metrics.js';
import { readState } from './state.js';

export async function handleEvent(request, env) {
  if (request.method !== 'POST') return new Response('', { status: 405 });

  let payload;
  try {
    payload = await request.json();
  } catch {
    return new Response('Bad request', { status: 400 });
  }

  // Auth: secret in body (Shelly firmware doesn't reliably send custom headers).
  // Also accept X-Sauna-Secret header for other callers (e.g. curl tests).
  const headerSecret = request.headers.get('X-Sauna-Secret');
  const bodySecret   = payload.secret;
  if (headerSecret !== env.WEBHOOK_SECRET && bodySecret !== env.WEBHOOK_SECRET) {
    return new Response('Unauthorized', { status: 401 });
  }

  // Shape: { secret?, sessionActive: bool, remainingS: number, uptimeS: number }
  // Update remainingS from the script's live reading. Do NOT touch sessionCount — that is
  // managed exclusively by evaluateSession() in scheduled.js using temperature data.
  const existing = await readState(env) ?? {};
  const state = {
    ...existing,
    remainingS: payload.remainingS,
    ts:         Date.now(),
  };

  // Use payload.sessionActive (live device signal) for relay/power metrics so that
  // Grafana updates immediately when the sauna turns on or off, without waiting for
  // the 5-min cron poll to push sauna_relay_on / sauna_power_watts.
  const relayOn = payload.sessionActive ? 1 : 0;

  await Promise.all([
    env.SAUNA_KV.put('state', JSON.stringify(state)),
    writeMetrics(env, [
      { name: 'sauna_session_active',    labels: { device: 'primary' },                                   value: relayOn                },
      { name: 'sauna_remaining_seconds', labels: { device: 'primary' },                                   value: payload.remainingS ?? 0 },
      { name: 'sauna_relay_on',          labels: { device: 'primary', channel: '0', name: 'heater_contactor' }, value: relayOn           },
      { name: 'sauna_power_watts',       labels: { device: 'primary', channel: '0', name: 'heater'        }, value: relayOn ? 6000 : 0   },
    ]),
  ]);

  return new Response('ok');
}

export async function handleStatus(request, env) {
  if (request.method !== 'GET') return new Response('', { status: 405 });

  const raw = await env.SAUNA_KV.get('state');
  if (!raw) return Response.json({ error: 'no data yet' }, { status: 503 });

  const state = JSON.parse(raw);
  const ageS = Math.round((Date.now() - state.ts) / 1000);
  return Response.json({ ...state, ageS });
}
