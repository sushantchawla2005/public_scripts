#!/bin/bash

# Check if required arguments are provided
if [ "$#" -lt 4 ]; then
	echo "Usage: $0 <email> <api_key> <server_id> <instance_type> [(Optional) slack_webhook_url]"
  exit 1
fi

EMAIL="$1"
API_KEY="$2"
SERVER_ID="$3"
INSTANCE_TYPE="$4"
SLACK_WEBHOOK="$5"

send_slack() {
  MESSAGE="$1"
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST -H 'Content-type: application/json' --data "{\"text\":\"$MESSAGE\"}" "$SLACK_WEBHOOK" > /dev/null
  else
    echo "$MESSAGE"
  fi
}

# Notify starting of server scaling
send_slack "🛠️ Starting server scaling for email: $EMAIL, server ID: $SERVER_ID, instance type: $INSTANCE_TYPE"

# Authenticate and get access token
ACCESS_TOKEN=$(curl -s -X POST "https://api.cloudways.com/api/v1/oauth/access_token" \
  -d "email=$EMAIL" \
  -d "api_key=$API_KEY" | jq -r '.access_token')

# Check if token retrieved successfully
if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
  send_slack "❌ Authentication failed. Please check your email and API key."
  exit 1
fi

# Trigger the scaling operation
RESPONSE=$(curl -s -X POST "https://api.cloudways.com/api/v1/server/scaleServer" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data "server_id=$SERVER_ID&instance_type=$INSTANCE_TYPE")

OPERATION_ID=$(echo "$RESPONSE" | jq -r '.operation_id')

# Check response
if [ "$OPERATION_ID" == "null" ] || [ -z "$OPERATION_ID" ]; then
  send_slack "❌ Scaling operation failed. Response: $RESPONSE"
  exit 1
else
  send_slack "✅ Scaling initiated successfully. Operation ID: $OPERATION_ID"
fi

# Check scaling operation status every 2 minutes, up to 10 times
for i in {1..10}; do
  sleep 60
  STATUS_RESPONSE=$(curl -s -X GET "https://api.cloudways.com/api/v1/operation/$OPERATION_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN")

  IS_COMPLETED=$(echo "$STATUS_RESPONSE" | jq -r '.operation.is_completed')
  STATUS_MESSAGE=$(echo "$STATUS_RESPONSE" | jq -r '.operation.message')

  if [ "$IS_COMPLETED" == "1" ]; then
    send_slack "🎉 Server scaling operation $OPERATION_ID completed successfully."
    exit 0
  elif [ "$IS_COMPLETED" == "0" ]; then
    continue
  elif [ "$IS_COMPLETED" == "-1" ]; then
    send_slack "⚠️ Server scaling operation $OPERATION_ID returned warning/error: $STATUS_MESSAGE"
    exit 1
  fi

done

send_slack "⚠️ Scaling operation $OPERATION_ID is still in progress after 10 minutes. Please check manually."
