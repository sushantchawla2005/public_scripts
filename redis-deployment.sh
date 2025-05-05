#!/bin/bash

# ====== CONFIG ======
REDIS_CONF="/etc/redis/redis.conf"
SHOREWALL_RULES="/etc/shorewall/rules"
IP_LIST_FILE="$1"
LOG_FILE="/var/log/redis_firewall_update_$(date +%F_%H-%M-%S).log"
BACKUP_PATH="/etc/redis/redis.conf.bak.$(date +%F_%H-%M-%S)"

# ====== INPUT VALIDATION ======
if [[ ! -f "$IP_LIST_FILE" ]]; then
    echo "IP list file missing or invalid. Usage: $0 <ip_list_file>" | tee -a "$LOG_FILE"
    exit 1
fi

# Start logging
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Log file: $LOG_FILE"
echo "==================== Starting Task @ $(date) ===================="

# ====== REDIS CONFIG UPDATE ======
echo "Checking Redis configuration..."
BIND_OK=$(grep -E '^bind\s+0\.0\.0\.0' "$REDIS_CONF")
PROTECTED_OK=$(grep -E '^protected-mode\s+no' "$REDIS_CONF")

if [[ -n "$BIND_OK" && -n "$PROTECTED_OK" ]]; then
    echo "Redis already configured properly."
else
    echo "Backing up Redis config to $BACKUP_PATH"
    sudo cp "$REDIS_CONF" "$BACKUP_PATH"

    echo "🔧 Updating Redis config..."
    sudo sed -i \
        -e 's/^bind .*/bind 0.0.0.0/' \
        -e 's/^protected-mode .*/protected-mode no/' "$REDIS_CONF"

    echo "Updated Redis config:"
    grep -E '^bind|^protected-mode' "$REDIS_CONF"

    echo "Restarting Redis..."
    sudo systemctl restart redis

    if systemctl is-active --quiet redis; then
        echo "Redis restarted successfully."
    else
        echo "Redis restart failed. Please check logs."
        exit 1
    fi
fi

# ====== PROCESS IP WHITELISTING ======
echo "Processing IP list from $IP_LIST_FILE..."

while IFS= read -r IP; do
    if [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then

        ## --- WHITELIST IN IMUNIFY360 ---
        echo "Whitelisting $IP in Imunify360..."
        sudo /usr/bin/imunify360-agent ip-list local add "$IP" --purpose white

        ## --- ADD TO SHOREWALL ---
        RULE="ACCEPT          net:${IP}       fw      tcp     6379    #Redis"
        if grep -qE "net:${IP}.*tcp\s+6379" "$SHOREWALL_RULES"; then
            echo "$IP already allowed in Shorewall"
        else
            echo "Adding $IP to Shorewall rules"
            echo "$RULE" | sudo tee -a "$SHOREWALL_RULES" > /dev/null
        fi

    else
        echo "Invalid IP format skipped: $IP"
    fi
done < "$IP_LIST_FILE"

# ====== RELOAD SHOREWALL and IMUNIFY360 ======
echo "Reloading Shorewall and Imunify360 firewalls..."
sudo /sbin/shorewall update && sudo /etc/init.d/shorewall restart && sudo /usr/bin/imunify360-agent reload-lists

echo "All tasks completed successfully."
echo "==================== Completed @ $(date) ===================="
