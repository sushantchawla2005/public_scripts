#!/bin/bash

LOG_FILE="/var/log/letsencrypt_check.log"
echo "Starting Let's Encrypt SSL & Cron Job Verification: $(date)" > "$LOG_FILE"

# Loop through only application folders with exactly 10-character names
for CERT_PATH in /home/master/applications/??????????/ssl/server.crt; do
    if [ -f "$CERT_PATH" ]; then
        APP_DIR=$(dirname "$(dirname "$CERT_PATH")")  # Get the parent directory (application folder)
        APP_FOLDER=$(basename "$APP_DIR")  # Extract application folder name
        ISSUER=$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null | grep -o "Let's Encrypt")

        if [[ "$ISSUER" == "Let's Encrypt" ]]; then
            echo "Application: $APP_FOLDER is using Let's Encrypt SSL" | tee -a "$LOG_FILE"

            # Check if renewal cron exists
            CRON_CHECK=$(grep -E "/var/cw/scripts/bash/letsencrypt.sh.*$APP_FOLDER" /etc/crontab)

            if [[ -n "$CRON_CHECK" ]]; then
                echo "   Auto-renewal cron found: $CRON_CHECK" | tee -a "$LOG_FILE"
            else
                echo "   No auto-renewal cron found for $APP_FOLDER" | tee -a "$LOG_FILE"
            fi
        else
            echo "Application: $APP_FOLDER is NOT using Let's Encrypt SSL" | tee -a "$LOG_FILE"
        fi
    fi
done

echo "Check completed at: $(date)" | tee -a "$LOG_FILE"
