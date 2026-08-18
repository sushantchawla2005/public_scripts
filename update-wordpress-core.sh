#!/usr/bin/env bash

# WordPress core bulk updater for Cloudways
#
# Features:
# - Discovers applications automatically
# - Uses each application user for WP-CLI
# - Handles relative wp-config.php includes such as wp-salt.php
# - Tests each website before and after updating
# - Adds a random query string to bypass page caches
# - Follows redirects and records the final HTTP status
# - Skips sites that are unhealthy before updating
# - Writes CSV and error-log reports
#
# Run as root:
#   chmod +x /root/test.sh
#   /root/test.sh

set -u

SERVER_ID="${1:-}"
ORIGIN_IP="127.0.0.1"

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <server-id>"
    exit 1
fi

APPS_ROOT="/home/master/applications"
REAL_APPS_ROOT="/home/${SERVER_ID}.cloudwaysapps.com"

RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="/home/master/wp-core-update-${RUN_TIMESTAMP}.tsv"
ERROR_LOG="/home/master/wp-core-update-errors-${RUN_TIMESTAMP}.log"

CONNECT_TIMEOUT=10
MAX_TIME=45
POST_UPDATE_DELAY=2

printf 'application\tdomain\tversion_before\tpre_http\tupdate_result\tversion_after\tpost_http\tstatus\n' \
    > "$REPORT"

touch "$ERROR_LOG"

get_domain() {
    local app="$1"
    local conf="$APPS_ROOT/$app/conf/server.nginx"

    [ -r "$conf" ] || return 1

    awk '
        NR == 1 {
            domain = $NF
            sub(/;$/, "", domain)
            print domain
            exit
        }
    ' "$conf"
}

wp_run() {
    local app="$1"
    local wp_path="$2"

    shift 2

    # Changing directory is required because some wp-config.php files use
    # relative includes, for example:
    #
    #   require("wp-salt.php");
    #
    # Running WP-CLI only with --path would not resolve that file correctly.
    sudo -u "$app" -- bash -c '
        wp_path="$1"
        shift

        cd "$wp_path" || exit 1

        exec wp \
            --path="$wp_path" \
            --skip-plugins \
            --skip-themes \
            "$@"
    ' bash "$wp_path" "$@"
}

test_site() {
    local domain="$1"
    local phase="$2"
    local cachebuster
    local url
    local http_code
    local curl_rc

    cachebuster="_cw_update_check=${phase}-$(date +%s)-${RANDOM}-${RANDOM}"
    url="https://${domain}/?${cachebuster}"

    printf 'Request URL:  %s\n' "$url" >&2
    printf 'Origin route: all redirect hosts -> 127.0.0.1\n' >&2

    http_code="$(
        curl \
            --silent \
            --insecure \
            --show-error \
            --location \
            --max-redirs 10 \
            --output /dev/null \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            --noproxy '*' \
            --proto '=http,https' \
            --proto-redir '=http,https' \
            --user-agent "Cloudways-WordPress-Update-Check/1.0" \
            --resolve "*:443:127.0.0.1" \
            --resolve "*:80:127.0.0.1" \
            --write-out '%{http_code}' \
            "$url" 2>>"$ERROR_LOG"
    )"

    curl_rc=$?

    if [ "$curl_rc" -ne 0 ] ||
       [ -z "$http_code" ] ||
       [ "$http_code" = "000" ]; then
        printf '000'
    else
        printf '%s' "$http_code"
    fi
}

is_healthy_code() {
    case "$1" in
        2??|3??)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

tsv_safe() {
    # Prevent tabs or line breaks inside a value from breaking the columns.
    printf '%s' "$1" | tr '\t\r\n' '   '
}

write_report() {
    local application="$1"
    local domain="$2"
    local version_before="$3"
    local pre_http="$4"
    local update_result="$5"
    local version_after="$6"
    local post_http="$7"
    local status="$8"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(tsv_safe "$application")" \
        "$(tsv_safe "$domain")" \
        "$(tsv_safe "$version_before")" \
        "$(tsv_safe "$pre_http")" \
        "$(tsv_safe "$update_result")" \
        "$(tsv_safe "$version_after")" \
        "$(tsv_safe "$post_http")" \
        "$(tsv_safe "$status")" \
        >> "$REPORT"
}

