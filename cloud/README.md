# Cloud Setup Guide

One-time external service setup before running `./deploy.sh`.

---

## Overview

The cloud layer adds two capabilities independent of Home Assistant:
- **SMS control** — text "on", "off", or "status" to your Twilio number
- **Remote dashboard** — Grafana Cloud showing session state, timer, and temperatures

Architecture: Shelly devices → Cloudflare Worker → Grafana Cloud (metrics + dashboards)

---

## Step 1 — Grafana Cloud

Grafana Cloud stores metrics and hosts dashboards — one service for both.

1. Create account at [grafana.com](https://grafana.com)
2. From your Grafana Cloud portal, open your stack
3. Click **"Send metrics"** → **Prometheus** section. You'll see:
   - **Remote Write Endpoint** → this is your `GRAFANA_METRICS_URL`
   - **Username** → this is your `GRAFANA_METRICS_USER` (a numeric ID, e.g. `123456`)
4. Click **"Generate now"** (or go to API Keys) to create an API key with **MetricsPublisher** role
5. Copy the key — you only see it once

Fill in `cloud/config.sh`:
```
GRAFANA_METRICS_URL="https://prometheus-prod-XX-prod-REGION.grafana.net/api/prom/push"
GRAFANA_METRICS_USER="123456"
```

Fill in `cloud/secrets.sh`:
```
GRAFANA_API_KEY="your-api-key"
```

### Dashboard setup

Create a dashboard with these panels (use the **Prometheus** data source, which is pre-configured in Grafana Cloud):

| Panel | PromQL query |
|-------|-------------|
| Session active | `sauna_session_active{device="primary"}` |
| Remaining time | `sauna_remaining_seconds{device="primary"}` |
| Indoor temp | `sauna_temperature_fahrenheit{sensor="indoor"}` |
| Outdoor temp | `sauna_temperature_fahrenheit{sensor="outdoor"}` |

To share without login: **Dashboard → Share → Public dashboard** → copy link → bookmark on phone.

---

## Step 2 — Shelly Cloud

1. Open the Shelly app on your phone
2. Add your primary Shelly (`shellypro2-0cb815fcaff4`) and exterior Shelly (`shellyplus2pm-3c8a1fe85f54`) to Shelly Cloud
3. In the app: **Settings → User Settings → Authorization cloud key**
4. Note the **server URL** and **auth key**

Fill in `cloud/config.sh`:
```
SHELLY_CLOUD_SERVER="https://shelly-103-eu.shelly.cloud"  # your server
```

Fill in `cloud/secrets.sh`:
```
SHELLY_AUTH_KEY="your-auth-key"
```

**Verify the RPC passthrough works** before deploying (replace values):
```bash
curl -X POST https://YOUR_SERVER/device/rpc \
  -d "auth_key=YOUR_KEY&id=shellypro2-0cb815fcaff4&method=Shelly.GetDeviceInfo&params={}"
```
Should return JSON with device info. If it doesn't, check server URL and auth key.

---

## Step 3 — Twilio

1. Create account at [twilio.com](https://twilio.com)
2. Buy a phone number (~$1/month) — US number, SMS capable
3. Note your **Auth Token** from the console (Account Info section)
4. Set the inbound SMS webhook URL after deploying the Worker:
   - Phone Numbers → Manage → Active Numbers → your number
   - Messaging → Webhook: `https://sauna.YOUR-SUBDOMAIN.workers.dev/sms`
   - Method: HTTP POST

Fill in `cloud/config.sh`:
```
AUTHORIZED_NUMBERS="+15551234567"  # your E.164 phone number
```

Fill in `cloud/secrets.sh`:
```
TWILIO_AUTH_TOKEN="your-auth-token"
```

---

## Step 4 — Cloudflare

1. Create account at [cloudflare.com](https://cloudflare.com)
2. Install wrangler: `npm install -g wrangler`
3. Log in: `wrangler login`
4. Find your workers.dev subdomain: dash.cloudflare.com → Workers → your subdomain

Fill in `cloud/config.sh`:
```
CLOUDFLARE_SUBDOMAIN="your-subdomain"
```

---

## Step 5 — Generate webhook secret

```bash
openssl rand -hex 32
```

Fill in `cloud/secrets.sh`:
```
WEBHOOK_SECRET="<output from above>"
```

---

## Step 6 — Deploy

```bash
./deploy.sh
```

Or deploy cloud first, verify, then deploy Shellys:
```bash
./deploy.sh --cloud
curl https://sauna.YOUR-SUBDOMAIN.workers.dev/status  # should return {"error":"no data yet"}
./deploy.sh --local
```

---

## Verify end-to-end

```
Text "status" to your Twilio number
→ Should reply "OFF." or "ON. X min remaining."
```

Check Grafana: within 5 minutes of the Shellys coming online you should see data in all panels.

---

## Files

```
cloud/
├── config.sh          — non-secret config (committed, you fill in)
├── secrets.sh         — secrets (gitignored, you create from example)
├── secrets.sh.example — template for secrets.sh
└── worker/
    ├── wrangler.toml  — Worker config (KV ID written here on first deploy)
    ├── package.json
    └── src/
        ├── index.js     — router + cron entry
        ├── sms.js       — SMS handling + Twilio signature validation
        ├── events.js    — Shelly webhook receiver + /status endpoint
        ├── shelly.js    — Shelly Cloud API calls
        ├── scheduled.js — device polling cron (every 5 min)
        └── metrics.js   — Grafana Cloud metrics writer
```
