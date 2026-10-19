#!/bin/bash

# Check if required arguments are provided
if [ "$#" -lt 3 ]; then
	echo "Usage: $0 <access_token> <server_id> <instance_type> [(Optional) slack_webhook_url]"
  exit 1
fi

ACCESS_TOKEN="$1"
SERVER_ID="$2"
INSTANCE_TYPE="$3"
SLACK_WEBHOOK="$4"

send_slack() {
  MESSAGE="$1"
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST -H 'Content-type: application/json' --data "{\"text\":\"$MESSAGE\"}" "$SLACK_WEBHOOK" > /dev/null
  else
    echo "$MESSAGE"
  fi
}

# Notify starting of server scaling
send_slack "🛠️ Starting server scaling for server ID: $SERVER_ID, instance type: $INSTANCE_TYPE. It may take upto 10 minutes to complete the operation."

# Check if token provided
if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
  send_slack "❌ Access token missing. Please provide a valid access token."
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
