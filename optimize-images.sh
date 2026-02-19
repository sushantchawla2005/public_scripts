#!/usr/bin/env bash
set -euo pipefail

OXP_VER="9.1.5"
OXP_TAR="oxipng-${OXP_VER}-x86_64-unknown-linux-musl.tar.gz"
OXP_DIR="oxipng-${OXP_VER}-x86_64-unknown-linux-musl"
OXP_URL="https://github.com/oxipng/oxipng/releases/download/v${OXP_VER}/${OXP_TAR}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[ERROR] Run as root (or with sudo)."
    exit 1
  fi
}

# Human size of a directory
dir_size() { du -sh --apparent-size "$1" 2>/dev/null | awk '{print $1}'; }

APT_UPDATED=0
apt_update_once() {
  if [[ "$APT_UPDATED" -eq 0 ]]; then
    echo "[INFO] Updating apt cache..."
    apt-get update -y >/dev/null 2>&1
    APT_UPDATED=1
  fi
}

apt_install_if_missing() {
  local pkg="$1" cmd="${2:-$1}"
  if have_cmd "$cmd"; then
    return 0
  fi

  echo "[INFO] Installing package: $pkg (for '$cmd')"
  apt_update_once
  # hide install output; keep errors on failure
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1 || {
    echo "[ERROR] Failed installing package: $pkg"
    exit 1
  }
}

install_oxipng_if_missing() {
  if have_cmd oxipng; then
    echo "[OK] oxipng already present: $(command -v oxipng)"
    return 0
  fi

  echo "[INFO] oxipng missing. Downloading and installing v${OXP_VER} to /usr/local/bin/oxipng"
  apt_install_if_missing wget wget
  apt_install_if_missing tar tar
  # update-ca-certificates is a command from ca-certificates; don't hard fail if it isn't needed
  apt_install_if_missing ca-certificates update-ca-certificates || true

  tmp=""
  cleanup() { [[ -n "${tmp:-}" && -d "${tmp:-}" ]] && rm -rf "$tmp"; }
  trap cleanup EXIT
  tmp="$(mktemp -d)"

  # keep wget progress (useful) but hide noisy apt
  wget -q --show-progress -O "${tmp}/${OXP_TAR}" "$OXP_URL"
  tar -xzf "${tmp}/${OXP_TAR}" -C "$tmp"
  install -m 0755 "${tmp}/${OXP_DIR}/oxipng" /usr/local/bin/oxipng

  echo "[OK] oxipng installed: $(command -v oxipng)"
}

main() {
  need_root

  # Capture before size of current folder (.)
  local before after
  before="$(dir_size ".")"

  apt_install_if_missing jpegoptim jpegoptim
  apt_install_if_missing findutils find
  apt_install_if_missing coreutils nproc
  # xargs usually available already; if missing, try findutils/coreutils depending on distro
  apt_install_if_missing findutils xargs || true

  install_oxipng_if_missing

  echo "[INFO] Optimizing JPEGs under: ."
  find ./ -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -exec jpegoptim --strip-all --max=82 {} \;

  echo "[INFO] Optimizing PNGs under: ."
  find ./ -type f -iname "*.png" -print0 | xargs -0 -P "$(nproc)" oxipng -o 3 --strip all --preserve

  after="$(dir_size ".")"
  echo -e ""
  echo "[DONE] Image optimization completed."
  echo "Folder size: ${before} -> ${after}"
}

main "$@"
