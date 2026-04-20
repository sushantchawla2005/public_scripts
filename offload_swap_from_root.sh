#!/bin/bash

set -u

LOG_FILE="/var/log/move_swap_to_data_2g.log"
DATA_MOUNT="/mnt/data"
NEW_SWAP_PATH="${DATA_MOUNT}/swap"
TARGET_SWAP_MB=2048
TARGET_SWAP_SIZE="2G"
EXTRA_FREE_MB=2048
MIN_FINAL_SWAP_MB=2000
FSTAB_BACKUP="/etc/fstab.bak.$(date +%F_%H%M%S)"

ORIG_SWAPPINESS=""
ACTIVE_SWAPS=()

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR: $*"
    restore_swappiness
    exit 1
}

restore_swappiness() {
    if [ -n "${ORIG_SWAPPINESS:-}" ]; then
        echo "${ORIG_SWAPPINESS}" > /proc/sys/vm/swappiness 2>/dev/null || true
        log "Restored vm.swappiness to ${ORIG_SWAPPINESS}"
    fi
}

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "Run this script as root"
}

get_php_version() {
    php -v 2>/dev/null | head -n1 | awk '{print $2}' | cut -d. -f1,2
}

get_active_swap_paths() {
    swapon --noheadings --show=NAME 2>/dev/null
}

get_total_swap_mb() {
    free -m | awk '/^Swap:/ {print $2}'
}

get_data_free_mb() {
    df -Pm "${DATA_MOUNT}" | awk 'NR==2 {print $4}'
}

get_file_size_mb() {
    local file="$1"
    if [ -f "$file" ]; then
        du -m "$file" | awk '{print $1}'
    else
        echo 0
    fi
}

check_data_partition_exists() {
    log "Checking if ${DATA_MOUNT} is a separate mounted data partition..."

    if ! mountpoint -q "${DATA_MOUNT}"; then
        log "${DATA_MOUNT} is not mounted. Exiting."
        exit 0
    fi

    local root_src data_src
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null)"
    data_src="$(findmnt -n -o SOURCE "${DATA_MOUNT}" 2>/dev/null)"

    if [ -z "${data_src}" ]; then
        log "Could not determine backing device for ${DATA_MOUNT}. Exiting."
        exit 0
    fi

    if [ "${root_src}" = "${data_src}" ]; then
        log "${DATA_MOUNT} is not on a separate partition/device from root. Exiting."
        exit 0
    fi

    log "${DATA_MOUNT} is mounted on a separate partition/device."
}

check_data_free_space_vs_existing_swap() {
    log "Checking free space on ${DATA_MOUNT} against existing swap size..."

    local current_swap_mb data_free_mb required_free_mb
    current_swap_mb="$(get_total_swap_mb)"
    data_free_mb="$(get_data_free_mb)"
    required_free_mb=$(( current_swap_mb + EXTRA_FREE_MB ))

    log "Current total swap: ${current_swap_mb} MB"
    log "Free space on ${DATA_MOUNT}: ${data_free_mb} MB"
    log "Required free space on ${DATA_MOUNT}: ${required_free_mb} MB"

    if [ "${data_free_mb}" -lt "${required_free_mb}" ]; then
        log "${DATA_MOUNT} does not have enough free space. Exiting."
        exit 0
    fi

    log "Free space check passed."
}

fstab_has_data_swap() {
    awk '
        $0 !~ /^[[:space:]]*#/ && NF >= 3 && $1 == "'"${NEW_SWAP_PATH}"'" && $3 == "swap" { found=1 }
        END { exit(found ? 0 : 1) }
    ' /etc/fstab
}

ensure_existing_data_swap_is_2g_if_configured() {
    if fstab_has_data_swap; then
        log "/etc/fstab already contains ${NEW_SWAP_PATH} as swap."

        local active_swap_mb file_swap_mb
        active_swap_mb=0
        file_swap_mb="$(get_file_size_mb "${NEW_SWAP_PATH}")"

        if swapon --show=NAME,SIZE --noheadings 2>/dev/null | awk '{print $1}' | grep -qx "${NEW_SWAP_PATH}"; then
            active_swap_mb="$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | awk -v p="${NEW_SWAP_PATH}" '
                $1==p {
                    size=$2
                    gsub(/B/,"",size)
                    if (size ~ /G$/) { sub(/G$/,"",size); print int(size*1024) }
                    else if (size ~ /M$/) { sub(/M$/,"",size); print int(size) }
                    else if (size ~ /K$/) { sub(/K$/,"",size); print int(size/1024) }
                    else { print int(size/1024/1024) }
                }'
            )"
            active_swap_mb="${active_swap_mb:-0}"
        fi

        log "Current ${NEW_SWAP_PATH} file size: ${file_swap_mb} MB"
        log "Current active ${NEW_SWAP_PATH} swap size: ${active_swap_mb} MB"

        if [ "${active_swap_mb}" -ge "${MIN_FINAL_SWAP_MB}" ] && [ "${file_swap_mb}" -ge "${MIN_FINAL_SWAP_MB}" ]; then
            log "${NEW_SWAP_PATH} is already configured and is >= ${MIN_FINAL_SWAP_MB} MB. No changes required."
            exit 0
        fi

        log "${NEW_SWAP_PATH} exists in fstab but is below ${MIN_FINAL_SWAP_MB} MB. Will reset it to 2 GB."
    else
        log "/etc/fstab does not contain ${NEW_SWAP_PATH}. Proceeding with migration/reset."
    fi
}

