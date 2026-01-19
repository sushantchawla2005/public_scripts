#!/usr/bin/env bash
# check_404_rate.sh
# Usage: ./check_404_rate.sh <threshold_percent> [log_dir]
# Example: ./check_404_rate.sh 2.5 ../logs
# Author: Sushant Chawla
# Last Updated: 19 Jan' 2026

set -euo pipefail

THRESH="${1:-}"
LOG_DIR="${2:-../logs}"

if [[ -z "${THRESH}" ]]; then
  echo "Usage: $0 <threshold_percent> [log_dir]"
  echo "Example: $0 2.5 ../logs"
  exit 1
fi

# Basic numeric validation (allows integers/decimals)
if ! [[ "${THRESH}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Error: threshold must be a number (e.g., 2 or 2.5). Got: '${THRESH}'"
  exit 1
fi

RED=$'\033[31m'
AMBER=$'\033[33m'
RESET=$'\033[0m'

# Compare floats using awk (returns 0 if a>b)
float_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN{exit (a>b)?0:1}'
}

print_file_report() {
  local f="$1"

  echo "------------------------------------------------------------"
  echo "Checking log file ${f}"

  local total hits_404 pct color
  total=$(wc -l < "${f}" 2>/dev/null | tr -d ' ')
  hits_404=$(grep -F " 404 " "${f}" 2>/dev/null | wc -l | tr -d ' ')

  if [[ "${total}" == "0" ]]; then
    pct="0.00"
  else
    pct=$(awk -v e="${hits_404}" -v t="${total}" 'BEGIN{printf "%.2f", (e*100)/t}')
  fi

  color="${AMBER}"
  if float_gt "${pct}" "${THRESH}"; then
    color="${RED}"
  fi

  echo "Total hits: ${total}"
  echo "404s    : ${hits_404}"
  echo -e "404 rate: ${color}${pct}%${RESET} (threshold ${THRESH}%)"

  echo "Top 5 404 URLs:"
  if [[ "${hits_404}" == "0" ]]; then
    echo "  (none)"
  else
    # NOTE: With `set -euo pipefail`, pipelines that end in `head` can cause SIGPIPE
    # upstream and exit the script. Wrapping in `{ ...; } || true` prevents that.
    {
      grep -F " 404 " "${f}" \
        | awk -F'"' 'NF>=2 {print $2}' \
        | awk '{print $2}' \
        | sort \
        | uniq -c \
        | sort -nr \
        | head -n 5 \
        | awk '{printf "  %s\t%s\n", $1, $2}'
    } || true
  fi
}

analyze_glob_per_file() {
  local glob="$1"

  # Make unmatched globs expand to nothing (instead of the literal pattern)
  shopt -s nullglob
  local files=( "${LOG_DIR}"/${glob} )
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    echo "------------------------------------------------------------"
    echo "Checking log file ${LOG_DIR}/${glob} (no matches)"
    echo "Total hits: 0"
    echo "404s    : 0"
    echo "404 rate: 0.00% (threshold ${THRESH}%)"
    echo "Top 5 404 URLs:"
    echo "  (none)"
    return 0
  fi

  for f in "${files[@]}"; do
    print_file_report "${f}"
  done
}

analyze_glob_per_file "backend*.access.log"
analyze_glob_per_file "backend*.access.log.1"
echo "------------------------------------------------------------"
