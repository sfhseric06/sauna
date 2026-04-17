/**
 * Web control panel — full device dashboard with controls.
 *
 * GET  /control          — dashboard (requires cookie)
 * POST /control          — device command (requires cookie)
 * POST /control/login    — validate password, set cookie
 * POST /control/logout   — clear cookie
 *
 * Command body: { device, action, channel? }
 *   device:  "sauna" | "exterior" | "led" | "hvac"
 *   action:  "on" | "off"
 *   channel: 0 | 1  (hvac only)
 *
 * Authentication: WEBHOOK_SECRET is the password.
 * Session cookie is HMAC-SHA256 of a fixed string — raw secret never in cookie or URL.
 */

import { shellySetSauna, shellySetSwitch, shellySetLight } from './shelly.js';
import { pollAndSync } from './scheduled.js';
import { readState, startSession, endSession, computeRemainingS } from './state.js';

const COOKIE_NAME    = 'sauna_session';
const COOKIE_MAX_AGE = 60 * 60 * 24 * 30; // 30 days

// ─── Auth ──────────────────────────────────────────────────────────────────────

async function makeSessionToken(secret) {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('sauna-session'));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

function getCookie(request, name) {
  const header = request.headers.get('Cookie') || '';
  for (const part of header.split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === name) return v.join('=');
  }
  return null;
}

async function isAuthenticated(request, env) {
  const cookie = getCookie(request, COOKIE_NAME);
  if (!cookie) return false;
  return cookie === await makeSessionToken(env.WEBHOOK_SECRET);
}

function sessionCookie(token) {
  return `${COOKIE_NAME}=${token}; HttpOnly; Secure; SameSite=Strict; Max-Age=${COOKIE_MAX_AGE}; Path=/control`;
}

function clearCookie() {
  return `${COOKIE_NAME}=; HttpOnly; Secure; SameSite=Strict; Max-Age=0; Path=/control`;
}

// ─── Router ────────────────────────────────────────────────────────────────────

export async function handleControl(request, env) {
  const url = new URL(request.url);

  if (url.pathname === '/control/login')  return handleLogin(request, env);
  if (url.pathname === '/control/logout') return handleLogout();
  if (url.pathname !== '/control') return new Response('Not found', { status: 404 });

  if (!(await isAuthenticated(request, env))) return loginPage();

  if (request.method === 'POST') return handleCommand(request, env);
  return controlPage(env);
}

// ─── Login / Logout ────────────────────────────────────────────────────────────

async function handleLogin(request, env) {
  if (request.method !== 'POST') return new Response('', { status: 405 });
  const form = await request.formData();
  const password = (form.get('password') || '').trim();
  if (password !== env.WEBHOOK_SECRET) return loginPage('Incorrect password.');
  const token = await makeSessionToken(env.WEBHOOK_SECRET);
  return new Response(null, {
    status: 302,
    headers: { 'Location': '/control', 'Set-Cookie': sessionCookie(token) },
  });
}

function handleLogout() {
  return new Response(null, {
    status: 302,
    headers: { 'Location': '/control', 'Set-Cookie': clearCookie() },
  });
}

// ─── Commands ──────────────────────────────────────────────────────────────────

async function handleCommand(request, env) {
  let body;
  try { body = await request.json(); } catch { return new Response('Bad request', { status: 400 }); }

  const { device, action, channel } = body;
  if (!device || (action !== 'on' && action !== 'off')) {
    return new Response('Invalid command', { status: 400 });
  }
  const on = action === 'on';

  let ok;
  switch (device) {
    case 'sauna': {
      const state = await readState(env);
      const isOn = state?.sessionActive ?? false;
      if (on && isOn)   return Response.json({ ok: true, message: 'Already ON',  state: true  });
      if (!on && !isOn) return Response.json({ ok: true, message: 'Already OFF', state: false });
      ok = await shellySetSauna(env, on);
      if (ok) { if (on) await startSession(env); else await endSession(env); }
      break;
    }
    case 'exterior':
      ok = await shellySetSwitch(env, env.EXTERIOR_DEVICE_ID, 0, on);
      break;
    case 'led':
      ok = await shellySetLight(env, env.LED_DEVICE_ID, 0, on);
      break;
    case 'hvac': {
      const ch = Number(channel ?? 0);
      if (ch !== 0 && ch !== 1) return new Response('Invalid channel', { status: 400 });
      ok = await shellySetSwitch(env, env.HVAC_DEVICE_ID, ch, on);
      break;
    }
    default:
      return new Response('Unknown device', { status: 400 });
  }

  if (!ok) return Response.json({ ok: false, message: 'Command failed — try the physical button.' }, { status: 502 });

  await new Promise(r => setTimeout(r, 1500));
  await pollAndSync(env);

  return Response.json({ ok: true, state: on });
}

