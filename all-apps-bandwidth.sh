#!/bin/bash

# Loop through each application's logs directory
for app in /home/master/applications/*/logs; do
    echo "Application: $(basename $(dirname $app))"
    cd $app || continue  # Change to the application's logs directory or skip if it fails

    # Loop through the past 30 days to check bandwidth for each day
    for i in {30..0}; do
        zcat -f *_*.access.log* | awk -v day="$(date --date="$i days ago" '+%d/%b/%Y')" '$4 ~ day {sum += $10} END {print day, sum/1024/1024 " MB"}'
    done

    echo "---------------------------"
done
