#!/bin/bash

LOG_FILE="/var/log/letsencrypt_check.log"
SERVER_IP=$(/usr/bin/curl -s -4 ifconfig.me)
SLACK_WEBHOOK_URL="$1"
shift  # Shift to get the rest of the args (ignored app folders)
IGNORED_APPS=("$@")

echo "Starting Let's Encrypt SSL & Cron Job Verification: $(date)" > "$LOG_FILE"

send_slack_notification() {
    local app_name="$1"
    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"🚨 *$SERVER_IP: $app_name* is using Let's Encrypt SSL but has no auto-renewal cron job!\"}" \
            "$SLACK_WEBHOOK_URL" > /dev/null
    fi
}

# Loop through only application folders with exactly 10-character names
for CERT_PATH in /home/master/applications/??????????/ssl/server.crt; do
    if [ -f "$CERT_PATH" ]; then
        APP_DIR=$(dirname "$(dirname "$CERT_PATH")")
        APP_FOLDER=$(basename "$APP_DIR")

        # Skip ignored applications
        if [[ " ${IGNORED_APPS[*]} " =~ " ${APP_FOLDER} " ]]; then
            echo "⚠️ Skipping ignored application: $APP_FOLDER" | tee -a "$LOG_FILE"
            continue
        fi

        if [ -d "$APP_DIR" ] && [ ! -L "$APP_DIR" ]; then
            ISSUER=$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null | grep -o "Let's Encrypt")

            if [[ "$ISSUER" == "Let's Encrypt" ]]; then
                echo "✅ Application: $APP_FOLDER is using Let's Encrypt SSL" | tee -a "$LOG_FILE"

                CRON_CHECK=$(grep -E "/var/cw/scripts/bash/letsencrypt.sh.*$APP_FOLDER" /etc/crontab)

                if [[ -n "$CRON_CHECK" ]]; then
                    echo "   ✅ Auto-renewal cron found: $CRON_CHECK" | tee -a "$LOG_FILE"
                else
                    echo "   ❌ No auto-renewal cron found for $APP_FOLDER" | tee -a "$LOG_FILE"
                    send_slack_notification "$APP_FOLDER"
                fi
            else
                echo "❌ Application: $APP_FOLDER is NOT using Let's Encrypt SSL" | tee -a "$LOG_FILE"
            fi
        fi
    fi
done

echo "Check completed at: $(date)" | tee -a "$LOG_FILE"
