#!/bin/bash

set -u

LOG_FILE="/var/log/fix_swap_to_4g.log"
REQUIRED_SWAP_MB=4000
REQUIRED_FREE_KB=$((4 * 1024 * 1024))
DATA_MOUNT="/mnt/data"
FSTAB_BACKUP="/etc/fstab.bak.$(date +%F_%H%M%S)"

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "This script must be run as root."
    fi
}

get_total_swap_mb() {
    free -m | awk '/^Swap:/ {print $2}'
}

precheck_data_mount_and_space() {
    log "Checking whether $DATA_MOUNT is mounted ..."
    if ! mountpoint -q "$DATA_MOUNT"; then
        log "$DATA_MOUNT is not mounted. Exiting without making any changes."
        exit 0
    fi

    log "$DATA_MOUNT is mounted. Checking available free space ..."
    local avail_kb usage_pct avail_gb
    usage_pct="$(df -P "$DATA_MOUNT" | awk 'NR==2 {gsub("%","",$5); print $5}')"
    avail_kb="$(df -Pk "$DATA_MOUNT" | awk 'NR==2 {print $4}')"
    avail_gb=$(( avail_kb / 1024 / 1024 ))

    log "$DATA_MOUNT usage: ${usage_pct}%"
    log "$DATA_MOUNT free space: ${avail_gb} GB"

    if [ "$avail_kb" -lt "$REQUIRED_FREE_KB" ]; then
        log "$DATA_MOUNT does not have 4 GB or more free space. Exiting without making any changes."
        exit 0
    fi

    log "$DATA_MOUNT has sufficient free space."
}

restart_services() {
    log "Restarting services..."

    /etc/init.d/nginx restart || log "Warning: nginx restart failed"
    /etc/init.d/varnish restart || log "Warning: varnish restart failed"
    /etc/init.d/apache2 restart || log "Warning: apache2 restart failed"

    PHP_FPM_SERVICE="php$(php -v | head -n 1 | cut -d ' ' -f2 | cut -d '.' -f1,2)-fpm"
    /etc/init.d/${PHP_FPM_SERVICE} restart || log "Warning: ${PHP_FPM_SERVICE} restart failed"

    /etc/init.d/mysql restart || log "Warning: mysql restart failed"
    systemctl restart redis-server || log "Warning: redis-server restart failed"

    log "Service restart step completed."
}

get_fstab_swap_lines() {
    awk '
        $0 !~ /^[[:space:]]*#/ &&
        NF >= 3 &&
        $3 == "swap" {
            print NR ":" $0
        }
    ' /etc/fstab
}

cleanup_fstab_swap_entries() {
    log "Checking swap entries in /etc/fstab ..."
    cp -a /etc/fstab "$FSTAB_BACKUP" || fail "Failed to back up /etc/fstab"
    log "Backup created: $FSTAB_BACKUP"

    mapfile -t SWAP_LINES < <(get_fstab_swap_lines)

    if [ "${#SWAP_LINES[@]}" -le 1 ]; then
        log "Zero or one swap entry found in /etc/fstab. No cleanup needed."
        return 0
    fi

    log "Multiple swap entries found:"
    printf '%s\n' "${SWAP_LINES[@]}" | tee -a "$LOG_FILE"

    KEEP_LINE_NO=""
    REMOVE_LINE_NOS=()

    for entry in "${SWAP_LINES[@]}"; do
        line_no="${entry%%:*}"
        line_content="${entry#*:}"
        swap_path="$(echo "$line_content" | awk '{print $1}')"
        base_name="$(basename "$swap_path")"

        if [ "$base_name" = "swap" ]; then
            KEEP_LINE_NO="$line_no"
            break
        fi
    done

    if [ -z "$KEEP_LINE_NO" ]; then
        KEEP_LINE_NO="${SWAP_LINES[0]%%:*}"
        log "No plain 'swap' entry found. Keeping first swap entry at line $KEEP_LINE_NO."
    else
        log "Keeping preferred swap entry at line $KEEP_LINE_NO."
    fi

    for entry in "${SWAP_LINES[@]}"; do
        line_no="${entry%%:*}"
        if [ "$line_no" != "$KEEP_LINE_NO" ]; then
            REMOVE_LINE_NOS+=("$line_no")
        fi
    done

    if [ "${#REMOVE_LINE_NOS[@]}" -gt 0 ]; then
        tmpfile="$(mktemp)"
        awk -v remove_list="$(IFS=,; echo "${REMOVE_LINE_NOS[*]}")" '
            BEGIN {
                n=split(remove_list, arr, ",")
                for (i=1; i<=n; i++) remove[arr[i]]=1
            }
            !(FNR in remove)
        ' /etc/fstab > "$tmpfile" || fail "Failed to rebuild /etc/fstab"

        cat "$tmpfile" > /etc/fstab || fail "Failed to update /etc/fstab"
        rm -f "$tmpfile"

        log "Removed extra swap entries from /etc/fstab: ${REMOVE_LINE_NOS[*]}"
    fi
}

