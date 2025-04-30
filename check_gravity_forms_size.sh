#!/bin/bash

echo -e "Application\t\tDomain\t\t\t\tGravity Forms Folder Size"
echo "--------------------------------------------------------------------------"

for app_path in /home/master/applications/*; do
    # Proceed only if it's a real directory (not symlink or file)
    if [[ -d "$app_path" && ! -L "$app_path" ]]; then
        upload_path="$app_path/public_html/wp-content/uploads/gravity_forms"
        apache_conf="$app_path/conf/server.apache"

        # Check if gravityforms folder exists
        if [[ -d "$upload_path" ]]; then
            # Get disk usage (human-readable)
            size=$(du -sh "$upload_path" 2>/dev/null | cut -f1)

            # Extract domain from last line of apache config (trim comments and extract last field)
            if [[ -f "$apache_conf" ]]; then
                domain=$(tail -n 1 "$apache_conf" | sed 's/#.*//' | awk '{print $NF}')
            else
                domain="(no config)"
            fi

            app_name=$(basename "$app_path")
            printf "%-20s %-35s %-10s\n" "$app_name" "$domain" "$size"
        fi
    fi
done
