#!/usr/bin/env bash
# bulk-create-wordpress-users.sh  (cd-based; no --path)
set -euo pipefail

CSV="${1:-}"
[[ -n "$CSV" ]] || { echo "Usage: $0 /path/to/users.csv"; exit 1; }
[[ -s "$CSV" ]] || { echo "ERROR: CSV missing or empty: $CSV"; exit 1; }

APP_ROOT="/home/master/applications"
[[ -d "$APP_ROOT" ]] || { echo "ERROR: $APP_ROOT not found"; exit 1; }

# Make sure wp is reachable; allow root if script is run via sudo
PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
command -v wp >/dev/null 2>&1 || { echo "ERROR: wp not found in PATH"; exit 1; }
export WP_CLI_ALLOW_ROOT=1
WP="wp --skip-themes --skip-plugins"

# Normalize CSV (strip CRLF, blank lines)
TMP_CSV="$(mktemp)"
trap 'rm -f "$TMP_CSV"' EXIT
tr -d '\r' < "$CSV" | awk 'NF>0' > "$TMP_CSV"

# Find WordPress installs
mapfile -t WP_DIRS < <(for d in "$APP_ROOT"/*/public_html; do
  [[ -f "$d/wp-config.php" ]] && echo "$d";
done)

echo "Found ${#WP_DIRS[@]} WordPress install(s) under $APP_ROOT."

for dir in "${WP_DIRS[@]}"; do
  app="$(basename "$(dirname "$dir")")"

  if ! (cd "$dir" && $WP core is-installed >/dev/null 2>&1); then
    echo "Skip $app: not a WP install"
    continue
  fi

  if (cd "$dir" && $WP core is-installed --network >/dev/null 2>&1); then
    echo "=== $app (multisite) ==="
    # Ensure network user exists; then set role on each site
    while IFS=, read -r login email role pass; do
      # skip header or bad lines
      [[ -z "$login" || -z "$email" || -z "$role" ]] && continue
      [[ "$login" == "Username" || "$email" == "Email" || "$role" == "Role" ]] && continue

      if ! (cd "$dir" && $WP user get "$login" >/dev/null 2>&1); then
        (cd "$dir" && $WP user create "$login" "$email" ${pass:+--user_pass="$pass"}) >/dev/null
        echo "  [OK] network user created: $login"
      else
        [[ -n "${pass:-}" ]] && (cd "$dir" && $WP user update "$login" --user_pass="$pass" >/dev/null)
        echo "  [OK] network user exists: $login"
      fi

      # Assign role on each site in the network
      while IFS= read -r url; do
        (cd "$dir" && $WP --url="$url" user set-role "$login" "$role") >/dev/null || true
        echo "    ↳ role=$role @ $url"
      done < <(cd "$dir" && $WP site list --field=url)
    done < "$TMP_CSV"

  else
    echo "=== $app (single) ==="
    while IFS=, read -r login email role pass; do
      [[ -z "$login" || -z "$email" || -z "$role" ]] && continue
      [[ "$login" == "Username" || "$email" == "Email" || "$role" == "Role" ]] && continue

      if (cd "$dir" && $WP user get "$login" >/dev/null 2>&1); then
        (cd "$dir" && $WP user update "$login" --role="$role" ${pass:+--user_pass="$pass"}) >/dev/null
        echo "  [OK] updated $login"
      else
        (cd "$dir" && $WP user create "$login" "$email" --role="$role" ${pass:+--user_pass="$pass"}) >/dev/null
        echo "  [OK] created $login"
      fi
    done < "$TMP_CSV"
  fi
done

echo "Done."