get_kept_swap_path() {
    awk '
        $0 !~ /^[[:space:]]*#/ &&
        NF >= 3 &&
        $3 == "swap" {
            print $1
            exit
        }
    ' /etc/fstab
}

disable_swap() {
    log "Running swapoff -a ..."
    swapoff -a || fail "swapoff -a failed"
}

ensure_swap_file_exists_and_resize() {
    local swap_path="$1"

    [ -n "$swap_path" ] || fail "No swap path found in /etc/fstab"

    log "Preparing swap file: $swap_path"

    mkdir -p "$(dirname "$swap_path")" || fail "Failed to create directory for $swap_path"

    if command -v fallocate >/dev/null 2>&1; then
        if fallocate -l 4G "$swap_path"; then
            log "Allocated 4 GB swap file using fallocate."
        else
            log "fallocate failed, falling back to dd ..."
            dd if=/dev/zero of="$swap_path" bs=1M count=4096 status=progress || fail "dd failed to create swap file"
        fi
    else
        dd if=/dev/zero of="$swap_path" bs=1M count=4096 status=progress || fail "dd failed to create swap file"
    fi

    chmod 600 "$swap_path" || fail "chmod 600 failed on $swap_path"
    mkswap "$swap_path" || fail "mkswap failed on $swap_path"

    log "Swap file resized and initialized successfully."
}

enable_swap() {
    log "Running swapon -a ..."
    swapon -a || fail "swapon -a failed"

    log "Active swap after swapon:"
    swapon --show | tee -a "$LOG_FILE"

    final_swap_mb="$(get_total_swap_mb)"
    log "Final total swap: ${final_swap_mb} MB"

    if [ "$final_swap_mb" -lt "$REQUIRED_SWAP_MB" ]; then
        fail "Final swap is still less than 4000 MB."
    fi
}

main() {
    require_root

    current_swap_mb="$(get_total_swap_mb)"
    log "Current total swap: ${current_swap_mb} MB"

    if [ "$current_swap_mb" -gt "$REQUIRED_SWAP_MB" ] || [ "$current_swap_mb" -eq "$REQUIRED_SWAP_MB" ]; then
        log "Swap is already 4000 MB or more. No action needed."
        exit 0
    fi

    log "Swap is less than 4000 MB. Running prerequisite checks before making changes."
    precheck_data_mount_and_space

    log "Prerequisite checks passed. Starting remediation."
    restart_services
    disable_swap
    cleanup_fstab_swap_entries

    swap_path="$(get_kept_swap_path)"
    [ -n "$swap_path" ] || fail "Could not determine swap path from /etc/fstab after cleanup."

    log "Using swap file path: $swap_path"

    ensure_swap_file_exists_and_resize "$swap_path"
    enable_swap

    log "Swap remediation completed successfully."
}

main "$@"
