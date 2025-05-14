#!/bin/bash

INPUT_FILE="$1"

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
  echo "❌ Please provide a valid input file."
  echo "Usage: $0 users.txt"
  exit 1
fi

while IFS=: read -r USERNAME PASSWORD; do
  if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
    echo "🔧 Creating database and user: $USERNAME"

    mysql <<EOF
      CREATE DATABASE IF NOT EXISTS \`$USERNAME\`;
      CREATE USER IF NOT EXISTS '$USERNAME'@'%' IDENTIFIED BY '$PASSWORD';
      GRANT ALL PRIVILEGES ON \`$USERNAME\`.* TO '$USERNAME'@'%';
      FLUSH PRIVILEGES;
EOF

  fi
done < "$INPUT_FILE"
