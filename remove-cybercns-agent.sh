#!/bin/bash

# Define variables
RULES_FILE="/etc/shorewall/rules"
BACKUP_FILE="/etc/shorewall/rules.bak"
TARGET_LINE_PATTERN="ACCEPT[[:space:]]*net:70.34.254.208,70.34.248.226,70.34.252.117,70.34.243.47,70.34.250.223,70.34.255.68,64.176.68.187[[:space:]]*fw[[:space:]]*tcp[[:space:]]*4222"

echo "Backing up Shorewall rules..." 
cp "$RULES_FILE" "$BACKUP_FILE"

echo "Removing the specific ACCEPT rule..." 
sed -i "/$TARGET_LINE_PATTERN/d" "$RULES_FILE"

echo "Deleting cybercnsagent_linux binaries from /home/master/applications/..." 
find /home/master/applications/ -type f -name "cybercnsagent_linux" -exec rm -f {} \;

echo "Reloading Shorewall..." 
shorewall reload

echo "Cleanup and reload complete."