// ─── Dashboard ─────────────────────────────────────────────────────────────────

function escapeHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function fTemp(val) {
  return val == null ? '--' : `${Math.round(val)}°`;
}

function fMins(s) {
  if (!s || s <= 0) return null;
  const m = Math.round(s / 60);
  return m > 0 ? `${m}m` : '<1m';
}

function fAge(ms) {
  if (ms == null) return 'no data';
  const s = Math.round(ms / 1000);
  if (s < 60)  return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  return `${Math.round(s / 3600)}h ago`;
}

// ─── Leaderboard rendering ─────────────────────────────────────────────────────

function renderLeaderboard(leaderboard, currentSessionPeak) {
  const entries = leaderboard?.entries ?? [];
  if (entries.length === 0 && currentSessionPeak == null) {
    return `<p style="color:var(--muted);font-size:.85rem;text-align:center;margin:12px 0">No sessions recorded yet</p>`;
  }

  // Show top 10, highlighting current session if it would appear
  const rows = entries.slice(0, 10).map((e, i) => {
    const medal = i === 0 ? '🥇' : i === 1 ? '🥈' : i === 2 ? '🥉' : `${i + 1}.`;
    return `<tr>
      <td style="padding:5px 8px;color:var(--muted);font-size:.8rem">${medal}</td>
      <td style="padding:5px 8px;font-size:.85rem">Session #${e.session}</td>
      <td style="padding:5px 8px;font-size:.85rem;color:var(--muted)">${e.date}</td>
      <td style="padding:5px 8px;font-size:.9rem;font-weight:600;color:var(--orange);text-align:right">${e.peakTempF}°F</td>
    </tr>`;
  }).join('');

  const currentRow = currentSessionPeak != null ? `
    <tr style="border-top:1px solid #333;opacity:.7">
      <td style="padding:5px 8px;color:var(--muted);font-size:.8rem">now</td>
      <td style="padding:5px 8px;font-size:.85rem" colspan="2">Current session</td>
      <td style="padding:5px 8px;font-size:.9rem;font-weight:600;color:var(--orange);text-align:right">${currentSessionPeak}°F</td>
    </tr>` : '';

  return `<table style="width:100%;border-collapse:collapse">${rows}${currentRow}</table>`;
}

// ─── Chart rendering ───────────────────────────────────────────────────────────

