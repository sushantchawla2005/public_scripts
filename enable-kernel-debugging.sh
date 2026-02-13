#!/bin/bash
set -euo pipefail

GRUB_FILE="/etc/default/grub"
BACKUP_FILE="/etc/default/grub.bak.$(date +%F_%H-%M-%S)"

# Boot-time params we want (applied after next reboot)
REQUIRED_PARAMS=(
  "log_buf_len=64M"
  "slab_nomerge"
  "slub_debug=FZP"
  "page_poison=1"
  "ignore_loglevel"
)

echo "[INFO] Updating $GRUB_FILE (idempotent, no duplicate params)..."

# Sanity checks
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root."
  exit 1
fi

if [[ ! -f "$GRUB_FILE" ]]; then
  echo "[ERROR] $GRUB_FILE not found"
  exit 1
fi

# Backup
cp -a "$GRUB_FILE" "$BACKUP_FILE"
echo "[INFO] Backup created: $BACKUP_FILE"

# Read GRUB_CMDLINE_LINUX_DEFAULT
CURRENT_LINE="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)"
if [[ -z "$CURRENT_LINE" ]]; then
  echo "[ERROR] GRUB_CMDLINE_LINUX_DEFAULT not found in $GRUB_FILE"
  exit 1
fi

# Extract current value inside quotes (supports empty string too)
CURRENT_VALUE="$(echo "$CURRENT_LINE" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/')"
NEW_VALUE="$CURRENT_VALUE"

# Add only missing params (avoid duplicates)
for param in "${REQUIRED_PARAMS[@]}"; do
  if [[ " $NEW_VALUE " != *" $param "* ]]; then
    echo "[INFO] Adding missing GRUB param: $param"
    NEW_VALUE="$NEW_VALUE $param"
  else
    echo "[OK] GRUB param already present: $param"
  fi
done

# Normalize whitespace
NEW_VALUE="$(echo "$NEW_VALUE" | xargs)"

# Update file only if changed
if [[ "$NEW_VALUE" != "$CURRENT_VALUE" ]]; then
  sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_VALUE\"|" "$GRUB_FILE"
  echo "[INFO] Updated GRUB_CMDLINE_LINUX_DEFAULT"
else
  echo "[INFO] No GRUB changes needed"
fi

# Update grub.cfg
echo "[INFO] Running update-grub..."
update-grub
echo "[INFO] update-grub completed"

###############################################################################
# Runtime (no reboot) SLUB checks on existing caches
###############################################################################
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
  # Only operate on directories
  [[ -d "$slab" ]] || continue

  for knob in sanity_checks red_zone poison; do
    f="$slab/$knob"
    if [[ -w "$f" ]]; then
      # If already 1, keep as-is
      cur="$(cat "$f" 2>/dev/null || echo "")"
      if [[ "$cur" == "1" ]]; then
        ((skipped++)) || true
        continue
      fi

      # Try to enable
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

echo "[SUCCESS] Done. Boot-time params take effect after next reboot; runtime slab checks are enabled now."
