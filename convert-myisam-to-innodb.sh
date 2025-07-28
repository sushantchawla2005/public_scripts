#!/bin/bash

# Author: Sushant Chawla
# Last Updated: 28 July' 2025
# Description: Basic script to take text file as input having MyISAM DB and tables list
# to convert them to InnoDB Engine

# Input file
INPUT_FILE="$1"

if [ $# -ne 1 ]; then
        echo -e ""
        echo "$0 /Path/to/MyISAM-DB-Tables-List.txt"
        exit 1
fi

# Skip header and loop through each line
tail -n +2 "$INPUT_FILE" | while read -r db table; do
  db=$(echo "$db" | xargs)
  table=$(echo "$table" | xargs)

  if [[ -z "$db" || -z "$table" ]]; then
    continue
  fi

  echo "Converting $db.$table to InnoDB..."
  mysql -e "ALTER TABLE \`${db}\`.\`${table}\` ENGINE=InnoDB;"

done
