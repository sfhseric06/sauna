/**
 * Shelly Cloud API helpers.
 *
 * The Shelly Cloud API uses v1-style control endpoints, not raw RPC passthrough:
 *   /device/relay/control  — turn a switch/relay on or off
 *   /device/light/control  — turn a light component on or off
 *   /device/status         — get device status (read-only)
 *   /device/all_status     — get all device statuses
 *
 * NOTE: /device/rpc does NOT forward arbitrary Gen2 RPC methods through Shelly Cloud.
 * Script.Eval is not available via cloud — sauna control uses direct relay/control
 * on both contactors (primary + secondary) until local script deployment.
 *
 * Rate limit: ~1 request/sec per auth_key. Commands are spaced with a short delay
 * when multiple devices need to be controlled in sequence.
 */

async function cloudPost(env, endpoint, params) {
  const body = new URLSearchParams({ auth_key: env.SHELLY_AUTH_KEY, ...params });
  let resp;
  try {
    resp = await fetch(`${env.SHELLY_CLOUD_SERVER}${endpoint}`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body:    body.toString(),
    });
  } catch (err) {
    console.error(`Shelly Cloud ${endpoint} fetch error:`, err);
    return null;
  }
  if (!resp.ok) {
    console.error(`Shelly Cloud ${endpoint} HTTP error:`, resp.status);
    return null;
  }
  const data = await resp.json();
  if (data.isok === false) {
    console.error(`Shelly Cloud ${endpoint} error:`, JSON.stringify(data.errors));
    return null;
  }
  return data;
}

// Turn a switch/relay on or off (Plus 2PM, Pro 2, etc.)
export async function shellySetSwitch(env, deviceId, channel, on) {
  const result = await cloudPost(env, '/device/relay/control', {
    id:      deviceId,
    channel: String(channel),
    turn:    on ? 'on' : 'off',
  });
  return result !== null;
}

// Turn a light component on or off (Plus RGBW PM, etc.)
export async function shellySetLight(env, deviceId, channel, on) {
  const result = await cloudPost(env, '/device/light/control', {
    id:      deviceId,
    channel: String(channel),
    turn:    on ? 'on' : 'off',
  });
  return result !== null;
}

// Turn the sauna ON: both contactors must close (primary then secondary).
// This bypasses the Shelly script (Script.Eval not available via Cloud API).
// Safety: firmware auto-off fires at 61 min on both controllers independently.
export async function shellySetSauna(env, on) {
  if (!on) {
    // Turn off secondary first (safe order: remove power before opening primary)
    const ok1 = await shellySetSwitch(env, env.SECONDARY_DEVICE_ID, 0, false);
    await new Promise(r => setTimeout(r, 1200)); // respect rate limit
    const ok2 = await shellySetSwitch(env, env.PRIMARY_DEVICE_ID, 0, false);
    return ok1 && ok2;
  } else {
    // Turn on primary first, then secondary
    const ok1 = await shellySetSwitch(env, env.PRIMARY_DEVICE_ID, 0, true);
    await new Promise(r => setTimeout(r, 1200)); // respect rate limit
    const ok2 = await shellySetSwitch(env, env.SECONDARY_DEVICE_ID, 0, true);
    return ok1 && ok2;
  }
}

// Get status for a specific device. Returns device_status object or null.
export async function shellyCloudDeviceStatus(env, deviceId) {
  const data = await cloudPost(env, '/device/status', { id: deviceId });
  return data?.data?.device_status ?? null;
}

// Get primary device status and return a normalized session state object.
// Used by SMS handler as fallback when KV is stale.
export async function shellyCloudStatus(env) {
  const status = await shellyCloudDeviceStatus(env, env.PRIMARY_DEVICE_ID);
  if (!status) return null;
  return {
    sessionActive: status['switch:0']?.output ?? false,
    remainingS:    null, // not in status API; comes from primary script webhook
    ts:            Date.now(),
  };
}