function renderChart(entries) {
  if (!entries || entries.length < 2) {
    return `<div style="height:120px;display:flex;align-items:center;justify-content:center;color:#444;font-size:.8rem">
      No history yet — check back in a few minutes
    </div>`;
  }

  const W = 400, H = 110, PAD = { t: 8, r: 8, b: 20, l: 36 };
  const gW = W - PAD.l - PAD.r;
  const gH = H - PAD.t - PAD.b;

  const temps = entries.flatMap(e => [e.indoor, e.outdoor]).filter(v => v != null);
  const tMin = temps.length ? Math.min(...temps) - 5 : 32;
  const tMax = temps.length ? Math.max(...temps) + 5 : 212;
  const tRange = tMax - tMin || 1;

  const t0 = entries[0].ts;
  const t1 = entries[entries.length - 1].ts;
  const tSpan = t1 - t0 || 1;

  function px(ts) { return PAD.l + ((ts - t0) / tSpan) * gW; }
  function py(temp) { return PAD.t + gH - ((temp - tMin) / tRange) * gH; }

  // Session bands (orange background when sauna was on)
  let bands = '';
  let bandStart = null;
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    if (e.saunaOn && bandStart === null) bandStart = e.ts;
    if (!e.saunaOn && bandStart !== null) {
      const x1 = px(bandStart), x2 = px(entries[i - 1].ts);
      bands += `<rect x="${x1.toFixed(1)}" y="${PAD.t}" width="${(x2 - x1).toFixed(1)}" height="${gH}" fill="rgba(232,130,74,.12)" rx="2"/>`;
      bandStart = null;
    }
  }
  if (bandStart !== null) {
    const x1 = px(bandStart), x2 = px(t1);
    bands += `<rect x="${x1.toFixed(1)}" y="${PAD.t}" width="${(x2 - x1).toFixed(1)}" height="${gH}" fill="rgba(232,130,74,.12)" rx="2"/>`;
  }

  // Line path builder — skip null values
  function linePath(key) {
    let d = '';
    for (const e of entries) {
      if (e[key] == null) continue;
      const x = px(e.ts).toFixed(1), y = py(e[key]).toFixed(1);
      d += d ? ` L${x},${y}` : `M${x},${y}`;
    }
    return d;
  }

  const indoorPath  = linePath('indoor');
  const outdoorPath = linePath('outdoor');

  // Y-axis tick labels (3 ticks)
  const yTicks = [tMin, (tMin + tMax) / 2, tMax].map(v => {
    const y = py(v).toFixed(1);
    return `<text x="${PAD.l - 5}" y="${y}" text-anchor="end" dominant-baseline="middle">${Math.round(v)}</text>`;
  }).join('');

  // X-axis labels: show time for first, last, and ~middle
  const xLabels = [0, Math.floor(entries.length / 2), entries.length - 1].map(i => {
    const e = entries[i];
    const d = new Date(e.ts);
    const label = `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`;
    const x = px(e.ts).toFixed(1);
    const anchor = i === 0 ? 'start' : i === entries.length - 1 ? 'end' : 'middle';
    return `<text x="${x}" y="${H - 4}" text-anchor="${anchor}">${label}</text>`;
  }).join('');

  return `<svg viewBox="0 0 ${W} ${H}" style="width:100%;height:auto;overflow:visible"
    fill="none" xmlns="http://www.w3.org/2000/svg">
    <style>text { font: 9px -apple-system, sans-serif; fill: #555; }</style>
    <!-- Grid lines -->
    <line x1="${PAD.l}" y1="${PAD.t}" x2="${PAD.l}" y2="${PAD.t + gH}" stroke="#222" stroke-width="1"/>
    <line x1="${PAD.l}" y1="${PAD.t + gH}" x2="${PAD.l + gW}" y2="${PAD.t + gH}" stroke="#222" stroke-width="1"/>
    <!-- Session bands -->
    ${bands}
    <!-- Temperature lines -->
    ${outdoorPath ? `<path d="${outdoorPath}" stroke="#4a9eff" stroke-width="1.5" stroke-linejoin="round" opacity=".8"/>` : ''}
    ${indoorPath  ? `<path d="${indoorPath}"  stroke="#e8824a" stroke-width="1.5" stroke-linejoin="round"/>` : ''}
    <!-- Labels -->
    ${yTicks}
    ${xLabels}
    <!-- Legend -->
    <rect x="${W - 80}" y="${PAD.t}" width="8" height="8" rx="2" fill="#e8824a"/>
    <text x="${W - 68}" y="${PAD.t + 7}" fill="#888">Indoor</text>
    <rect x="${W - 80}" y="${PAD.t + 12}" width="8" height="8" rx="2" fill="#4a9eff"/>
    <text x="${W - 68}" y="${PAD.t + 19}" fill="#888">Outdoor</text>
  </svg>`;
}

