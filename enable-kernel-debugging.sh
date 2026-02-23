#!/bin/bash
set -euo pipefail

GRUB_FILE="/etc/default/grub"
BACKUP_FILE="/etc/default/grub.bak.$(date +%F_%H-%M-%S)"

# journald retention (runtime, no reboot)
JOURNALD_FILE="/etc/systemd/journald.conf"
JOURNALD_BACKUP="/etc/systemd/journald.conf.bak.$(date +%F_%H-%M-%S)"
JOURNALD_MAXUSE="500M"
JOURNALD_STORAGE="persistent"
PERSIST_DIR="/var/log/journal"

# Boot-time params we want (applied after next reboot)
REQUIRED_PARAMS=(
  "log_buf_len=64M"
  "slab_nomerge"
  "slub_debug=FZPU"
  "page_poison=1"
  "ignore_loglevel"
)

echo "[INFO] Updating $GRUB_FILE (idempotent; replaces key=value params; no duplicates)..."

###############################################################################
# Sanity checks
###############################################################################
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERROR] Run as root."
  exit 1
fi

if [[ ! -f "$GRUB_FILE" ]]; then
  echo "[ERROR] $GRUB_FILE not found"
  exit 1
fi

# Backup GRUB
cp -a "$GRUB_FILE" "$BACKUP_FILE"
echo "[INFO] Backup created: $BACKUP_FILE"

###############################################################################
# Helpers for GRUB_CMDLINE_LINUX_DEFAULT
###############################################################################
get_grub_cmdline_default() {
  local file="$1"
  local line
  line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$file" || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi
  # Extract current value inside quotes (supports empty string too)
  echo "$line" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/'
}

set_grub_cmdline_default() {
  local file="$1"
  local new_value="$2"
  sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$new_value\"|" "$file"
}

# Ensure/replace a param in a cmdline string (space-separated tokens)
# - For flags: ensure token exists once
# - For key=value: replace any existing key=*, then ensure desired key=value exists once
ensure_param_in_cmdline() {
  local cmdline="$1"
  local param="$2"

  # Normalize whitespace early
  cmdline="$(echo "$cmdline" | xargs)"

  if [[ "$param" == *"="* ]]; then
    local key="${param%%=*}"

    # Remove any existing occurrences of key=... (avoid duplicates)
    # Match token boundaries: start or space, then key=..., then end or space
    cmdline="$(echo " $cmdline " | sed -E "s/(^|[[:space:]])${key}=[^[:space:]]+([[:space:]]|$)/ /g")"
    cmdline="$(echo "$cmdline" | xargs)"

    # Add desired key=value (once)
    if [[ " $cmdline " != *" $param "* ]]; then
      cmdline="$cmdline $param"
      echo "[INFO] Set/updated GRUB param: $key -> ${param#*=}"
    else
      echo "[OK] GRUB param already set: $param"
    fi
  else
    # Flag param
    if [[ " $cmdline " != *" $param "* ]]; then
      cmdline="$cmdline $param"
      echo "[INFO] Added GRUB flag: $param"
    else
      echo "[OK] GRUB flag already present: $param"
    fi
  fi

  # Normalize whitespace
  echo "$cmdline" | xargs
}

###############################################################################
# Update GRUB_CMDLINE_LINUX_DEFAULT safely
###############################################################################
CURRENT_VALUE="$(get_grub_cmdline_default "$GRUB_FILE" || true)"
if [[ -z "${CURRENT_VALUE+x}" ]] || ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
  echo "[ERROR] GRUB_CMDLINE_LINUX_DEFAULT not found in $GRUB_FILE"
  exit 1
fi

NEW_VALUE="$CURRENT_VALUE"

for param in "${REQUIRED_PARAMS[@]}"; do
  NEW_VALUE="$(ensure_param_in_cmdline "$NEW_VALUE" "$param")"
done

# Final normalize
NEW_VALUE="$(echo "$NEW_VALUE" | xargs)"

if [[ "$NEW_VALUE" != "$CURRENT_VALUE" ]]; then
  set_grub_cmdline_default "$GRUB_FILE" "$NEW_VALUE"
  echo "[INFO] Updated GRUB_CMDLINE_LINUX_DEFAULT"
else
  echo "[INFO] No GRUB changes needed"
fi

# Update grub.cfg
echo "[INFO] Running update-grub..."
update-grub
echo "[INFO] update-grub completed"

