#!/usr/bin/env bash
# bulk-create-wordpress-users.sh  (cd-based; no --path)
# - Creates/updates users from a CSV: username,email,role,password
# - Works for single-site and multisite
# - Handles "email already used" by mapping to the existing account
# - Skips header lines and blank rows

set -euo pipefail
set -E
trap 'echo "[ERR] line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

CSV="${1:-}"
[[ -n "$CSV" ]] || { echo "Usage: $0 /path/to/users.csv"; exit 1; }
[[ -s "$CSV" ]] || { echo "ERROR: CSV missing or empty: $CSV"; exit 1; }

APP_ROOT="/home/master/applications"
[[ -d "$APP_ROOT" ]] || { echo "ERROR: $APP_ROOT not found"; exit 1; }

# Ensure wp is reachable; allow root if invoked via sudo
PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
command -v wp >/dev/null 2>&1 || { echo "ERROR: wp not found in PATH"; exit 1; }
export WP_CLI_ALLOW_ROOT=1
WP_BASE="wp --skip-themes --skip-plugins"

# Normalize CSV (strip CRLF, blank lines)
TMP_CSV="$(mktemp)"
trap 'rm -f "$TMP_CSV"' EXIT
tr -d '\r' < "$CSV" | awk 'NF>0' > "$TMP_CSV"

# Find WordPress installs
mapfile -t WP_DIRS < <(for d in "$APP_ROOT"/*/public_html; do
  [[ -f "$d/wp-config.php" ]] && echo "$d"
done)

echo "Found ${#WP_DIRS[@]} WordPress install(s) under $APP_ROOT."

# Helpers
wp_in_dir() {
  # usage: wp_in_dir <dir> <wp-args...>
  local _dir="$1"; shift
  ( cd "$_dir" && $WP_BASE "$@" )
}

# If a user with this login exists -> echo login and return 0
# Else if a user with this email exists -> echo *that* login and return 0
# Else return 1
resolve_user_login_by_login_or_email() {
  local dir="$1" login="$2" email="$3"
  if wp_in_dir "$dir" user get "$login" >/dev/null 2>&1; then
    echo "$login"; return 0
  fi
  # WP-CLI accepts email in place of <user>
  if wp_in_dir "$dir" user get "$email" >/dev/null 2>&1; then
    # Normalize to login name for subsequent calls
    local existing_login
    existing_login="$(wp_in_dir "$dir" user get "$email" --field=user_login)"
    echo "$existing_login"; return 0
  fi
  return 1
}

assign_role_on_all_sites() {
  # Multisite: set role for user on each site; fallback to add-role if needed
  local dir="$1" user_ident="$2" role="$3"
  while IFS= read -r url; do
    wp_in_dir "$dir" --url="$url" user set-role "$user_ident" "$role" >/dev/null 2>&1 \
      || wp_in_dir "$dir" --url="$url" user add-role "$user_ident" "$role" >/dev/null 2>&1 \
      || true
    echo "    ↳ role=$role @ $url"
  done < <(wp_in_dir "$dir" site list --field=url)
}

for dir in "${WP_DIRS[@]}"; do
  app="$(basename "$(dirname "$dir")")"

  if ! wp_in_dir "$dir" core is-installed >/dev/null 2>&1; then
    echo "Skip $app: not a WP install"
    continue
  fi

  if wp_in_dir "$dir" core is-installed --network >/dev/null 2>&1; then
    echo "=== $app (multisite) ==="
    while IFS=, read -r login email role pass; do
      # Skip headers/partials
      [[ -z "${login:-}" || -z "${email:-}" || -z "${role:-}" ]] && continue
      [[ "$login" == "Username" || "$email" == "Email" || "$role" == "Role" ]] && continue
      pass="${pass:-}"

      if resolved_login="$(resolve_user_login_by_login_or_email "$dir" "$login" "$email")"; then
        # Update password if provided
        [[ -n "$pass" ]] && wp_in_dir "$dir" user update "$resolved_login" --user_pass="$pass" >/dev/null || true
        echo "  [OK] network user exists: $resolved_login (from ${login}/${email})"
      else
        # Create at network level
        wp_in_dir "$dir" user create "$login" "$email" ${pass:+--user_pass="$pass"} >/dev/null
        resolved_login="$login"
        echo "  [OK] network user created: $login"
      fi
      assign_role_on_all_sites "$dir" "$resolved_login" "$role"
    done < "$TMP_CSV"

  else
    echo "=== $app (single) ==="
    while IFS=, read -r login email role pass; do
      [[ -z "${login:-}" || -z "${email:-}" || -z "${role:-}" ]] && continue
      [[ "$login" == "Username" || "$email" == "Email" || "$role" == "Role" ]] && continue
      pass="${pass:-}"

      if resolved_login="$(resolve_user_login_by_login_or_email "$dir" "$login" "$email")"; then
        # Existing user (by login or by email)
        wp_in_dir "$dir" user update "$resolved_login" --role="$role" ${pass:+--user_pass="$pass"} >/dev/null || true
        echo "  [OK] updated $resolved_login (role${pass:++pass})"
      else
        # New user
        wp_in_dir "$dir" user create "$login" "$email" --role="$role" ${pass:+--user_pass="$pass"} >/dev/null
        echo "  [OK] created $login"
      fi
    done < "$TMP_CSV"
  fi
done

echo "Done."
