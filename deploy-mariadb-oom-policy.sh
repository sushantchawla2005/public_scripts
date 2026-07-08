#!/bin/bash

set -euo pipefail

SERVICE_NAME="mariadb"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
DROPIN_FILE="${DROPIN_DIR}/oom-and-kill-policy.conf"

OOM_SCORE="-800"
SEND_SIGKILL="yes"
TIMEOUT_STOP="120"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this script as root."
    exit 1
fi

command -v systemctl >/dev/null 2>&1 || {
    echo "systemctl is required but not found."
    exit 1
}

# Reliable service existence check
if ! systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "${SERVICE_NAME}.service not found or not readable by systemctl."
    echo
    echo "Debug:"
    systemctl status "$SERVICE_NAME" --no-pager || true
    exit 1
fi

echo "MariaDB service found."
echo

echo "Creating systemd drop-in directory if missing..."
mkdir -p "$DROPIN_DIR"

NEEDS_UPDATE=0

if [ -f "$DROPIN_FILE" ]; then
    if grep -q "^OOMScoreAdjust=${OOM_SCORE}$" "$DROPIN_FILE" \
        && grep -q "^SendSIGKILL=${SEND_SIGKILL}$" "$DROPIN_FILE" \
        && grep -q "^TimeoutStopSec=${TIMEOUT_STOP}$" "$DROPIN_FILE"; then
        echo "Required MariaDB override is already present in:"
        echo "$DROPIN_FILE"
        echo "No changes needed."
    else
        NEEDS_UPDATE=1
        BACKUP_FILE="${DROPIN_FILE}.$(date +%F-%H%M%S).bak"
        echo "Existing managed override found but values differ."
        echo "Backing up current file to:"
        echo "$BACKUP_FILE"
        cp -a "$DROPIN_FILE" "$BACKUP_FILE"
    fi
else
    NEEDS_UPDATE=1
fi

if [ "$NEEDS_UPDATE" -eq 1 ]; then
    cat > "$DROPIN_FILE" <<EOF
[Service]
OOMScoreAdjust=${OOM_SCORE}
SendSIGKILL=${SEND_SIGKILL}
TimeoutStopSec=${TIMEOUT_STOP}
EOF

    echo "Created/updated MariaDB override:"
    echo "$DROPIN_FILE"
fi

echo
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo
echo "Current effective MariaDB settings:"
systemctl show "$SERVICE_NAME" \
    -p OOMScoreAdjust \
    -p SendSIGKILL \
    -p TimeoutStopUSec \
    -p KillMode \
    -p Restart \
    -p DropInPaths

echo
echo "Done."
echo
echo "Important:"
echo "systemd has loaded the override, but OOMScoreAdjust applies to the MariaDB process only after MariaDB is restarted."
echo
echo "To apply it to the running MariaDB process, run during a maintenance window:"
echo
echo "systemctl restart mariadb"
echo
echo "After restart, verify:"
echo
echo "pid=\$(pidof mariadbd)"
echo "cat /proc/\$pid/oom_score_adj"
