#!/bin/bash

# Usage: ./check_cpu_steal.sh <threshold>
# Example: ./check_cpu_steal.sh 50

THRESHOLD=$1

if [[ -z "$THRESHOLD" ]]; then
  echo "Usage: $0 <steal_threshold_percent>"
  exit 1
fi

ATOP_DIR="/var/log/atop"
FILES=$(ls "$ATOP_DIR"/atop_* 2>/dev/null)

for FILE in $FILES; do
  echo "Checking file: $FILE"
  atopsar -c -r "$FILE" 2>/dev/null | grep -v "^$" | grep -v "analysis date" | grep -v "cpu" | grep "all" | while read -r line; do
    TIMESTAMP=$(echo "$line" | awk '{print $1}')
    CPU_ID=$(echo "$line" | awk '{print $2}')
    STEAL=$(echo "$line" | awk '{print $8}' | cut -d. -f1)

    if [[ "$STEAL" -ge "$THRESHOLD" ]]; then
      echo "$FILE | Time: $TIMESTAMP | CPU: $CPU_ID | Steal: ${STEAL}%"
    fi
  done
done
