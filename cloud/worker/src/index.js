/**
 * Sauna Cloud Worker
 *
 * Routes:
 *   POST /sms       — Twilio inbound SMS webhook
 *   POST /event     — Shelly primary script state webhook
 *   GET  /status    — JSON status (for debugging)
 *   GET  /control   — Web control panel (token auth via ?token=WEBHOOK_SECRET)
 *   POST /control   — Web control actions (on/off)
 *
 * Cron:
 *   Every 5 min — poll all Shelly devices, push metrics to Grafana Cloud
 */

import { handleSMS } from './sms.js';
import { handleEvent, handleStatus } from './events.js';
import { pollTemperatures } from './scheduled.js';
import { handleControl } from './control.js';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/sms')                  return handleSMS(request, env);
    if (url.pathname === '/event')                return handleEvent(request, env);
    if (url.pathname === '/status')               return handleStatus(request, env);
    if (url.pathname.startsWith('/control'))      return handleControl(request, env);
    if (url.pathname === '/sync') {
      await pollTemperatures(env);
      return new Response('ok');
    }

    return new Response('Not found', { status: 404 });
  },

  async scheduled(_event, env) {
    await pollTemperatures(env);
  },
};
