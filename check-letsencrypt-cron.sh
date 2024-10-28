#!/bin/bash

for A in $(ls -l /home/master/applications/ | grep "^d" | awk '{print $NF}'); do
  if ! sudo crontab -l | grep $A > /dev/null 2>&1; then
    echo "No SSL auto renewal cron found for $A"
    cat /home/master/applications/$A/conf/server.nginx
  fi
done
