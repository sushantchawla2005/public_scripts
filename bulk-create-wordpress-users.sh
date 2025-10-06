#!/usr/bin/env bash
set -euo pipefail

CSV_FILE="${1:-/tmp/users.csv}"

APP_ROOT="/home/master/applications"

# WP-CLI
PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
command -v wp >/dev/null 2>&1 || { echo "ERROR: wp not found in PATH"; exit 1; }
WP="wp --allow-root --skip-themes --skip-plugins"

# Feature-detect email flags (older WP-CLI lacks these)
CREATE_NOEMAIL=""   # for `wp user create`
UPDATE_NOEMAIL=""   # for `wp user update`

if $WP help user create 2>/dev/null | grep -q -- '--send-email'; then
  CREATE_NOEMAIL="--send-email=false"
fi
if $WP help user update 2>/dev/null | grep -q -- '--skip-email'; then
  UPDATE_NOEMAIL="--skip-email"
fi

shopt -s nullglob

[[ -s "$CSV_FILE" ]] || { echo "ERROR: CSV not found or empty: $CSV_FILE"; exit 1; }

# Clean CSV: strip CRLF, drop blanks/headers; expect username,email,role[,password]
TMP_CSV="$(mktemp)"
tr -d '\r' <"$CSV_FILE" | awk -F, 'NF>=3 && $2 ~ /@/ && tolower($1)!="username"' >"$TMP_CSV"

# Discover WP installs
mapfile -t WP_PATHS < <(for d in "$APP_ROOT"/*/public_html; do
  [[ -f "$d/wp-config.php" ]] && echo "$d"
done)
echo "Found ${#WP_PATHS[@]} WordPress install(s) under $APP_ROOT."

for wp_path in "${WP_PATHS[@]}"; do
  app="$(basename "$(dirname "$wp_path")")"

  if ! $WP --path="$wp_path" core is-installed >/dev/null 2>&1; then
    echo "Skip $app: not a WP install"
    continue
  fi

  if $WP --path="$wp_path" core is-installed --network >/dev/null 2>&1; then
    echo "=== $app (multisite) ==="
    while IFS=, read -r USERNAME EMAIL ROLE PASSWORD; do
      [[ -z "$USERNAME" || -z "$EMAIL" || -z "$ROLE" ]] && continue

      if ! $WP --path="$wp_path" user get "$USERNAME" >/dev/null 2>&1; then
        $WP --path="$wp_path" user create "$USERNAME" "$EMAIL" ${PASSWORD:+--user_pass="$PASSWORD"} ${CREATE_NOEMAIL:+$CREATE_NOEMAIL}
        echo "  + created network user: $USERNAME"
      else
        [[ -n "${PASSWORD:-}" ]] && $WP --path="$wp_path" user update "$USERNAME" --user_pass="$PASSWORD" ${UPDATE_NOEMAIL:+$UPDATE_NOEMAIL} >/dev/null
        echo "  = network user exists: $USERNAME"
      fi

      while IFS= read -r URL; do
        $WP --path="$wp_path" --url="$URL" user set-role "$USERNAME" "$ROLE" >/dev/null || true
        echo "    ↳ $ROLE @ $URL"
      done < <($WP --path="$wp_path" site list --field=url)
    done < "$TMP_CSV"

  else
    echo "=== $app (single) ==="
    while IFS=, read -r USERNAME EMAIL ROLE PASSWORD; do
      [[ -z "$USERNAME" || -z "$EMAIL" || -z "$ROLE" ]] && continue

      if $WP --path="$wp_path" user get "$USERNAME" >/dev/null 2>&1; then
        $WP --path="$wp_path" user update "$USERNAME" --role="$ROLE" ${PASSWORD:+--user_pass="$PASSWORD"} ${UPDATE_NOEMAIL:+$UPDATE_NOEMAIL}
        echo "  = updated $USERNAME"
      else
        $WP --path="$wp_path" user create "$USERNAME" "$EMAIL" --role="$ROLE" ${PASSWORD:+--user_pass="$PASSWORD"} ${CREATE_NOEMAIL:+$CREATE_NOEMAIL}
        echo "  + created $USERNAME"
      fi
    done < "$TMP_CSV"
  fi
done

rm -f "$TMP_CSV"
echo "Done."
