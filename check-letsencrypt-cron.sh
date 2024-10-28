#!/bin/bash

for A in $(ls -l /home/master/applications/| grep "^d" | awk '{print $NF}'); do sudo crontab -l | grep $A > /dev/null 2>&1 || echo "No match found for $A" && cat /home/master/applications/$A/conf/server.nginx && echo ""; done
