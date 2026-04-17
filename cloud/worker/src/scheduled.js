/**
 * Cron handler — runs every 5 minutes, always.
 * Polls all devices and writes metrics to Grafana Cloud + device state to KV.
 *
 * KV writes per tick (minimized to stay within free tier):
 *   snap  — always (1 write): devices + rolling 24h history combined
 *   state — only when session state changes (skipped on idle ticks)
 */

import { shellyCloudDeviceStatus } from './shelly.js';
import { writeMetrics } from './metrics.js';
import { computeRemainingS, evaluateSession } from './state.js';

const SHELLY_POLL_DELAY_MS = 1100; // Shelly Cloud rate limit: ~1 req/sec per auth_key

// Poll all devices, write metrics to Grafana, write state to KV.
// Called by cron every 5 min, and after /sync requests.
export async function pollAndSync(env) {
  // Poll sequentially to respect Shelly Cloud's ~1 req/sec rate limit.
  const delay = () => new Promise(r => setTimeout(r, SHELLY_POLL_DELAY_MS));
  const exteriorStatus  = await shellyCloudDeviceStatus(env, env.EXTERIOR_DEVICE_ID);  await delay();
  const primaryStatus   = await shellyCloudDeviceStatus(env, env.PRIMARY_DEVICE_ID);   await delay();
  const secondaryStatus = await shellyCloudDeviceStatus(env, env.SECONDARY_DEVICE_ID); await delay();
  const hvacStatus      = await shellyCloudDeviceStatus(env, env.HVAC_DEVICE_ID);      await delay();
  const ledStatus       = await shellyCloudDeviceStatus(env, env.LED_DEVICE_ID);

  const metrics = [];
  const devices = { ts: Date.now() };

  if (!exteriorStatus) {
    console.error('Poll: could not reach exterior Shelly');
  } else {
    const lightOn    = exteriorStatus['switch:0']?.output ? 1 : 0;
    const lightPower = exteriorStatus['switch:0']?.apower ?? null;

    metrics.push({ name: 'sauna_relay_on', labels: { device: 'exterior', channel: '0', name: 'exterior_light' }, value: lightOn });
    if (lightPower != null) metrics.push({ name: 'sauna_power_watts', labels: { device: 'exterior', channel: '0', name: 'exterior_light' }, value: lightPower });

    devices.exterior = { on: lightOn === 1, apower: lightPower };
  }

  let relayOn = false;
  if (!primaryStatus) {
    console.error('Poll: could not reach primary Shelly');
  } else {
    relayOn = !!primaryStatus['switch:0']?.output;
    const heaterPower = primaryStatus['switch:0']?.apower ?? null;
    if (heaterPower != null) metrics.push({ name: 'sauna_power_watts', labels: { device: 'primary', channel: '0', name: 'heater_contactor' }, value: heaterPower });
    devices.primary = { on: relayOn, apower: heaterPower };
  }

  if (!secondaryStatus) {
    console.error('Poll: could not reach secondary Shelly');
  } else {
    const safetyOn = secondaryStatus['switch:0']?.output ? 1 : 0;
    metrics.push({ name: 'sauna_relay_on', labels: { device: 'secondary', channel: '0', name: 'safety_contactor' }, value: safetyOn });
    devices.secondary = { on: safetyOn === 1 };
  }

  // Temperature from HVAC device add-on probes: temperature:100=outdoor, temperature:101=indoor.
  let indoorTempF = null;
  if (!hvacStatus) {
    console.error('Poll: could not reach HVAC Shelly');
  } else {
    const outdoor = hvacStatus['temperature:100']?.tF ?? null;
    indoorTempF   = hvacStatus['temperature:101']?.tF ?? null;

    if (outdoor     != null) metrics.push({ name: 'sauna_temperature_fahrenheit', labels: { sensor: 'outdoor' }, value: outdoor     });
    if (indoorTempF != null) metrics.push({ name: 'sauna_temperature_fahrenheit', labels: { sensor: 'indoor'  }, value: indoorTempF });

    devices.temperature = { outdoor, indoor: indoorTempF };

    const hvac0On    = hvacStatus['switch:0']?.output ? 1 : 0;
    const hvac0Power = hvacStatus['switch:0']?.apower ?? null;
    const hvac1On    = hvacStatus['switch:1']?.output ? 1 : 0;
    const hvac1Power = hvacStatus['switch:1']?.apower ?? null;

    metrics.push({ name: 'sauna_relay_on', labels: { device: 'hvac', channel: '0', name: 'hvac_0' }, value: hvac0On });
    metrics.push({ name: 'sauna_relay_on', labels: { device: 'hvac', channel: '1', name: 'hvac_1' }, value: hvac1On });
    if (hvac0Power != null) metrics.push({ name: 'sauna_power_watts', labels: { device: 'hvac', channel: '0', name: 'hvac_0' }, value: hvac0Power });
    if (hvac1Power != null) metrics.push({ name: 'sauna_power_watts', labels: { device: 'hvac', channel: '1', name: 'hvac_1' }, value: hvac1Power });

    devices.hvac = {
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
    devices.led = { on: ledOn === 1, apower: ledPower };
  }

  // Evaluate session — only writes state KV when something changed.
  let sessionState = null;
  if (primaryStatus && hvacStatus) {
    const result = await evaluateSession(env, relayOn, indoorTempF);
    sessionState = result.state;
  }

  const sessionActive = sessionState?.sessionActive ?? false;
  const remainingS    = sessionActive ? computeRemainingS(sessionState) : 0;
  const sessionCount  = sessionState?.sessionCount ?? 0;

  metrics.push({ name: 'sauna_session_active',    labels: { device: 'primary' }, value: sessionActive ? 1 : 0 });
  metrics.push({ name: 'sauna_remaining_seconds', labels: { device: 'primary' }, value: remainingS            });
  metrics.push({ name: 'sauna_sessions_total',    labels: {},                    value: sessionCount          });
  // Heater is a 6kW resistive element — always full power when session active, zero otherwise.
  metrics.push({ name: 'sauna_power_watts',      labels: { device: 'primary', channel: '0', name: 'heater' }, value: sessionActive ? 6000 : 0 });
  metrics.push({ name: 'sauna_energy_kwh_total', labels: {}, value: sessionState?.energyKwhTotal ?? 0 });
  metrics.push({ name: 'sauna_energy_kwh_month', labels: {}, value: sessionState?.energyKwhMonth ?? 0 });

  if (devices.primary) devices.primary.sessionActive = sessionActive;

  // Read existing snap to get history, then write combined snap (1 write instead of 2).
  const snapRaw = await env.SAUNA_KV.get('snap');
  const prevSnap = snapRaw ? JSON.parse(snapRaw) : null;
  const history = prevSnap?.history ?? { entries: [] };

  history.entries.push({
    ts:      devices.ts,
    indoor:  devices.temperature?.indoor  ?? null,
    outdoor: devices.temperature?.outdoor ?? null,
    saunaOn: sessionActive,
    power:   devices.primary?.apower      ?? null,
  });
  if (history.entries.length > 288) history.entries = history.entries.slice(-288);

  await env.SAUNA_KV.put('snap', JSON.stringify({ devices, history }));
  if (metrics.length > 0) await writeMetrics(env, metrics);
}

// Cron entrypoint — kept as a thin wrapper so the name stays stable.
export async function pollTemperatures(env) {
  await pollAndSync(env);
}
