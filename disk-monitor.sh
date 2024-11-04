#!/bin/bash
# Author: Sushant Chawla
# Script to monitor all mounted partitions and 
# send alert on Slack channel if it exceeds threshold value

# Slack webhook URL
SLACK_WEBHOOK_URL=""

# Disk usage threshold (in percentage)
THRESHOLD=80

# Date and hostname for the alert message
DATE=$(date "+%Y-%m-%d %H:%M:%S")
HOSTNAME=$(dig @resolver1.opendns.com myip.opendns.com +short)

# Check each partition
df -H | grep "/dev" | grep -v boot | grep -vE '^Filesystem|udev|tmpfs|cdrom' | awk '{ print $5 " " $1 " " $6}' | while read output; do
  usage=$(echo $output | awk '{ print $1}' | sed 's/%//g')
  partition=$(echo $output | awk '{ print $2 " Mounted on " $3}')

  if [ "$usage" -ge "$THRESHOLD" ]; then
    # Compose message for Slack
    message=":Warning: *Disk Usage Alert* :Warning: \n *Date:* $DATE \n *Server:* $HOSTNAME \n *Partition:* $partition \n *Usage:* $usage%"
	echo $message

    # Send alert to Slack
    curl -X POST -H 'Content-type: application/json' \
      --data "{\"text\": \"$message\"}" $SLACK_WEBHOOK_URL
  fi
done
