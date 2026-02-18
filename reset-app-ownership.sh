#!/bin/bash
set -euo pipefail

# ==========================================================
# Cloudways: Reset application ownership to sys_user via API v2
#
# Optional args:
#   $1 = server_id (optional, numeric)
#   $2 = app_id    (optional, numeric)
#
# Auto-detect:
#   server_id: from hostname (1234567.cloudwaysapps.com or 1234567-xxxx.cloudwaysapps.com)
#   app_folder: from pwd using either:
#       /home/<server_id>.cloudwaysapps.com/<app_folder>/...
#       /home/master/applications/<app_folder>/...
#     or fallback to whoami (often equals app_folder inside app user)
#   app_id: from one of:
#       <base>/public_html/conf/server.apache
#       <base>/conf/server.apache
#       <base>/conf/server.conf
#     by extracting last numeric chunk in ServerName/ServerAlias:
#       wordpress-1234567-9876543.cloudwaysapps.com -> 9876543
#
# Requires env vars:
#   CW_EMAIL, CW_API_KEY
# ==========================================================

usage() {
  echo "Usage: $0 [server_id] [app_id]"
  echo
  echo "If args are omitted/invalid, script auto-detects server_id/app_id."
  echo
  echo "Required env vars:"
  echo "  CW_EMAIL   Cloudways account email"
  echo "  CW_API_KEY Cloudways API key"
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# -------------------------
# Validate credentials
# -------------------------
if [[ -z "${CW_EMAIL:-}" || -z "${CW_API_KEY:-}" ]]; then
  echo "[ERROR] CW_EMAIL and CW_API_KEY must be set"
  usage
  exit 1
fi

# -------------------------
# server_id
# -------------------------
SERVER_ID=""
if is_int "${1:-}"; then
  SERVER_ID="$1"
  echo "[INFO] Using provided server_id: $SERVER_ID"
else
  [[ -n "${1:-}" ]] && echo "[WARN] Provided server_id '$1' is not numeric; falling back to hostname detection"
  HOSTNAME_FULL="$(hostname)"
  SERVER_ID="$(echo "$HOSTNAME_FULL" | sed -E 's/^([0-9]+).*$/\1/')"
  if ! is_int "$SERVER_ID"; then
    echo "[ERROR] Could not extract numeric server_id from hostname: $HOSTNAME_FULL"
    exit 1
  fi
  echo "[INFO] Auto-detected server_id: $SERVER_ID (from hostname: $HOSTNAME_FULL)"
fi

# -------------------------
# app_id (arg or detect)
# -------------------------
APP_ID=""
if is_int "${2:-}"; then
  APP_ID="$2"
  echo "[INFO] Using provided app_id: $APP_ID"
fi

# Helper: detect app folder from pwd or whoami fallback
detect_app_folder() {
  local p="$1"
  local app=""

  # Case A: /home/<server_id>.cloudwaysapps.com/<app_folder>/...
  app="$(echo "$p" | sed -nE 's#^/home/[0-9]+\.cloudwaysapps\.com/([^/]+)(/.*)?$#\1#p' | head -n1)"
  if [[ -n "${app:-}" ]]; then
    echo "$app"
    return 0
  fi

  # Case B: /home/master/applications/<app_folder>/...
  app="$(echo "$p" | sed -nE 's#^/home/master/applications/([^/]+)(/.*)?$#\1#p' | head -n1)"
  if [[ -n "${app:-}" ]]; then
    echo "$app"
    return 0
  fi

  # Case C: fallback to whoami (often equals app_folder)
  app="$(whoami 2>/dev/null || true)"
  if [[ -n "${app:-}" && "$app" != "root" && "$app" != "master" ]]; then
    echo "$app"
    return 0
  fi

  return 1
}

# Helper: find a conf file that contains ServerName/ServerAlias
find_conf_file() {
  local candidates=("$@")
  local f=""
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]] && grep -qE '^(ServerName|ServerAlias)\s+' "$f"; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# Helper: extract app_id from conf file
extract_app_id_from_conf() {
  local file="$1"
  awk '
    BEGIN{app=""}
    $1 ~ /^Server(Name|Alias)$/ {
      s=$2
      gsub(/^www\./,"",s)
      if (match(s, /-([0-9]+)\./, m)) { app=m[1] }
    }
    END{print app}
  ' "$file"
}

# Detect app_folder + conf file + app_id if not provided
if [[ -z "${APP_ID:-}" ]]; then
  PWD_PATH="$(pwd)"
  APP_FOLDER="$(detect_app_folder "$PWD_PATH" || true)"

  if [[ -z "${APP_FOLDER:-}" ]]; then
    echo "[ERROR] Could not detect application folder from pwd or whoami"
    echo "[DEBUG] pwd: $PWD_PATH"
    exit 1
  fi

  echo "[INFO] Detected app folder: $APP_FOLDER (from context: pwd/whoami)"

  # Build base dirs to try
  BASE_A="/home/${SERVER_ID}.cloudwaysapps.com/${APP_FOLDER}"
  BASE_B="/home/master/applications/${APP_FOLDER}"

  # Candidate conf paths (try both base layouts)
  CANDIDATES=(
    "${BASE_A}/public_html/conf/server.apache"
    "${BASE_A}/conf/server.apache"
    "${BASE_A}/conf/server.conf"
    "${BASE_B}/public_html/conf/server.apache"
    "${BASE_B}/conf/server.apache"
    "${BASE_B}/conf/server.conf"
  )

  CONF_FILE="$(find_conf_file "${CANDIDATES[@]}" || true)"
  if [[ -z "${CONF_FILE:-}" ]]; then
    echo "[ERROR] Could not find a usable conf file containing ServerName/ServerAlias."
    echo "[HINT] Looked in:"
    for c in "${CANDIDATES[@]}"; do echo "  - $c"; done
    exit 1
  fi

  echo "[INFO] Using conf file: $CONF_FILE"

  APP_ID="$(extract_app_id_from_conf "$CONF_FILE" | head -n1)"

  if ! is_int "${APP_ID:-}"; then
    echo "[ERROR] Could not extract numeric app_id from: $CONF_FILE"
    echo "[HINT] Expected ServerName like: wordpress-${SERVER_ID}-5739215.cloudwaysapps.com"
    exit 1
  fi

  echo "[INFO] Auto-detected app_id: $APP_ID"
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
# Reset ownership to sys_user
# -------------------------
echo "[INFO] Resetting ownership to sys_user for server_id=$SERVER_ID app_id=$APP_ID ..."

RESPONSE=$(
  curl -sS -X POST \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --header "Accept: application/json" \
    --header "Authorization: Bearer $OATH" \
    -d "server_id=$SERVER_ID&app_id=$APP_ID&ownership=sys_user" \
    "https://api.cloudways.com/api/v2/app/manage/reset_permissions"
)

# -------------------------
# Evaluate response
# -------------------------
if echo "$RESPONSE" | grep -Eq '"status"[[:space:]]*:[[:space:]]*true'; then
  sleep 15
  echo "[SUCCESS] Ownership reset initiated (sys_user) for app_id=$APP_ID on server_id=$SERVER_ID"
else
  if echo "$RESPONSE" | grep -qiE '"error"|errors|invalid|unauthorized|forbidden'; then
    echo "[ERROR] API indicated failure"
    echo "[ERROR] Response: $RESPONSE"
    exit 1
  fi
  echo "[INFO] API response: $RESPONSE"
  echo "[SUCCESS] Ownership reset request sent for app_id=$APP_ID on server_id=$SERVER_ID"
fi
