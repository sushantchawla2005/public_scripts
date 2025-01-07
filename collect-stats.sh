#!/bin/bash

DATE=$(/bin/date +%F--%H-%M)
# Define output file
OUTPUT_FILE="/root/server-stats.log"

# Clear previous log content
echo "Extracting useful information from server..." > "$OUTPUT_FILE"

echo "== ${DATE} ==" >> ${OUTPUT_FILE}

# Run the SHOW ENGINE INNODB STATUS command
mysql -e "SHOW ENGINE INNODB STATUS\G;" >> ${OUTPUT_FILE}

# Run the processlist command
echo -e "######## PROCESS LIST ########" >> ${OUTPUT_FILE}
mysql -e "show processlist;" >> ${OUTPUT_FILE}

# Run iostat
echo -e "######## DISK STATUS ########" >> ${OUTPUT_FILE}
iostat -x >> ${OUTPUT_FILE}

# Notify user
echo "Debugging information has been saved to $OUTPUT_FILE"
