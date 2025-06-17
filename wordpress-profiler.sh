#!/bin/bash

# Script to check speed of the Wordpress website
# to identify which plugin is adding how much delay
# Author: Sushant Chawla
# Last Updated: 17 June' 2025

COLORCODE_CYAN="\e[36m"
COLORCODE_RED="\e[31m"
COLORCODE_RESET="\e[0m"

# Initialize WP-CLI
if [ "$(id -u)" -eq 0 ]; then
    WP="/usr/local/bin/wp --allow-root"
else
    WP="/usr/local/bin/wp"
fi

LOGFILE="/tmp/wp-profile-output.log"
PLUGINS=$(${WP} --skip-plugins --skip-themes plugin list --status=active --field=name)

# === Check for unbuffer ===
if ! command -v unbuffer &> /dev/null; then
  echo "❗ 'unbuffer' not found. Attempting to install 'expect' to provide it..."
  if command -v sudo &> /dev/null; then
    sudo apt-get update && sudo apt-get install -y expect
  else
    echo "❌ 'sudo' command not found. Please install 'expect' manually to use 'unbuffer'."
    exit 1
  fi

  if ! command -v unbuffer &> /dev/null; then
    echo "❌ 'unbuffer' still not found after installing 'expect'. Exiting."
    exit 1
  fi
fi

# === Check for WP-CLI profiler ===
if ! ${WP} profile stage --help &> /dev/null; then
  echo "🔧 'wp profile' command not available. Installing wp-cli/profile-command package..."
  ${WP} package install wp-cli/profile-command:@stable

  if ! ${WP} profile stage --help &> /dev/null; then
    echo "❌ Failed to install wp-cli/profile-command. Exiting."
    exit 1
  fi
fi

# === Clear old log ===
rm -f "${LOGFILE}"

echo -e "${COLORCODE_CYAN}Running profiling tests by skipping all plugins one by one, saving output to ${LOGFILE}...${COLORCODE_RESET}"

# === Run baseline test ===
{
  echo "Testing with all plugins/themes enabled"
  echo "============="
  unbuffer ${WP} profile stage --spotlight --format=table
  echo "============="

  for plugin in $PLUGINS; do
    echo "Testing by skipping plugin: $plugin"
    echo "============="
    unbuffer ${WP} --skip-plugins="$plugin" profile stage --spotlight --format=table
    echo "============="
  done
} >> "${LOGFILE}"

# === Parse results to identify top 5 plugins slowing site down ===
baseline_hook=$(awk '
  BEGIN { hook = 0 }
  /^Testing with all plugins\/themes enabled/ { mode = 1 }
  /^\| total/ && mode == 1 {
    gsub(/[|]/, "", $0)
    gsub(/[ \t]+/, " ", $0)
    split($0, f, " ")
    sub("s$", "", f[9])
    hook = f[9]
    mode = 0
  }
  END { print hook }
' "$LOGFILE")

declare -A plugin_deltas

while read -r plugin; do
  plugin_hook=$(awk -v name="$plugin" '
    BEGIN { hook = "" }
    $0 ~ "Testing by skipping plugin: "name {
      mode = 1
    }
    /^\| total/ && mode == 1 {
      gsub(/[|]/, "", $0)
      gsub(/[ \t]+/, " ", $0)
      split($0, f, " ")
      sub("s$", "", f[9])
      hook = f[9]
      mode = 0
    }
    END { print hook }
  ' "$LOGFILE")

  if [[ -n "$plugin_hook" ]]; then
    delta=$(awk "BEGIN {printf \"%.4f\", $baseline_hook - $plugin_hook}")
    plugin_deltas["$plugin"]=$delta
  fi
done <<< "$PLUGINS"

# === Display top 5 contributing plugins ===
echo -e "\n${COLORCODE_RED}Top 5 Plugins Contributing Most to Hook Time (Any plugin adding more than  0.1 seconds to the hooks should be debugged deeply):"
for plugin in "${!plugin_deltas[@]}"; do
  echo -e "${plugin_deltas[$plugin]}\t$plugin"
done | sort -rn | head -5

echo -e "${COLORCODE_RESET}"
echo -e "For more details, please check ${LOGFILE}"
