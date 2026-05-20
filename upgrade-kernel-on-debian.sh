#!/usr/bin/env bash
set -euo pipefail

FACT_FILE="/etc/ansible/facts.d/cloud_provider.fact"

APT_OPTS=(
  -y
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

export DEBIAN_FRONTEND=noninteractive

log() {
  echo "[$(date '+%F %T')] $*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

get_latest_pkg() {
  local pattern="$1"
  local pkg

  pkg="$(
    apt-cache search "$pattern" \
      | awk '{print $1}' \
      | sort -V \
      | tail -1
  )"

  if [[ -z "$pkg" ]]; then
    fail "No package found for pattern: $pattern"
  fi

  echo "$pkg"
}

if [[ $EUID -ne 0 ]]; then
  fail "Please run this script as root."
fi

if [[ ! -r /etc/os-release ]]; then
  fail "/etc/os-release not found. Cannot detect OS."
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
  fail "This script supports Debian only. Detected ID=${ID:-unknown}"
fi

DEBIAN_VERSION="${VERSION_ID%%.*}"

case "$DEBIAN_VERSION" in
  11|12)
    log "Detected Debian $DEBIAN_VERSION"
    ;;
  *)
    fail "Unsupported Debian version: ${VERSION_ID:-unknown}. Only Debian 11 and Debian 12 are supported."
    ;;
esac

CLOUD_PROVIDER="unknown"

if [[ -r "$FACT_FILE" ]]; then
  CLOUD_PROVIDER="$(
    awk -F= '
      /^[[:space:]]*cloud[[:space:]]*=/ {
        gsub(/[[:space:]"'\''\r]/, "", $2);
        print tolower($2);
        exit
      }
    ' "$FACT_FILE"
  )"

  CLOUD_PROVIDER="${CLOUD_PROVIDER:-unknown}"
else
  log "Cloud provider fact file not found/readable: $FACT_FILE"
fi

log "Detected cloud provider: $CLOUD_PROVIDER"

IS_CLOUD_KERNEL_PROVIDER=0
case "$CLOUD_PROVIDER" in
  amazon|gce)
    IS_CLOUD_KERNEL_PROVIDER=1
    ;;
esac

log "Running apt update..."
apt update

if [[ "$DEBIAN_VERSION" == "11" ]]; then
  if [[ "$IS_CLOUD_KERNEL_PROVIDER" -eq 1 ]]; then
    log "Finding latest Debian 11 cloud kernel packages..."

    IMAGE_PKG="$(
      get_latest_pkg '^linux-image-6\.1\.0-0\.deb11\.[0-9]+-cloud-amd64-unsigned$'
    )"

    HEADERS_PKG="$(
      get_latest_pkg '^linux-headers-6\.1\.0-0\.deb11\.[0-9]+-cloud-amd64$'
    )"

    log "Selected image package: $IMAGE_PKG"
    log "Selected headers package: $HEADERS_PKG"

    log "Installing Debian 11 latest cloud kernel packages..."
    apt-get install "${APT_OPTS[@]}" "$IMAGE_PKG" "$HEADERS_PKG"

  else
    log "Finding latest Debian 11 generic kernel packages..."

    IMAGE_PKG="$(
      get_latest_pkg '^linux-image-6\.1\.0-0\.deb11\.[0-9]+-amd64-unsigned$'
    )"

    HEADERS_PKG="$(
      get_latest_pkg '^linux-headers-6\.1\.0-0\.deb11\.[0-9]+-amd64$'
    )"

    log "Selected image package: $IMAGE_PKG"
    log "Selected headers package: $HEADERS_PKG"

    log "Installing Debian 11 latest generic kernel packages..."
    apt-get install "${APT_OPTS[@]}" "$IMAGE_PKG" "$HEADERS_PKG"
  fi
fi

if [[ "$DEBIAN_VERSION" == "12" ]]; then
  if [[ "$IS_CLOUD_KERNEL_PROVIDER" -eq 1 ]]; then
    log "Installing Debian 12 latest cloud kernel meta packages..."
    apt-get install "${APT_OPTS[@]}" \
      linux-image-cloud-amd64 \
      linux-headers-cloud-amd64
  else
    log "Installing Debian 12 latest generic kernel meta packages..."
    apt-get install "${APT_OPTS[@]}" \
      linux-image-amd64 \
      linux-headers-amd64
  fi
fi

log "Kernel packages installed successfully."

log "Running update-grub..."
update-grub

log "Done. Current running kernel is still:"
uname -r

log "Installed kernel packages:"
dpkg -l 'linux-image*' 'linux-headers*' \
  | awk '/^ii/{print $2, $3}' \
  | sort -V \
  | tail -30

log "Reboot is required to boot into the newly installed kernel."
