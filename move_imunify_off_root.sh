#!/bin/bash
set -euo pipefail

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Please run this script as root or with sudo."
  fi
}

check_fstab() {
  local matches
  matches="$(grep -i 'imunify360' /etc/fstab || true)"
  if [[ -n "${matches}" ]]; then
    echo "[ABORT] Found existing imunify360-related entries in /etc/fstab:"
    echo "${matches}"
    exit 1
  fi
}

check_mounts() {
  local matches
  matches="$(mount | grep -i 'imunify' || true)"
  if [[ -n "${matches}" ]]; then
    echo "[ABORT] Found existing imunify-related mount entries:"
    echo "${matches}"
    exit 1
  fi
}

check_storage_requirements() {
  local db_source data_source db_avail_kb data_avail_kb min_kb
  min_kb=$((2 * 1024 * 1024))  # 2 GB in KB

  if ! mountpoint -q /mnt/db; then
    fail "/mnt/db is not mounted as a separate mount point."
  fi

  if ! mountpoint -q /mnt/data; then
    fail "/mnt/data is not mounted as a separate mount point."
  fi

  db_source="$(findmnt -n -o SOURCE /mnt/db || true)"
  data_source="$(findmnt -n -o SOURCE /mnt/data || true)"

  [[ -n "$db_source" ]] || fail "Unable to determine source device for /mnt/db."
  [[ -n "$data_source" ]] || fail "Unable to determine source device for /mnt/data."

  if [[ "$db_source" == "$data_source" ]]; then
    fail "/mnt/db and /mnt/data are mounted from the same source device ($db_source). Separate partitions are required."
  fi

  db_avail_kb="$(df -Pk /mnt/db | awk 'NR==2 {print $4}')"
  data_avail_kb="$(df -Pk /mnt/data | awk 'NR==2 {print $4}')"

  [[ "$db_avail_kb" =~ ^[0-9]+$ ]] || fail "Unable to determine free space on /mnt/db."
  [[ "$data_avail_kb" =~ ^[0-9]+$ ]] || fail "Unable to determine free space on /mnt/data."

  if (( db_avail_kb <= min_kb )); then
    fail "/mnt/db does not have more than 2 GB free space. Available: $((db_avail_kb / 1024 / 1024)) GB"
  fi

  if (( data_avail_kb <= min_kb )); then
    fail "/mnt/data does not have more than 2 GB free space. Available: $((data_avail_kb / 1024 / 1024)) GB"
  fi

  log "/mnt/db is mounted from ${db_source} with $((db_avail_kb / 1024 / 1024)) GB free"
  log "/mnt/data is mounted from ${data_source} with $((data_avail_kb / 1024 / 1024)) GB free"
}

backup_fstab() {
  local backup
  backup="/etc/fstab.bak.$(date +%F-%H%M%S)"
  cp -a /etc/fstab "${backup}"
  log "Backup of /etc/fstab created at ${backup}"
}

stop_services() {
  log "Stopping monit"
  systemctl stop monit || true

  log "Stopping Imunify services"
  systemctl stop 'imunify*' || true
}

prepare_dirs() {
  log "Creating target directories"
  mkdir -p /mnt/db/imunify360
  mkdir -p /mnt/data/imunify360-logs
  mkdir -p /mnt/data/imunify360-webshield-logs
}

sync_data() {
  log "Syncing /var/imunify360 -> /mnt/db/imunify360"
  rsync -aHAX /var/imunify360/ /mnt/db/imunify360/

  log "Syncing /var/log/imunify360 -> /mnt/data/imunify360-logs"
  rsync -aHAX /var/log/imunify360/ /mnt/data/imunify360-logs/

  if [[ -d /var/log/imunify360-webshield ]]; then
    log "Syncing /var/log/imunify360-webshield -> /mnt/data/imunify360-webshield-logs"
    rsync -aHAX /var/log/imunify360-webshield/ /mnt/data/imunify360-webshield-logs/
  else
    warn "/var/log/imunify360-webshield does not exist, skipping rsync for webshield logs"
  fi
}

clear_source_dirs() {
  log "Clearing original source directories"
  rm -rf /var/imunify360/*
  rm -rf /var/log/imunify360/*

  if [[ -d /var/log/imunify360-webshield ]]; then
    rm -rf /var/log/imunify360-webshield/*
  fi
}

ensure_dir() {
  local path="$1"
  [[ -d "$path" ]] || mkdir -p "$path"
}

bind_mounts() {
  log "Creating bind mounts"

  ensure_dir /var/imunify360
  ensure_dir /var/log/imunify360
  ensure_dir /var/log/imunify360-webshield

  mount --bind /mnt/db/imunify360 /var/imunify360
  mount --bind /mnt/data/imunify360-logs /var/log/imunify360
  mount --bind /mnt/data/imunify360-webshield-logs /var/log/imunify360-webshield
}

append_fstab() {
  log "Appending bind mount entries to /etc/fstab"

  cat >> /etc/fstab <<'EOF'

/mnt/db/imunify360 /var/imunify360 none bind 0 0
/mnt/data/imunify360-logs /var/log/imunify360 none bind 0 0
/mnt/data/imunify360-webshield-logs /var/log/imunify360-webshield none bind 0 0
EOF
}

unit_exists() {
  local unit="$1"
  sudo systemctl list-unit-files --type=service --type=socket --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"
}

restart_unit_safe() {
  local unit="$1"

  if unit_exists "$unit"; then
    if sudo systemctl restart "$unit" 2>/dev/null; then
      log "Restarted $unit"
    else
      warn "Failed to restart $unit (ignored)"
    fi
  else
    log "$unit not present, skipping"
  fi
}

restart_services() {
  log "Reloading systemd daemon"
  systemctl daemon-reload

  log "Restarting Imunify services"
  for unit in \
    imunify-agent-proxy.service \
    imunify-realtime-av.service \
    imunify360-agent.service \
    imunify360-dos-protection.service \
    imunify360-php-daemon.service \
    imunify360-unified-access-logger.service \
    imunify360-wafd.service \
    imunify360.service
  do
    restart_unit_safe "$unit"
  done

  log "Restarting Imunify socket units safely"
  for unit in \
    imunify-agent-proxy.socket \
    imunify-notifier.socket \
    imunify360-agent-user.socket \
    imunify360-agent.socket \
    imunify360-pam.socket \
    imunify360-php-daemon.socket
  do
    restart_unit_safe "$unit"
  done

  log "Starting monit"
  sudo systemctl start monit || true
}

post_checks() {
  log "Running verification checks"
  imunify360-agent version || warn "Unable to get Imunify360 version"

  if [[ -f /var/imunify360/imunify360.db ]]; then
    ls -la /var/imunify360/imunify360.db
  else
    warn "/var/imunify360/imunify360.db not found"
  fi

  log "Current MALWARE_SCAN_INTENSITY"
  imunify360-agent config show | grep -A5 MALWARE_SCAN_INTENSITY || true

  log "Reducing scan intensity"
  imunify360-agent config update '{"MALWARE_SCAN_INTENSITY": {"io": 1, "cpu": 1, "ram": 1024}}'

  log "Updated MALWARE_SCAN_INTENSITY"
  imunify360-agent config show | grep -A5 MALWARE_SCAN_INTENSITY || true
}

main() {
  require_root
  check_fstab
  check_mounts
  check_storage_requirements
  backup_fstab
  stop_services
  prepare_dirs
  sync_data
  clear_source_dirs
  bind_mounts
  append_fstab
  restart_services
  post_checks

  log "Completed successfully."
}

main "$@"