for app_path in "$APPS_ROOT"/*; do
    [ -d "$app_path" ] || continue

    app="$(basename "$app_path")"
    wp_path="$REAL_APPS_ROOT/$app/public_html"

    printf '\n============================================================\n'
    printf 'Application: %s\n' "$app"

    domain="$(get_domain "$app")"

    if [ -z "$domain" ]; then
        printf 'SKIPPED: Unable to determine primary domain\n'

        write_report \
            "$app" "" "" "" \
            "skipped" "" "" "domain-not-found"

        continue
    fi

    printf 'Domain:      %s\n' "$domain"
    printf 'WP path:     %s\n' "$wp_path"

    if [ ! -d "$wp_path" ]; then
        printf 'SKIPPED: public_html directory not found\n'

        write_report \
            "$app" "$domain" "" "" \
            "skipped" "" "" "public-html-not-found"

        continue
    fi

    # Detect WordPress through its core filesystem structure.
    if [ ! -f "$wp_path/wp-config.php" ] ||
       [ ! -f "$wp_path/wp-load.php" ] ||
       [ ! -f "$wp_path/wp-settings.php" ] ||
       [ ! -d "$wp_path/wp-admin" ] ||
       [ ! -d "$wp_path/wp-includes" ]; then

        printf 'SKIPPED: WordPress core files not found\n'

        write_report \
            "$app" "$domain" "" "" \
            "skipped" "" "" "not-wordpress"

        continue
    fi

    printf 'Checking installed WordPress version...\n'

    version_before="$(
        wp_run "$app" "$wp_path" core version \
            2>>"$ERROR_LOG"
    )"
    version_rc=$?

    if [ "$version_rc" -ne 0 ] || [ -z "$version_before" ]; then
        printf 'SKIPPED: WP-CLI could not determine the core version\n'
        printf 'Error log:   %s\n' "$ERROR_LOG"

        write_report \
            "$app" "$domain" "" "" \
            "skipped" "" "" "version-check-failed"

        continue
    fi

    printf 'Version:     %s\n' "$version_before"
    printf 'Testing site before update...\n'

    pre_http="$(test_site "$domain" "before")"

    printf 'Before HTTP: %s\n' "$pre_http"


    if ! is_healthy_code "$pre_http"; then
        printf 'SKIPPED: Site was not healthy before update\n'

        write_report \
            "$app" "$domain" "$version_before" "$pre_http" \
            "skipped" "$version_before" "" "pre-check-failed"

        continue
    fi

    printf 'Updating WordPress core...\n'

    if wp_run "$app" "$wp_path" core update \
        2>>"$ERROR_LOG"; then
        update_result="success"
    else
        update_result="core-update-failed"
    fi

    if [ "$update_result" = "success" ]; then
        printf 'Running WordPress database update...\n'

        if ! wp_run "$app" "$wp_path" core update-db \
            2>>"$ERROR_LOG"; then
            update_result="database-update-failed"
        fi
    fi

    version_after="$(
        wp_run "$app" "$wp_path" core version \
            2>>"$ERROR_LOG"
    )"
    version_after_rc=$?

    if [ "$version_after_rc" -ne 0 ] ||
       [ -z "$version_after" ]; then
        version_after="unknown"
    fi

    sleep "$POST_UPDATE_DELAY"

    printf 'Testing site after update...\n'

    post_http="$(test_site "$domain" "after")"

    printf 'Update:      %s\n' "$update_result"
    printf 'New version: %s\n' "$version_after"
    printf 'After HTTP:  %s\n' "$post_http"

    if ! is_healthy_code "$post_http"; then
        final_status="post-check-failed"
    elif [ "$update_result" != "success" ]; then
        final_status="$update_result"
    elif [ "$version_after" = "unknown" ]; then
        final_status="post-version-check-failed"
    else
        final_status="healthy"
    fi

    printf 'Result:      %s\n' "$final_status"

    write_report \
        "$app" "$domain" "$version_before" "$pre_http" \
        "$update_result" "$version_after" "$post_http" \
        "$final_status"
done

printf '\n============================================================\n'
printf 'Processing completed.\n'
printf 'TSV report: %s\n' "$REPORT"
printf 'Error log:  %s\n' "$ERROR_LOG"

printf '\nGoogle Sheets output — copy and paste into cell A1:\n\n'
cat "$REPORT"