###############################################################################
# Runtime: Make journald persistent + increase retention (no reboot)
###############################################################################
echo
echo "[INFO] Ensuring journald config: Storage=$JOURNALD_STORAGE, SystemMaxUse=$JOURNALD_MAXUSE in $JOURNALD_FILE ..."

if [[ -f "$JOURNALD_FILE" ]]; then
  cp -a "$JOURNALD_FILE" "$JOURNALD_BACKUP"
  echo "[INFO] Backup created: $JOURNALD_BACKUP"
else
  echo "[WARN] $JOURNALD_FILE not found; creating it."
  install -m 0644 /dev/null "$JOURNALD_FILE"
fi

set_or_add_journal_kv() {
  local key="$1" val="$2" file="$3"

  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
    # Replace existing (commented or uncommented)
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=${val}|" "$file"
    echo "[INFO] Updated existing ${key} line"
  else
    if grep -Eq '^\[Journal\][[:space:]]*$' "$file"; then
      # Insert right after [Journal] (first occurrence)
      sed -i -E "/^\[Journal\][[:space:]]*$/a ${key}=${val}" "$file"
      echo "[INFO] Added ${key} under existing [Journal] section"
    else
      # Append minimal config section
      {
        echo
        echo "[Journal]"
        echo "${key}=${val}"
      } >> "$file"
      echo "[INFO] Added new [Journal] section with ${key}"
    fi
  fi
}

# Enforce both keys
set_or_add_journal_kv "Storage" "$JOURNALD_STORAGE" "$JOURNALD_FILE"
set_or_add_journal_kv "SystemMaxUse" "$JOURNALD_MAXUSE" "$JOURNALD_FILE"

# Ensure persistent journal directory exists (systemd uses this for persistence)
if [[ "$JOURNALD_STORAGE" == "persistent" ]]; then
  if [[ ! -d "$PERSIST_DIR" ]]; then
    echo "[INFO] Creating $PERSIST_DIR for persistent journald storage..."
    mkdir -p "$PERSIST_DIR"
    chmod 2755 "$PERSIST_DIR" || true
    chown root:systemd-journal "$PERSIST_DIR" 2>/dev/null || true
  fi
fi

echo "[INFO] Restarting systemd-journald..."
systemctl restart systemd-journald
echo "[INFO] systemd-journald restarted"

echo "[INFO] Effective journald settings (from file):"
grep -E '^[[:space:]]*(Storage|SystemMaxUse)=' "$JOURNALD_FILE" || true

###############################################################################
# Runtime (no reboot) SLUB checks on existing caches
###############################################################################
echo
echo "[INFO] Enabling runtime SLUB checks on /sys/kernel/slab/kmalloc-* (no reboot)..."

SLAB_BASE="/sys/kernel/slab"
if [[ ! -d "$SLAB_BASE" ]]; then
  echo "[WARN] $SLAB_BASE not found; skipping runtime SLUB sysfs toggles."
  exit 0
fi

shopt -s nullglob
slabs=( "$SLAB_BASE"/kmalloc-* )
shopt -u nullglob

if (( ${#slabs[@]} == 0 )); then
  echo "[WARN] No kmalloc-* slab caches found under $SLAB_BASE; skipping."
  exit 0
fi

changed=0
skipped=0

for slab in "${slabs[@]}"; do
  [[ -d "$slab" ]] || continue

  for knob in sanity_checks red_zone poison; do
    f="$slab/$knob"
    if [[ -w "$f" ]]; then
      cur="$(cat "$f" 2>/dev/null || echo "")"
      if [[ "$cur" == "1" ]]; then
        ((skipped++)) || true
        continue
      fi

      if echo 1 > "$f" 2>/dev/null; then
        ((changed++)) || true
      else
        ((skipped++)) || true
      fi
    else
      ((skipped++)) || true
    fi
  done
done

echo "[INFO] Runtime SLUB toggles: changed=$changed skipped=$skipped"

# Show one cache as a quick proof (best-effort)
if [[ -d "$SLAB_BASE/kmalloc-128" ]]; then
  echo "[INFO] kmalloc-128 status (best-effort):"
  for knob in sanity_checks red_zone poison; do
    if [[ -r "$SLAB_BASE/kmalloc-128/$knob" ]]; then
      echo "  $knob=$(cat "$SLAB_BASE/kmalloc-128/$knob" 2>/dev/null || echo '?')"
    fi
  done
fi

echo
echo "[SUCCESS] Done. Boot-time params take effect after next reboot; journald is now persistent with higher retention; runtime slab checks are enabled now."
