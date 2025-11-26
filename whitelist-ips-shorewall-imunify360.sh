#!/bin/bash
#
# Whitelist IPs in Shorewall ALLOW_SSH + Imunify360
# - First argument : IP list file
# - Second argument: Slack webhook URL
# - Sends Slack alert on:
#     * Any actual script error (trap)
#     * Any invalid IP entries in the list
# - Reloads Shorewall ONLY if at least one new IP was added
#

set -euo pipefail

# -------------------------
# INPUT ARGUMENTS
# -------------------------
LIST_FILE="${1:-}"
SLACK_WEBHOOK="${2:-}"
MACRO_FILE="/etc/shorewall/macro.ALLOW_SSH"

# -------------------------
# FETCH SERVER PUBLIC IP
# -------------------------
SERVER_IP=$(curl -s -4 http://ifconfig.me || echo "UNKNOWN")

# -------------------------
# STATE FLAGS
# -------------------------
SHOREWALL_CHANGED=0
INVALID_IPS=()

# -------------------------
# SLACK ALERT FUNCTION
# -------------------------
send_slack_alert() {
    local ERROR_MSG="$1"
    local NOW
    NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')

    if [[ -n "${SLACK_WEBHOOK}" ]]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{
                \"text\":\":rotating_light: *SSH Whitelist Script Error*\n*Server IP:* ${SERVER_IP}\n*Date:* ${NOW}\n*Error:* ${ERROR_MSG}\"
            }" \
            "${SLACK_WEBHOOK}" >/dev/null 2>&1 || true
    fi
}

# -------------------------
# GLOBAL ERROR HANDLER
# -------------------------
trap 'send_slack_alert "Script failed on line $LINENO."' ERR

# -------------------------
# SIMPLE IPv4 / IPv4-CIDR VALIDATOR
# -------------------------
is_valid_ipv4() {
    local ip="$1"

    [[ -z "$ip" ]] && return 1

    # Match IPv4 or IPv4/CIDR
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        IFS='/.' read -r o1 o2 o3 o4 prefix <<<"$ip"

        for o in "$o1" "$o2" "$o3" "$o4"; do
            if ! [[ "$o" =~ ^[0-9]+$ ]] || [[ "$o" -lt 0 || "$o" -gt 255 ]]; then
                return 1
            fi
        done

        if [[ -n "${prefix:-}" ]]; then
            if ! [[ "$prefix" =~ ^[0-9]+$ ]] || [[ "$prefix" -lt 0 || "$prefix" -gt 32 ]]; then
                return 1
            fi
        fi

        # Don’t allow 0.0.0.0/0 in whitelist
        [[ "$ip" == "0.0.0.0/0" ]] && return 1

        return 0
    fi

    return 1
}

# -------------------------
# VALIDATION
# -------------------------
if [[ -z "$LIST_FILE" ]]; then
    send_slack_alert "No whitelist file provided as first argument."
    echo "Usage: $0 /path/to/ips.txt https://hooks.slack.com/..."
    exit 1
fi

if [[ -z "$SLACK_WEBHOOK" ]]; then
    send_slack_alert "No Slack webhook URL provided as second argument."
    echo "Usage: $0 /path/to/ips.txt https://hooks.slack.com/..."
    exit 1
fi

if [[ ! -f "$LIST_FILE" ]]; then
    send_slack_alert "Whitelist file not found: $LIST_FILE"
    echo "ERROR: Whitelist file not found: $LIST_FILE"
    exit 1
fi

if [[ ! -f "$MACRO_FILE" ]]; then
    send_slack_alert "Shorewall macro file not found: $MACRO_FILE"
    echo "ERROR: Shorewall macro file not found: $MACRO_FILE"
    exit 1
fi

echo "Processing IP list: $LIST_FILE"
echo "------------------------------------------------------"

# -------------------------
# MAIN PROCESS
# -------------------------
while IFS= read -r IP; do
    # Strip comments and trim whitespace
    IP="${IP%%#*}"
    IP="$(echo "$IP" | xargs || true)"

    # Skip empty lines
    [[ -z "$IP" ]] && continue

    # Validate IPv4 / IPv4-CIDR
    if ! is_valid_ipv4 "$IP"; then
        echo "Skipping invalid IP entry: $IP"
        INVALID_IPS+=("$IP")
        continue
    fi

    ###################################
    # SHOREWALL WHITELIST
    ###################################
    if ! grep -qF "PARAM     net:${IP}" "$MACRO_FILE"; then
        echo "Adding to Shorewall ALLOW_SSH → $IP"
        echo "PARAM     net:${IP}" >> "$MACRO_FILE"
        SHOREWALL_CHANGED=1
    else
        echo "Already in Shorewall → $IP"
    fi

    ###################################
    # IMUNIFY360 WHITELIST
    ###################################
    echo "Whitelisting in Imunify360 → $IP"
    sudo /usr/bin/imunify360-agent ip-list local add "$IP" --purpose white

done < "$LIST_FILE"

# -------------------------
# SEND ALERT IF INVALID IPs FOUND
# -------------------------
if [[ ${#INVALID_IPS[@]} -gt 0 ]]; then
    send_slack_alert "Invalid IP entries in whitelist file ${LIST_FILE}: ${INVALID_IPS[*]}"
fi

# -------------------------
# RELOAD SHOREWALL ONLY IF CHANGED
# -------------------------
if [[ "$SHOREWALL_CHANGED" -eq 1 ]]; then
    echo "Shorewall configuration changed. Reloading Shorewall..."
    if command -v shorewall >/dev/null 2>&1; then
        shorewall reload || shorewall restart
    else
        send_slack_alert "shorewall command not found — cannot reload firewall."
    fi
else
    echo "No new IPs added to Shorewall. Skipping reload."
fi

echo "Done."
