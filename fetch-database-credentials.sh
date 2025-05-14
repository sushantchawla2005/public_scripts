#!/bin/bash

# Usage: ./fetch_database_credentials.sh <server_ip> <API_EMAIL> <API_KEY>

SERVER_IP="$1"
API_EMAIL="$2"
API_KEY="$3"

if [ "$#" -ne 3 ]; then
  echo "❌ Usage: $0 <server_ip> <API_EMAIL> <API_KEY>"
  exit 1
fi


# Authenticate and get access token
ACCESS_TOKEN=$(curl -s -X POST "https://api.cloudways.com/api/v1/oauth/access_token" \
  -d "email=$API_EMAIL&api_key=$API_KEY" | jq -r '.access_token')

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "❌ Authentication failed."
  exit 1
fi

# Get server data
SERVER_DATA=$(curl -s -X GET "https://api.cloudways.com/api/v1/server" \
  -H "Authorization: Bearer $ACCESS_TOKEN")

# Optional: Print server label for clarity
SERVER_LABEL=$(echo "$SERVER_DATA" | jq -r --arg IP "$SERVER_IP" '.servers[] | select(.public_ip == $IP) | .label')

if [[ -z "$SERVER_LABEL" ]]; then
  echo "❌ No server found with IP: $SERVER_IP"
  exit 1
fi

echo "✅ Server: $SERVER_LABEL ($SERVER_IP)"
echo ""
echo "🔐 MySQL Users and Passwords for Applications:"
echo "----------------------------------------------"

# Directly filter by public_ip and list apps' DB credentials
echo "$SERVER_DATA" | jq -r --arg IP "$SERVER_IP" '
  .servers[] | select(.public_ip == $IP) | .apps[] |
  "\(.mysql_user):\(.mysql_password)"'
