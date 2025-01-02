#!/bin/bash

# Check if the file path is provided as the first argument
if [ -z "$1" ]; then
  echo "Usage: $0 <path_to_ip_file>"
  exit 1
fi

# Assign the file path to a variable
IP_FILE="$1"

# Check if the file exists
if [ ! -f "$IP_FILE" ]; then
  echo "File not found: $IP_FILE"
  exit 1
fi

# Loop through each line (IP) in the file and run the command
while IFS= read -r ip; do
  # Skip empty lines
  if [ -n "$ip" ]; then
    imunify360-agent whitelist ip add "$ip"
    echo "Whitelisted IP: $ip"
  fi
done < "$IP_FILE"
