#!/bin/bash

set -euo pipefail

SERVICE_NAME="mariadb"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
DROPIN_FILE="${DROPIN_DIR}/oom-and-kill-policy.conf"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this script as root."
    exit 1
fi

if ! systemctl show "$SERVICE_NAME" -p FragmentPath --value 2>/dev/null |
    grep -q '/'; then
    echo "${SERVICE_NAME}.service not found."
    exit 1
fi

mkdir -p "$DROPIN_DIR"

cat > "$DROPIN_FILE" <<'EOF'
[Service]
SendSIGKILL=yes
TimeoutStopSec=120
EOF

echo "Overwritten: $DROPIN_FILE"

systemctl daemon-reload
echo "systemd configuration reloaded."

PID="$(systemctl show "$SERVICE_NAME" -p MainPID --value)"

if [ -z "$PID" ] || [ "$PID" -eq 0 ] || [ ! -e "/proc/$PID/oom_score_adj" ]; then
    echo "Running MariaDB process not found."
    exit 1
fi

echo 0 > "/proc/$PID/oom_score_adj"

echo
echo "MariaDB policy applied without restart:"
echo "PID: $PID"
echo "Runtime oom_score_adj: $(cat "/proc/$PID/oom_score_adj")"

systemctl show "$SERVICE_NAME" \
    -p OOMScoreAdjust \
    -p SendSIGKILL \
    -p TimeoutStopUSec \
    -p MainPID \
    -p DropInPaths
