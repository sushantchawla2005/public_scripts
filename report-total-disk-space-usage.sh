#!/bin/bash

# Define paths
WEBROOT_DIR="/home/master/applications"
DB_DIR="/var/lib/mysql"
IP=$(/bin/curl -s -4 ifconfig.me)

# Check if required directories exist
if [[ ! -d "$WEBROOT_DIR" ]]; then
    echo "❌ Error: Webroot directory $WEBROOT_DIR does not exist."
    exit 1
fi

if [[ ! -d "$DB_DIR" ]]; then
    echo "❌ Error: Database directory $DB_DIR does not exist."
    exit 1
fi

# Print header
echo "Total Webroot & Database Disk Usage"
echo "-----------------------------------------------"
printf "%-20s %-15s %-15s\n" "Server IP" "Webroot Size" "Database Size"
echo "-----------------------------------------------"

# Loop through each application
    WEBROOT_SIZE=$(du -sh "$WEBROOT_DIR/" 2>/dev/null | awk '{print $1}')
    DB_SIZE=$(du -sh "$DB_DIR/" 2>/dev/null | awk '{print $1}')

    # If sizes are empty, set them to "0B"
    WEBROOT_SIZE=${WEBROOT_SIZE:-"0B"}
    DB_SIZE=${DB_SIZE:-"0B"}

    # Print results
    printf "%-20s %-15s %-15s\n" "${IP}" "$WEBROOT_SIZE" "$DB_SIZE"

echo "-----------------------------------------------"
