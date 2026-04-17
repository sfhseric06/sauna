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
  // Update relay state and remainingS. Do NOT touch sessionCount — that is
  // managed exclusively by evaluateSession() in scheduled.js using temperature data.
  const existing = await readState(env) ?? {};
  const state = {
    ...existing,
    remainingS: payload.remainingS,
    ts:         Date.now(),
  };

  await Promise.all([
    env.SAUNA_KV.put('state', JSON.stringify(state)),
    writeMetrics(env, [
      { name: 'sauna_session_active',    labels: { device: 'primary' }, value: state.sessionActive ? 1 : 0 },
      { name: 'sauna_remaining_seconds', labels: { device: 'primary' }, value: state.remainingS ?? 0 },
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
