#!/bin/bash

set -euo pipefail

SERVICE_NAME="mariadb"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
DROPIN_FILE="${DROPIN_DIR}/oom-and-kill-policy.conf"

SEND_SIGKILL="yes"
TIMEOUT_STOP="120"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this script as root."
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found."
    exit 1
fi

# Reload first in case drop-ins changed on disk already
systemctl daemon-reload || true

# Debian 11/12-safe service check
if ! systemctl status "$SERVICE_NAME" >/dev/null 2>&1; then
    if ! systemctl show "$SERVICE_NAME" -p FragmentPath --value 2>/dev/null | grep -q '/'; then
        echo "${SERVICE_NAME}.service not found."
        exit 1
    fi
fi

echo "MariaDB service found."

mkdir -p "$DROPIN_DIR"

if [ -f "$DROPIN_FILE" ] \
   && grep -qx "SendSIGKILL=${SEND_SIGKILL}" "$DROPIN_FILE" \
   && grep -qx "TimeoutStopSec=${TIMEOUT_STOP}" "$DROPIN_FILE"; then
    echo "Required settings already exist in $DROPIN_FILE. No update needed."
else
    if [ -f "$DROPIN_FILE" ]; then
        BACKUP_FILE="${DROPIN_FILE}.$(date +%F-%H%M%S).bak"
        cp -a "$DROPIN_FILE" "$BACKUP_FILE"
        echo "Backed up existing file to $BACKUP_FILE"
    fi

    cat > "$DROPIN_FILE" <<EOF
[Service]
SendSIGKILL=${SEND_SIGKILL}
TimeoutStopSec=${TIMEOUT_STOP}
EOF

    echo "Created/updated $DROPIN_FILE"
fi

systemctl daemon-reload

echo
echo "Effective MariaDB settings:"
systemctl show "$SERVICE_NAME" \
  -p OOMScoreAdjust \
  -p SendSIGKILL \
  -p TimeoutStopUSec \
  -p KillMode \
  -p Restart \
  -p DropInPaths

echo
echo "Note: OOMScoreAdjust applies to the live mariadbd process only after MariaDB restart."
echo "Restart during maintenance window:"
echo "systemctl restart mariadb"
