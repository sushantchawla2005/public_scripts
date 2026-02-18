#!/bin/bash
set -euo pipefail

# ======================================
# Cloudways: Restart PHP-FPM via API v2
# - server_id optional argument
# - If not provided, extract from hostname
# ======================================

usage() {
  echo "Usage: $0 [server_id]"
  echo
  echo "If server_id is not provided, it will be auto-detected from hostname."
  echo
  echo "Required env vars:"
  echo "  CW_EMAIL   Cloudways account email"
  echo "  CW_API_KEY Cloudways API key"
}

# -------------------------
# Determine SERVER_ID
# -------------------------
if [[ $# -ge 1 ]]; then
  SERVER_ID="$1"
  echo "[INFO] Using provided server_id: $SERVER_ID"
else
  HOSTNAME_FULL=$(hostname)

  # Extract first numeric part before "-" or "."
  SERVER_ID=$(echo "$HOSTNAME_FULL" | sed -E 's/^([0-9]+).*$/\1/')

  if [[ -z "$SERVER_ID" ]]; then
    echo "[ERROR] Could not extract server_id from hostname: $HOSTNAME_FULL"
    exit 1
  fi

  echo "[INFO] Auto-detected server_id: $SERVER_ID (from hostname: $HOSTNAME_FULL)"
fi

# -------------------------
# Validate credentials
# -------------------------
if [[ -z "${CW_EMAIL:-}" || -z "${CW_API_KEY:-}" ]]; then
  echo "[ERROR] CW_EMAIL and CW_API_KEY must be set"
  exit 1
fi

# -------------------------
# Generate OAuth token
# -------------------------
echo "[INFO] Generating Cloudways API token..."

OATH=$(
  curl -sS -X POST "https://api.cloudways.com/api/v2/oauth/access_token" \
    -d "email=$CW_EMAIL" \
    -d "api_key=$CW_API_KEY" \
  | awk -F'"' '/access_token/{print $4}'
)

if [[ -z "${OATH:-}" ]]; then
  echo "[ERROR] Failed to generate API token"
  exit 1
fi

echo "[OK] Token generated"

# -------------------------
# Detect PHP version
# -------------------------
echo "[INFO] Detecting PHP-FPM service name..."

SETTINGS_JSON=$(
  curl -sS -X GET \
    --header "Accept: application/json" \
    --header "Authorization: Bearer $OATH" \
    "https://api.cloudways.com/api/v2/server/manage/settings?server_id=$SERVER_ID"
)

PHP_VERSION=$(
  echo "$SETTINGS_JSON" \
  | sed -nE 's/.*"php"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
  | head -n1
)

if [[ -z "${PHP_VERSION:-}" ]]; then
  echo "[ERROR] Could not detect PHP version"
  echo "[DEBUG] Response: $SETTINGS_JSON"
  exit 1
fi

SERVICE="php${PHP_VERSION}-fpm"

echo "[INFO] PHP version detected: $PHP_VERSION"
echo "[INFO] Restarting service: $SERVICE"

# -------------------------
# Restart PHP-FPM
# -------------------------
RESPONSE=$(
  curl -sS -X POST \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --header "Accept: application/json" \
    --header "Authorization: Bearer $OATH" \
    -d "server_id=$SERVER_ID&service=$SERVICE&state=restart" \
    "https://api.cloudways.com/api/v2/service/state"
)

# -------------------------
# Evaluate response
# -------------------------
if echo "$RESPONSE" | grep -Eq '"status"[[:space:]]*:[[:space:]]*true'; then
  echo "[SUCCESS] Restart request accepted for $SERVICE on server $SERVER_ID"
elif echo "$RESPONSE" | grep -Eq '"service_status"[[:space:]]*:[[:space:]]*\{[^}]*"status"[[:space:]]*:[[:space:]]*"(running|restarting)"'; then
  CUR_STATE=$(echo "$RESPONSE" | sed -nE 's/.*"service_status"[[:space:]]*:[[:space:]]*\{[^}]*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
  echo "[SUCCESS] $SERVICE is \"$CUR_STATE\" on server $SERVER_ID"
else
  echo "[ERROR] Restart call did not return a success indicator"
  echo "[ERROR] Response: $RESPONSE"
  exit 1
fi
