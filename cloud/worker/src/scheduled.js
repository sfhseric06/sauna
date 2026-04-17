/**
 * Cron handler — runs every 5 minutes, always.
 * Polls all devices and writes metrics to Grafana Cloud + device state to KV.
 *
 * KV keys written:
 *   state   — session state (see state.js for schema)
 *   devices — { ts, temperature, primary, secondary, exterior, hvac, led }
 *   history — rolling 24h array of { ts, indoor, outdoor, saunaOn, power }
 */

import { shellyCloudDeviceStatus } from './shelly.js';
import { writeMetrics } from './metrics.js';
import { computeRemainingS, evaluateSession } from './state.js';

const SHELLY_POLL_DELAY_MS = 1100; // Shelly Cloud rate limit: ~1 req/sec per auth_key

// Poll all devices, write metrics to Grafana, write state to KV.
// Called by cron every 5 min, and after commands to refresh KV immediately.
export async function pollAndSync(env) {
  // Poll sequentially to respect Shelly Cloud's ~1 req/sec rate limit.
  const delay = () => new Promise(r => setTimeout(r, SHELLY_POLL_DELAY_MS));
  const exteriorStatus  = await shellyCloudDeviceStatus(env, env.EXTERIOR_DEVICE_ID);  await delay();
  const primaryStatus   = await shellyCloudDeviceStatus(env, env.PRIMARY_DEVICE_ID);   await delay();
  const secondaryStatus = await shellyCloudDeviceStatus(env, env.SECONDARY_DEVICE_ID); await delay();
  const hvacStatus      = await shellyCloudDeviceStatus(env, env.HVAC_DEVICE_ID);      await delay();
  const ledStatus       = await shellyCloudDeviceStatus(env, env.LED_DEVICE_ID);

  const metrics = [];
  const snap = { ts: Date.now() };

  if (!exteriorStatus) {
    console.error('Poll: could not reach exterior Shelly');
  } else {
    const lightOn    = exteriorStatus['switch:0']?.output ? 1 : 0;
    const lightPower = exteriorStatus['switch:0']?.apower ?? null;

    metrics.push({ name: 'sauna_relay_on', labels: { device: 'exterior', channel: '0', name: 'exterior_light' }, value: lightOn });
    if (lightPower != null) metrics.push({ name: 'sauna_power_watts', labels: { device: 'exterior', channel: '0', name: 'exterior_light' }, value: lightPower });

    snap.exterior = { on: lightOn === 1, apower: lightPower };
  }

  // Relay state from primary — used for session evaluation below.
  let relayOn = false;
  if (!primaryStatus) {
    console.error('Poll: could not reach primary Shelly');
  } else {
    relayOn = !!primaryStatus['switch:0']?.output;
    const heaterPower = primaryStatus['switch:0']?.apower ?? null;
    if (heaterPower != null) metrics.push({ name: 'sauna_power_watts', labels: { device: 'primary', channel: '0', name: 'heater_contactor' }, value: heaterPower });
    snap.primary = { on: relayOn, apower: heaterPower };
  }

  if (!secondaryStatus) {
    console.error('Poll: could not reach secondary Shelly');
  } else {
    const safetyOn = secondaryStatus['switch:0']?.output ? 1 : 0;
    metrics.push({ name: 'sauna_relay_on', labels: { device: 'secondary', channel: '0', name: 'safety_contactor' }, value: safetyOn });
    snap.secondary = { on: safetyOn === 1 };
  }

  // Temperature from HVAC device add-on probes: temperature:100=outdoor, temperature:101=indoor.
  // Indoor temp is also used for session evaluation (must reach ≥90°F to confirm a session).
  let indoorTempF = null;
  if (!hvacStatus) {
    console.error('Poll: could not reach HVAC Shelly');
  } else {
    const outdoor = hvacStatus['temperature:100']?.tF ?? null;
    indoorTempF   = hvacStatus['temperature:101']?.tF ?? null;

    if (outdoor     != null) metrics.push({ name: 'sauna_temperature_fahrenheit', labels: { sensor: 'outdoor' }, value: outdoor     });
    if (indoorTempF != null) metrics.push({ name: 'sauna_temperature_fahrenheit', labels: { sensor: 'indoor'  }, value: indoorTempF });

    snap.temperature = { outdoor, indoor: indoorTempF };

    const hvac0On    = hvacStatus['switch:0']?.output ? 1 : 0;
    const hvac0Power = hvacStatus['switch:0']?.apower ?? null;
    const hvac1On    = hvacStatus['switch:1']?.output ? 1 : 0;
    const hvac1Power = hvacStatus['switch:1']?.apower ?? null;

    metrics.push({ name: 'sauna_relay_on', labels: { device: 'hvac', channel: '0', name: 'hvac_0' }, value: hvac0On });
    metrics.push({ name: 'sauna_relay_on', labels: { device: 'hvac', channel: '1', name: 'hvac_1' }, value: hvac1On });
    if (hvac0Power != null) metrics.push({ name: 'sauna_power_watts', labels: { device: 'hvac', channel: '0', name: 'hvac_0' }, value: hvac0Power });
    if (hvac1Power != null) metrics.push({ name: 'sauna_power_watts', labels: { device: 'hvac', channel: '1', name: 'hvac_1' }, value: hvac1Power });

    snap.hvac = {
      ch0: { on: hvac0On === 1, apower: hvac0Power },
      ch1: { on: hvac1On === 1, apower: hvac1Power },
    };
  }

  if (!ledStatus) {
    console.error('Poll: could not reach LED Shelly');
  } else {
    const ledOn    = ledStatus['light:0']?.output ? 1 : 0;
    const ledPower = ledStatus['light:0']?.apower ?? null;
    metrics.push({ name: 'sauna_relay_on',    labels: { device: 'led', channel: '0', name: 'led_strip' }, value: ledOn    });
    if (ledPower != null) metrics.push({ name: 'sauna_power_watts', labels: { device: 'led', channel: '0', name: 'led_strip' }, value: ledPower });
    snap.led = { on: ledOn === 1, apower: ledPower };
  }

  // Evaluate session state using relay + temperature (runs every 5 min).
  // Only runs when we have data from both primary and HVAC; skip if either poll failed.
  let sessionState = null;
  if (primaryStatus && hvacStatus) {
    sessionState = await evaluateSession(env, relayOn, indoorTempF);
  }

  // Emit session metrics using freshly evaluated state.
  const sessionActive = sessionState?.sessionActive ?? false;
  const remainingS    = sessionActive ? computeRemainingS(sessionState) : 0;
  const sessionCount  = sessionState?.sessionCount ?? 0;
  metrics.push({ name: 'sauna_session_active',    labels: { device: 'primary' }, value: sessionActive ? 1 : 0 });
  metrics.push({ name: 'sauna_remaining_seconds', labels: { device: 'primary' }, value: remainingS            });
  metrics.push({ name: 'sauna_sessions_total',    labels: {},                    value: sessionCount          });

  if (snap.primary) snap.primary.sessionActive = sessionActive;

  await env.SAUNA_KV.put('devices', JSON.stringify(snap));
  if (metrics.length > 0) await writeMetrics(env, metrics);

  // Append to rolling 24h history (288 entries at 5-min intervals).
  try {
    const histRaw = await env.SAUNA_KV.get('history');
    const hist = histRaw ? JSON.parse(histRaw) : { entries: [] };
    hist.entries.push({
      ts:       snap.ts,
      indoor:   snap.temperature?.indoor  ?? null,
      outdoor:  snap.temperature?.outdoor ?? null,
      saunaOn:  sessionActive,
      power:    snap.primary?.apower      ?? null,
    });
    if (hist.entries.length > 288) hist.entries = hist.entries.slice(-288);
    await env.SAUNA_KV.put('history', JSON.stringify(hist));
  } catch (e) {
    console.error('History append error:', e);
  }
}

// Cron entrypoint — kept as a thin wrapper so the name stays stable.
export async function pollTemperatures(env) {
  await pollAndSync(env);
}