async function controlPage(env) {
  const [snapRaw, stateRaw, lbRaw] = await Promise.all([
    env.SAUNA_KV.get('snap'),
    env.SAUNA_KV.get('state'),
    env.SAUNA_KV.get('leaderboard'),
  ]);

  const snap        = snapRaw  ? JSON.parse(snapRaw)  : null;
  const dev         = snap?.devices  ?? null;
  const history     = snap?.history  ?? null;
  const state       = stateRaw ? JSON.parse(stateRaw) : null;
  const leaderboard = lbRaw    ? JSON.parse(lbRaw)    : null;

  const relayOn     = dev?.primary?.on       ?? false;
  const confirmed   = state?.sessionActive   ?? false;
  const warmingUp   = relayOn && !confirmed;
  const saunaOn     = confirmed || relayOn;   // on if relay is on, regardless of session confirmation
  // Show relay-based remaining when warming up (from webhook), confirmed remaining when session active
  const remainingS  = confirmed ? computeRemainingS(state) : (warmingUp ? (state?.remainingS ?? 0) : 0);
  const sessionNum  = state?.sessionCount  ?? null;
  const heaterPower = dev?.primary?.apower ?? null;

  const indoorTemp  = dev?.temperature?.indoor;
  const outdoorTemp = dev?.temperature?.outdoor;

  const exteriorOn = dev?.exterior?.on  ?? false;
  const ledOn      = dev?.led?.on       ?? false;
  const hvac0On    = dev?.hvac?.ch0?.on ?? false;
  const hvac1On    = dev?.hvac?.ch1?.on ?? false;

  const dataAge  = dev ? Date.now() - dev.ts : null;
  const stale    = dataAge == null || dataAge > 360_000;

  // Sauna sub-info line
  let saunaInfo = '';
  if (warmingUp) {
    const mins = fMins(remainingS);
    saunaInfo = `warming up${mins ? ` &middot; ${mins} left on relay` : ''}`;
    if (indoorTemp != null) saunaInfo += ` &middot; ${Math.round(indoorTemp)}&deg;F`;
  } else if (confirmed) {
    const mins = fMins(remainingS);
    saunaInfo = mins ? `${mins} remaining` : 'session active';
    if (heaterPower) saunaInfo += ` &middot; ${Math.round(heaterPower)}W`;
  } else {
    saunaInfo = sessionNum ? `${sessionNum} sessions` : 'ready';
  }

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Sauna</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --bg:     #0d0d0d;
      --card:   #181818;
      --border: #272727;
      --text:   #f0f0f0;
      --muted:  #585858;
      --orange: #e8824a;
      --green:  #52c77a;
      --blue:   #4a9eff;
      --red:    #e05252;
    }
    html, body { height: 100%; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: var(--bg); color: var(--text);
      padding: env(safe-area-inset-top, 16px) 16px env(safe-area-inset-bottom, 16px);
      padding-top: max(env(safe-area-inset-top), 16px);
    }
    .page { max-width: 420px; margin: 0 auto; }

    /* ── Header ── */
    .header {
      display: flex; align-items: center; justify-content: space-between;
      margin-bottom: 20px;
    }
    .header h1 { font-size: 1.25rem; font-weight: 700; letter-spacing: -.02em; }
    .status-dot {
      display: inline-block; width: 6px; height: 6px; border-radius: 50%;
      background: ${stale ? 'var(--red)' : 'var(--green)'}; margin-right: 5px;
      vertical-align: middle;
    }
    .header-right { font-size: 0.72rem; color: var(--muted); text-align: right; }

    /* ── Temp strip ── */
    .temps { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 10px; }
    .temp-card {
      background: var(--card); border: 1px solid var(--border);
      border-radius: 14px; padding: 14px 16px;
    }
    .temp-label { font-size: 0.65rem; color: var(--muted); text-transform: uppercase; letter-spacing: .07em; margin-bottom: 4px; }
    .temp-value { font-size: 2rem; font-weight: 250; letter-spacing: -.02em; }

    /* ── Device cards ── */
    .card {
      background: var(--card); border: 1px solid var(--border);
      border-radius: 14px; padding: 16px; margin-bottom: 10px;
      transition: border-color .2s;
    }
    .card.is-on { border-color: rgba(232,130,74,.35); }

    .card-top { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
    .card-name { font-size: 0.7rem; font-weight: 600; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); }

    .state-pill {
      font-size: 0.68rem; font-weight: 700; padding: 3px 9px;
      border-radius: 99px; letter-spacing: .05em;
    }
    .pill-on  { background: rgba(232,130,74,.18); color: var(--orange); }
    .pill-off { background: rgba(255,255,255,.05); color: var(--muted); }

    .card-info {
      font-size: 0.82rem; color: var(--muted);
      margin-bottom: 13px; min-height: 1.1em;
    }

    /* ── Sauna timer display ── */
    .timer-display { margin-bottom: 14px; }
    .timer-big { font-size: 3rem; font-weight: 200; letter-spacing: -.03em; line-height: 1; color: var(--orange); }
    .timer-label { font-size: 0.72rem; color: var(--muted); margin-top: 2px; }

    /* ── Toggle button ── */
    .toggle-btn {
      width: 100%; padding: 13px;
      border: none; border-radius: 10px;
      font-size: 0.9rem; font-weight: 600; cursor: pointer;
      transition: opacity .15s, transform .1s;
      letter-spacing: .01em;
    }
    .toggle-btn:active { opacity: .7; transform: scale(.98); }
    .toggle-btn.turn-off { background: rgba(232,130,74,.12); color: var(--orange); border: 1px solid rgba(232,130,74,.25); }
    .toggle-btn.turn-on  { background: rgba(255,255,255,.06); color: var(--text); border: 1px solid var(--border); }
    .toggle-btn:disabled { opacity: .35; cursor: default; }

    /* ── HVAC two-channel layout ── */
    .hvac-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
    .hvac-ch-label { font-size: 0.65rem; color: var(--muted); text-transform: uppercase; letter-spacing: .06em; margin-bottom: 8px; }

    /* ── Chart ── */
    .chart-wrap { width: 100%; overflow: hidden; }

    /* ── Footer ── */
    .footer {
      display: flex; justify-content: space-between; align-items: center;
      margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--border);
    }
    .footer a { color: var(--muted); font-size: 0.78rem; text-decoration: none; }
    .footer a:hover { color: var(--text); }
    .footer-btn { background: none; border: none; color: var(--muted); font-size: 0.78rem; cursor: pointer; }
    .footer-btn:hover { color: var(--text); }

    /* ── Toast ── */
    #toast {
      position: fixed; bottom: calc(env(safe-area-inset-bottom, 0px) + 20px);
      left: 50%; transform: translateX(-50%) translateY(10px);
      background: #2a2a2a; color: #eee; padding: 10px 18px;
      border-radius: 10px; font-size: 0.84rem;
      opacity: 0; transition: opacity .2s, transform .2s;
      pointer-events: none; white-space: nowrap; z-index: 100;
    }
    #toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }

    /* ── Loading spinner on button ── */
    @keyframes spin { to { transform: rotate(360deg); } }
    .loading::after {
      content: ''; display: inline-block; width: 12px; height: 12px;
      border: 2px solid currentColor; border-top-color: transparent;
      border-radius: 50%; animation: spin .6s linear infinite;
      margin-left: 8px; vertical-align: middle;
    }
  </style>
