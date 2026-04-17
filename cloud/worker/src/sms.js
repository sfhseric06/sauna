/**
 * SMS handler — receives Twilio webhooks, dispatches sauna commands.
 */

import { shellySetSauna, shellyCloudStatus } from './shelly.js';
import { pollAndSync } from './scheduled.js';
import { readState, startSession, endSession, computeRemainingS } from './state.js';

// Parse AUTHORIZED_USERS env var: "+16501234567:Eric,+16691234567:Anh"
// Returns a map of { number → name }
function parseUsers(env) {
  return Object.fromEntries(
    (env.AUTHORIZED_USERS || '').split(',')
      .map(s => s.trim().split(':'))
      .filter(parts => parts.length === 2)
      .map(([number, name]) => [number.trim(), name.trim()])
  );
}

export async function handleSMS(request, env) {
  if (request.method !== 'POST') return new Response('', { status: 405 });

  if (!await validateTwilioSignature(request, env)) {
    console.log('SMS rejected: invalid Twilio signature');
    return twiml('Unauthorized.');
  }

  const form = await request.formData();
  const from = (form.get('From') || '').trim();
  const body = (form.get('Body') || '').trim().toLowerCase();

  const users = parseUsers(env);
  if (!users[from]) {
    console.log('SMS rejected: unauthorized number', from);
    return twiml('Unauthorized.');
  }

  const name = users[from];
  console.log(`SMS from ${name} (${from}): "${body}"`);

  if (body === 'on')     return twiml(await commandOn(env, name));
  if (body === 'off')    return twiml(await commandOff(env, name));
  if (body === 'status') return twiml(await commandStatus(env));

  return twiml('Commands: on · off · status');
}

// --- Commands ---

async function commandOn(env, name) {
  const state = await readState(env);
  if (state?.sessionActive) {
    const remaining = computeRemainingS(state);
    return `Already ON. ${formatRemaining(remaining)}`;
  }

  const ok = await shellySetSauna(env, true);
  if (!ok) return 'Command failed — use physical button as backup.';

  const next = await startSession(env);

  // Re-poll so KV and Grafana reflect reality
  await new Promise(r => setTimeout(r, 1500));
  await pollAndSync(env);

  const sessionNum = next.sessionCount ?? '';
  const numStr = sessionNum ? ` (session #${sessionNum})` : '';
  return `Sauna ON${numStr}. ${formatRemaining(SESSION_DURATION_S)}.`;
}

async function commandOff(env, name) {
  const state = await readState(env);
  if (!state?.sessionActive) return 'Already OFF.';

  const ok = await shellySetSauna(env, false);
  if (!ok) return 'Command failed — use physical button as backup.';

  await endSession(env);

  await new Promise(r => setTimeout(r, 1500));
  await pollAndSync(env);

  return 'Sauna OFF.';
}

async function commandStatus(env) {
  // Try KV first — fresh if updated within last 5 min
  let state = await readState(env);
  if (!state || (Date.now() - state.ts) > 5 * 60 * 1000) {
    // Fall back to live Shelly Cloud poll
    state = await shellyCloudStatus(env);
  }

  if (!state) return 'Status unavailable — check device connectivity.';

  if (state.sessionActive) {
    const remaining = computeRemainingS(state);
    const sessionNum = state.sessionCount ? ` · Session #${state.sessionCount}` : '';
    return `ON. ${formatRemaining(remaining)}${sessionNum}`;
  }

  const sessionNum = state.sessionCount ? ` · ${state.sessionCount} sessions total` : '';
  return `OFF${sessionNum}.`;
}

// --- Helpers ---

const SESSION_DURATION_S = 3600;

function formatRemaining(seconds) {
  if (!seconds) return '';
  const m = Math.round(seconds / 60);
  return `${m} min remaining.`;
}

function twiml(message) {
  const safe = message
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${safe}</Message></Response>`,
    { headers: { 'Content-Type': 'text/xml' } }
  );
}

// Validates that the request genuinely came from Twilio.
// https://www.twilio.com/docs/usage/webhooks/webhooks-security
async function validateTwilioSignature(request, env) {
  const signature = request.headers.get('X-Twilio-Signature');
  if (!signature) return false;

  const url = new URL(request.url);
  const form = await request.clone().formData();

  const params = [...form.entries()].sort(([a], [b]) => a.localeCompare(b));
  let data = url.toString();
  for (const [key, value] of params) data += key + value;

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(env.TWILIO_AUTH_TOKEN),
    { name: 'HMAC', hash: 'SHA-1' },
    false,
    ['sign']
  );
  const sigBytes = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  const computed = btoa(String.fromCharCode(...new Uint8Array(sigBytes)));

  return computed === signature;
}
