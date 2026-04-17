#!/bin/bash
# =============================================================================
# CLOUD CONFIGURATION
# =============================================================================
# Fill in your values below, then run ./deploy.sh
#
# This file is committed to git. Do NOT put secrets here.
# Secrets go in cloud/secrets.sh (gitignored).
# =============================================================================

# --- Cloudflare Worker ---
# Your workers.dev subdomain (find at dash.cloudflare.com → Workers)
CLOUDFLARE_SUBDOMAIN="emiddleton"
WORKER_NAME="sauna"
WORKER_URL="https://${WORKER_NAME}.${CLOUDFLARE_SUBDOMAIN}.workers.dev"

# Cloudflare KV namespace ID — populated automatically on first deploy-cloud.sh run.
# If it's already been created, paste the ID here.
KV_NAMESPACE_ID=""

# --- Shelly Cloud ---
# Find server URL and auth key at: home.shelly.cloud → Settings → User Settings → Authorization cloud key
# Server varies by region: shelly-103-eu.shelly.cloud (EU), shelly-103-us.shelly.cloud (US), etc.
SHELLY_CLOUD_SERVER="https://shelly-142-eu.shelly.cloud"
# Shelly Cloud API uses the short hex ID (no model prefix).
# Local LAN access uses the full hostname (shellypro2-0cb815fcaff4.local).
PRIMARY_DEVICE_ID="0cb815fcaff4"
SECONDARY_DEVICE_ID="0cb815fc96dc"
EXTERIOR_DEVICE_ID="3c8a1fe851a4"
HVAC_DEVICE_ID="3c8a1fe85f54"
LED_DEVICE_ID="30c922571550"

# --- Grafana Cloud ---
# From Grafana Cloud → your stack → "Send metrics" → Prometheus section:
#   - Remote Write Endpoint → GRAFANA_METRICS_URL
#   - Username              → GRAFANA_METRICS_USER  (numeric, e.g. 123456)
# API key goes in cloud/secrets.sh (GRAFANA_API_KEY).
GRAFANA_METRICS_URL="https://prometheus-prod-67-prod-us-west-0.grafana.net/api/prom/push"
GRAFANA_METRICS_USER="3121540"

# Prometheus datasource UID in your Grafana instance.
# Find it: Grafana → Connections → Data sources → Prometheus → check the URL (uid=xxxxx)
# or: Administration → Service accounts → set Admin role → deploy script will auto-detect it.
GRAFANA_DATASOURCE_UID="grafanacloud-prom"

# --- Twilio ---
# Your Twilio phone number (the one people text TO)
TWILIO_NUMBER="+15415085787"

# Authorized users go in cloud/secrets.sh (AUTHORIZED_USERS) — kept out of git
# because phone numbers are personal data.