</head>
<body>
<div class="page">

  <div class="header">
    <h1>Sauna</h1>
    <div class="header-right">
      <span class="status-dot"></span>${escapeHtml(fAge(dataAge))}
    </div>
  </div>

  <!-- Temperatures -->
  <div class="temps">
    <div class="temp-card">
      <div class="temp-label">Indoor</div>
      <div class="temp-value">${escapeHtml(fTemp(indoorTemp))}<span style="font-size:1rem;color:var(--muted)">F</span></div>
    </div>
    <div class="temp-card">
      <div class="temp-label">Outdoor</div>
      <div class="temp-value">${escapeHtml(fTemp(outdoorTemp))}<span style="font-size:1rem;color:var(--muted)">F</span></div>
    </div>
  </div>

  <!-- Temperature history chart -->
  <div class="card" style="margin-bottom:10px;padding:14px 14px 10px">
    <div class="card-top" style="margin-bottom:10px">
      <span class="card-name">Temperature &mdash; 24h</span>
      <span style="font-size:.68rem;color:var(--muted)">${history?.entries?.length ? `${history.entries.length} readings` : 'building...'}</span>
    </div>
    ${renderChart(history?.entries)}
  </div>

  <!-- Sauna heater -->
  <div class="card${saunaOn ? ' is-on' : ''}" id="card-sauna">
    <div class="card-top">
      <span class="card-name">Sauna Heater</span>
      <span class="state-pill ${saunaOn ? 'pill-on' : 'pill-off'}" id="pill-sauna">${saunaOn ? 'ON' : 'OFF'}</span>
    </div>
    ${saunaOn && remainingS > 0
      ? `<div class="timer-display">
           <div class="timer-big" id="sauna-timer">${escapeHtml(fMins(remainingS) ?? '--')}</div>
           <div class="timer-label">remaining</div>
         </div>`
      : `<div class="card-info" id="sauna-info">${saunaInfo}</div>`
    }
    <button class="toggle-btn ${saunaOn ? 'turn-off' : 'turn-on'}" id="btn-sauna"
            onclick="toggle('sauna', ${saunaOn})">
      ${saunaOn ? 'Turn Off' : 'Turn On'}
    </button>
  </div>

  <!-- Exterior light -->
  <div class="card${exteriorOn ? ' is-on' : ''}" id="card-exterior">
    <div class="card-top">
      <span class="card-name">Exterior Light</span>
      <span class="state-pill ${exteriorOn ? 'pill-on' : 'pill-off'}" id="pill-exterior">${exteriorOn ? 'ON' : 'OFF'}</span>
    </div>
    <div class="card-info" id="info-exterior">${exteriorOn && dev?.exterior?.apower ? `${Math.round(dev.exterior.apower)}W` : 'Outdoor lighting'}</div>
    <button class="toggle-btn ${exteriorOn ? 'turn-off' : 'turn-on'}" id="btn-exterior"
            onclick="toggle('exterior', ${exteriorOn})">
      ${exteriorOn ? 'Turn Off' : 'Turn On'}
    </button>
  </div>

  <!-- LED strip -->
  <div class="card${ledOn ? ' is-on' : ''}" id="card-led">
    <div class="card-top">
      <span class="card-name">LED Strip</span>
      <span class="state-pill ${ledOn ? 'pill-on' : 'pill-off'}" id="pill-led">${ledOn ? 'ON' : 'OFF'}</span>
    </div>
    <div class="card-info" id="info-led">${ledOn && dev?.led?.apower ? `${Math.round(dev.led.apower)}W` : 'Interior lighting'}</div>
    <button class="toggle-btn ${ledOn ? 'turn-off' : 'turn-on'}" id="btn-led"
            onclick="toggle('led', ${ledOn})">
      ${ledOn ? 'Turn Off' : 'Turn On'}
    </button>
  </div>

  <!-- HVAC -->
  <div class="card${(hvac0On || hvac1On) ? ' is-on' : ''}" id="card-hvac">
    <div class="card-top">
      <span class="card-name">HVAC</span>
      <span class="state-pill ${(hvac0On || hvac1On) ? 'pill-on' : 'pill-off'}" id="pill-hvac">${(hvac0On || hvac1On) ? 'ON' : 'OFF'}</span>
    </div>
    <div class="hvac-grid">
      <div>
        <div class="hvac-ch-label">
          Channel 0
          <span class="state-pill ${hvac0On ? 'pill-on' : 'pill-off'}" id="pill-hvac0" style="margin-left:4px">${hvac0On ? 'ON' : 'OFF'}</span>
        </div>
        <button class="toggle-btn ${hvac0On ? 'turn-off' : 'turn-on'}" id="btn-hvac0"
                onclick="toggle('hvac', ${hvac0On}, 0)">
          ${hvac0On ? 'Turn Off' : 'Turn On'}
        </button>
      </div>
      <div>
        <div class="hvac-ch-label">
          Channel 1
          <span class="state-pill ${hvac1On ? 'pill-on' : 'pill-off'}" id="pill-hvac1" style="margin-left:4px">${hvac1On ? 'ON' : 'OFF'}</span>
        </div>
        <button class="toggle-btn ${hvac1On ? 'turn-off' : 'turn-on'}" id="btn-hvac1"
                onclick="toggle('hvac', ${hvac1On}, 1)">
          ${hvac1On ? 'Turn Off' : 'Turn On'}
        </button>
      </div>
    </div>
  </div>

  <!-- Peak temperature leaderboard -->
  <div class="card" style="margin-bottom:12px">
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
      <span style="font-weight:600;font-size:.9rem">Peak Temp Leaderboard</span>
      <span style="font-size:.68rem;color:var(--muted)">${leaderboard?.entries?.length ? `${leaderboard.entries.length} sessions` : 'building...'}</span>
    </div>
    ${renderLeaderboard(leaderboard, state?.sessionPeakTempF != null ? Math.round(state.sessionPeakTempF * 10) / 10 : null)}
  </div>

  <div class="footer">
    <a href="https://panoramasauna.grafana.net" target="_blank" rel="noopener">Grafana &rarr;</a>
    <form method="POST" action="/control/logout" style="display:inline">
      <button type="submit" class="footer-btn">Sign out</button>
    </form>
  </div>

