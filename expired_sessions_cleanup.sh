#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
WP_PATH="."
BATCH_SIZE="${BATCH_SIZE:-20000}"

# ===== Initialize WP-CLI =====
if [ "$(id -u)" -eq 0 ]; then
    WP="/usr/local/bin/wp --allow-root --skip-themes --skip-plugins --path=$WP_PATH"
else
    WP="/usr/local/bin/wp --skip-themes --skip-plugins --path=$WP_PATH"
fi

# ===== PRECHECKS =====
command -v /usr/local/bin/wp >/dev/null || { echo "wp (WP-CLI) not found"; exit 1; }
[ -d "$WP_PATH" ] || { echo "WP_PATH not found: $WP_PATH"; exit 1; }
$WP core is-installed >/dev/null || { echo "WordPress not installed at $WP_PATH"; exit 1; }

# ===== Prefix detection =====
PREFIX="$($WP db prefix | tr -d '[:space:]')"
[ -n "$PREFIX" ] || PREFIX="wp_"
SESS_TBL="${PREFIX}woocommerce_sessions"

# ===== Expired sessions cleanup =====
echo "🧹 Purging expired WooCommerce sessions from $SESS_TBL..."

count_expired() {
  $WP db query --skip-column-names --silent "
    SELECT COUNT(*) FROM ${SESS_TBL}
    WHERE session_expiry < UNIX_TIMESTAMP(CURDATE());
  "
}

to_delete="$(count_expired || echo 0)"
echo "Found ${to_delete} expired sessions."

if [ "$to_delete" -gt 0 ]; then
  while :; do
    $WP db query --skip-column-names --silent "
      DELETE FROM ${SESS_TBL}
      WHERE session_expiry < UNIX_TIMESTAMP(CURDATE())
      LIMIT ${BATCH_SIZE};
    " || true

    remaining="$(count_expired || echo 0)"
    echo "Remaining: $remaining"
    [ "$remaining" -gt 0 ] || break
    sleep 1
  done

  $WP db query "OPTIMIZE TABLE ${SESS_TBL};" || true
fi

echo "✅ Purge complete at $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
