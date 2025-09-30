#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
WP_PATH="${WP_PATH:-/path/to/wordpress}"
BATCH_SIZE="${BATCH_SIZE:-20000}"                        # delete LIMIT per batch
LOG_FILE="/tmp/wc_session_purge.log"

# ===== PRECHECKS =====
command -v wp >/dev/null || { echo "wp (WP-CLI) not found"; exit 1; }
[ -d "$WP_PATH" ] || { echo "WP_PATH not found: $WP_PATH"; exit 1; }
wp core is-installed --path="$WP_PATH" >/dev/null || { echo "WordPress not installed at $WP_PATH"; exit 1; }

# Detect table prefix (avoid --quiet due to some envs swallowing output)
PREFIX="$(wp db prefix --path="$WP_PATH" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$PREFIX" ]; then
  PREFIX="$(wp eval 'global $wpdb; echo $wpdb->prefix;' --path="$WP_PATH" 2>/dev/null | tr -d '[:space:]' || true)"
fi
[ -n "$PREFIX" ] || PREFIX="wp_"

SESS_TBL="${PREFIX}woocommerce_sessions"

# Verify table exists via information_schema
TBL_EXISTS="$(wp db query --path="$WP_PATH" --skip-column-names --quiet "
  SELECT COUNT(*) FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '${SESS_TBL}';
" 2>/dev/null | tr -d '[:space:]' || echo 0)"
if [ "$TBL_EXISTS" != "1" ]; then
  echo "Table not found: ${SESS_TBL} (Is WooCommerce installed?)"
  # Still log a zero so you have a run record
  mkdir -p "$(dirname "$LOG_FILE")" || true
  [ -f "$LOG_FILE" ] || echo "timestamp_utc,site_url,window,deleted_rows" > "$LOG_FILE"
  SITE_URL="$(wp option get siteurl --path="$WP_PATH" 2>/dev/null || echo '-')"
  printf "%s,%s,%s,%d\n" \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "$SITE_URL" \
    "session_expiry < start_of_today" \
    0 >> "$LOG_FILE"
  exit 0
fi

echo "🧹 Purging WooCommerce sessions expired before start of today from ${SESS_TBL}..."

# Helpers
count_expired() {
  wp db query --path="$WP_PATH" --skip-column-names --silent "
    SELECT COUNT(*) FROM ${SESS_TBL}
    WHERE session_expiry < UNIX_TIMESTAMP(CURDATE());
  "
}

SITE_URL="$(wp option get siteurl --path="$WP_PATH" 2>/dev/null || echo '-')"
TODAY_UTC="$(date -u +"%Y-%m-%d 00:00:00 UTC")"

to_delete="$(count_expired || echo 0)"
echo "Found ${to_delete} expired sessions (before today)."

deleted_total=0

if [ "$to_delete" -gt 0 ]; then
  while :; do
    # Perform one batch delete
    wp db query --path="$WP_PATH" --skip-column-names --silent "
      DELETE FROM ${SESS_TBL}
      WHERE session_expiry < UNIX_TIMESTAMP(CURDATE())
      LIMIT ${BATCH_SIZE};
    " || true

    remaining="$(count_expired || echo 0)"

    # Derive batch count from difference
    batch_deleted=$(( to_delete - remaining ))
    if [ "$batch_deleted" -gt 0 ]; then
      deleted_total=$(( deleted_total + batch_deleted ))
    fi
    to_delete="$remaining"

    echo "Remaining: $remaining"
    [ "$remaining" -gt 0 ] || break
    sleep 1
  done

  # Optional: optimize if we actually deleted rows
  if [ "$deleted_total" -gt 0 ]; then
    wp db query --path="$WP_PATH" "OPTIMIZE TABLE ${SESS_TBL};" || true
  fi
fi

# ===== LOGGING =====
mkdir -p "$(dirname "$LOG_FILE")" || true
[ -f "$LOG_FILE" ] || echo "timestamp_utc,site_url,window,deleted_rows" > "$LOG_FILE"
printf "%s,%s,%s,%d\n" \
  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  "$SITE_URL" \
  "session_expiry < start_of_today (${TODAY_UTC})" \
  "$deleted_total" >> "$LOG_FILE"

echo "✅ Purge complete at $(date -u +"%Y-%m-%d %H:%M:%S UTC"). Deleted rows: ${deleted_total}."
echo "📝 Log: $LOG_FILE"