</div>
<div id="toast"></div>

<script>
// Auto-refresh every 30s when page is visible
let refreshTimer = setTimeout(() => location.reload(), 30000);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { clearTimeout(refreshTimer); }
  else { refreshTimer = setTimeout(() => location.reload(), 30000); }
});

function toast(msg, duration) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(el._t);
  el._t = setTimeout(() => el.classList.remove('show'), duration || 2500);
}

function setPill(id, on) {
  const el = document.getElementById('pill-' + id);
  if (!el) return;
  el.textContent = on ? 'ON' : 'OFF';
  el.className = 'state-pill ' + (on ? 'pill-on' : 'pill-off');
}

function setBtn(id, nowOn) {
  const el = document.getElementById('btn-' + id);
  if (!el) return;
  el.textContent = nowOn ? 'Turn Off' : 'Turn On';
  el.className = 'toggle-btn ' + (nowOn ? 'turn-off' : 'turn-on');
  el.disabled = false;
  el.classList.remove('loading');
  el.onclick = () => toggle(id.replace(/\d$/, ''), nowOn, id.match(/\d$/) ? Number(id.match(/\d$/)[0]) : undefined);
}

function setCard(id, on) {
  const el = document.getElementById('card-' + id);
  if (!el) return;
  if (on) el.classList.add('is-on');
  else el.classList.remove('is-on');
}