restart_services() {
    log "Restarting core services before swapoff..."

    local php_ver
    php_ver="$(get_php_version)"

    /etc/init.d/nginx restart || fail "Failed to restart nginx"
    /etc/init.d/varnish restart || fail "Failed to restart varnish"
    /etc/init.d/apache2 restart || fail "Failed to restart apache2"

    if [ -n "${php_ver}" ]; then
        /etc/init.d/php${php_ver}-fpm restart || fail "Failed to restart php${php_ver}-fpm"
    else
        log "Could not detect PHP version, skipping PHP-FPM restart"
    fi

    /etc/init.d/mysql restart || fail "Failed to restart mysql"
    systemctl restart redis-server || fail "Failed to restart redis-server"

    log "Service restart completed"
}

remember_swappiness() {
    ORIG_SWAPPINESS="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)"
    log "Original vm.swappiness: ${ORIG_SWAPPINESS}"
}

set_safe_swappiness() {
    echo 0 > /proc/sys/vm/swappiness || fail "Failed to set vm.swappiness to 0"
    log "Temporarily set vm.swappiness to 0"
}

flush_caches() {
    log "Running sync and dropping caches..."
    sync
    echo 3 > /proc/sys/vm/drop_caches || fail "Failed to drop caches"
    sleep 2
    log "Cache drop completed"
}

backup_fstab() {
    cp -a /etc/fstab "${FSTAB_BACKUP}" || fail "Failed to back up /etc/fstab"
    log "fstab backup created: ${FSTAB_BACKUP}"
}

remove_swap_entries_from_fstab() {
    log "Removing all existing swap entries from /etc/fstab ..."
    local tmpfile
    tmpfile="$(mktemp)" || fail "Could not create temp file"

    awk '
        $0 ~ /^[[:space:]]*#/ { print; next }
        NF >= 3 && $3 == "swap" { next }
        { print }
    ' /etc/fstab > "${tmpfile}" || fail "Failed to process fstab"

    cat "${tmpfile}" > /etc/fstab || fail "Failed to write updated fstab"
    rm -f "${tmpfile}"
    log "Removed old swap entries from /etc/fstab"
}

disable_swap() {
    log "Disabling swap using swapoff -a ..."

    if swapoff -a; then
        log "swapoff -a completed successfully on first attempt"
        return 0
    fi

    log "First swapoff -a attempt failed. Retrying once more after 2 seconds..."
    sleep 2

    if swapoff -a; then
        log "swapoff -a completed successfully on second attempt"
        return 0
    fi

    fail "swapoff -a failed on both attempts. No further actions will be performed."
}

remove_old_swap_files() {
    log "Removing old swap files if present..."

    for s in "${ACTIVE_SWAPS[@]}"; do
        if [[ "$s" == /* && -f "$s" && "$s" != "${NEW_SWAP_PATH}" ]]; then
            log "Removing old swap file: $s"
            rm -f "$s" || fail "Failed to remove old swap file: $s"
        fi
    done

    if [ -f "${NEW_SWAP_PATH}" ]; then
        log "Removing existing ${NEW_SWAP_PATH} before recreation"
        rm -f "${NEW_SWAP_PATH}" || fail "Failed to remove existing ${NEW_SWAP_PATH}"
    fi
}

create_new_swap() {
    log "Creating ${TARGET_SWAP_SIZE} swap file at ${NEW_SWAP_PATH} ..."

    if command -v fallocate >/dev/null 2>&1; then
        if ! fallocate -l "${TARGET_SWAP_SIZE}" "${NEW_SWAP_PATH}"; then
            log "fallocate failed, using dd instead..."
            dd if=/dev/zero of="${NEW_SWAP_PATH}" bs=1M count="${TARGET_SWAP_MB}" status=progress || fail "Failed to create swap with dd"
        fi
    else
        dd if=/dev/zero of="${NEW_SWAP_PATH}" bs=1M count="${TARGET_SWAP_MB}" status=progress || fail "Failed to create swap with dd"
    fi

    chmod 600 "${NEW_SWAP_PATH}" || fail "chmod failed on ${NEW_SWAP_PATH}"
    mkswap "${NEW_SWAP_PATH}" || fail "mkswap failed on ${NEW_SWAP_PATH}"
    log "New swap file created successfully"
}

enable_new_swap() {
    echo "${NEW_SWAP_PATH} none swap sw 0 0" >> /etc/fstab || fail "Failed to append new swap entry to /etc/fstab"
    swapon "${NEW_SWAP_PATH}" || fail "Failed to enable ${NEW_SWAP_PATH}"

    log "New swap enabled:"
    swapon --show | tee -a "$LOG_FILE"

    local final_swap_mb
    final_swap_mb="$(get_total_swap_mb)"
    log "Final total swap: ${final_swap_mb} MB"

    if [ "${final_swap_mb}" -lt "${MIN_FINAL_SWAP_MB}" ]; then
        fail "Final swap is below ${MIN_FINAL_SWAP_MB} MB"
    fi
}

main() {
    require_root
    log "===== START swap move/reset to ${NEW_SWAP_PATH} (${TARGET_SWAP_SIZE}) ====="

    check_data_partition_exists
    check_data_free_space_vs_existing_swap
    ensure_existing_data_swap_is_2g_if_configured

    mapfile -t ACTIVE_SWAPS < <(get_active_swap_paths)

    restart_services
    remember_swappiness
    set_safe_swappiness
    flush_caches
    backup_fstab
    disable_swap
    remove_swap_entries_from_fstab
    remove_old_swap_files
    create_new_swap
    enable_new_swap
    restore_swappiness

    log "===== COMPLETED SUCCESSFULLY ====="
}

main "$@"