async function toggle(device, currentlyOn, channel) {
  const action = currentlyOn ? 'off' : 'on';
  const btnId  = channel != null ? device + channel : device;
  const btn    = document.getElementById('btn-' + btnId);

  if (btn) { btn.disabled = true; btn.classList.add('loading'); }
  clearTimeout(refreshTimer);

  toast(currentlyOn ? 'Turning off...' : 'Turning on...');

  try {
    const body = channel != null ? { device, action, channel } : { device, action };
    const r = await fetch('/control', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const d = await r.json();

    if (!d.ok) {
      toast(d.message || 'Command failed.', 4000);
      if (btn) { btn.disabled = false; btn.classList.remove('loading'); }
      refreshTimer = setTimeout(() => location.reload(), 30000);
      return;
    }

    const nowOn = d.state ?? !currentlyOn;

    if (device === 'sauna') {
      setPill('sauna', nowOn); setBtn('sauna', nowOn); setCard('sauna', nowOn);
    } else if (device === 'exterior') {
      setPill('exterior', nowOn); setBtn('exterior', nowOn); setCard('exterior', nowOn);
    } else if (device === 'led') {
      setPill('led', nowOn); setBtn('led', nowOn); setCard('led', nowOn);
    } else if (device === 'hvac') {
      setPill('hvac' + channel, nowOn);
      setBtn('hvac' + channel, nowOn);
      const other = channel === 0
        ? document.getElementById('pill-hvac1')?.textContent === 'ON'
        : document.getElementById('pill-hvac0')?.textContent === 'ON';
      setPill('hvac', nowOn || other);
      setCard('hvac', nowOn || other);
    }

    toast(nowOn ? 'On' : 'Off');
  } catch {
    toast('Network error.', 4000);
    if (btn) { btn.disabled = false; btn.classList.remove('loading'); }
  }

  refreshTimer = setTimeout(() => location.reload(), 30000);
}
</script>
</body>
</html>`;

  return new Response(html, { headers: { 'Content-Type': 'text/html;charset=UTF-8' } });
}

// ─── Login page ────────────────────────────────────────────────────────────────

function loginPage(error = '') {
  const errorHtml = error
    ? `<p style="color:var(--orange);font-size:.84rem;margin-bottom:14px">${escapeHtml(error)}</p>`
    : '';
  return new Response(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Sauna</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root { --orange: #e8824a; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #0d0d0d; color: #f0f0f0;
      display: flex; justify-content: center; align-items: center;
      min-height: 100vh; padding: 20px;
    }
    .card {
      background: #181818; border: 1px solid #272727; border-radius: 18px;
      padding: 40px 32px; max-width: 320px; width: 100%; text-align: center;
    }
    h1 { font-size: 1.4rem; font-weight: 700; margin-bottom: 28px; letter-spacing: -.02em; }
    input[type=password] {
      width: 100%; padding: 13px 15px; border-radius: 10px;
      border: 1px solid #333; background: #111; color: #f0f0f0;
      font-size: 1rem; margin-bottom: 12px; outline: none;
    }
    input[type=password]:focus { border-color: var(--orange); }
    button {
      width: 100%; padding: 14px; border: none; border-radius: 10px;
      background: var(--orange); color: #fff; font-size: 1rem;
      font-weight: 600; cursor: pointer; letter-spacing: .01em;
    }
    button:active { opacity: .85; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Sauna</h1>
    <form method="POST" action="/control/login">
      <input type="password" name="password" placeholder="Password" autofocus autocomplete="current-password">
      ${errorHtml}
      <button type="submit">Sign in</button>
    </form>
  </div>
</body>
</html>`, { headers: { 'Content-Type': 'text/html;charset=UTF-8' } });
}
