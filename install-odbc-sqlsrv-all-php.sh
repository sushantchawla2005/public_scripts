#!/usr/bin/env bash
# Debian 12: ODBC 18 + sqlsrv/pdo_sqlsrv through version-specific PECL builds.
# PECL compiles internally. Run as root during an appropriate maintenance window.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
source /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 12 ]] || {
    echo 'This script is intended for Debian 12 only.' >&2; exit 1;
}

PHP_VERSIONS=(7.4 8.0 8.1 8.2 8.3 8.4)
for ver in "${PHP_VERSIONS[@]}"; do
    [[ -x "/usr/bin/php${ver}" ]] || {
        echo "Missing /usr/bin/php${ver}" >&2; exit 1;
    }
done

apt-get update
apt-get install -y curl ca-certificates
repo_tmp=$(mktemp -d /var/tmp/microsoft-repo.XXXXXX)
curl -fsSL --retry 3 \
    https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb \
    -o "$repo_tmp/packages-microsoft-prod.deb"
dpkg -i "$repo_tmp/packages-microsoft-prod.deb"
rm -rf -- "$repo_tmp"
apt-get update
ACCEPT_EULA=Y apt-get install -y msodbcsql18 mssql-tools18
dpkg-query -W msodbcsql18
odbcinst -q -d -n 'ODBC Driver 18 for SQL Server'

deps=(unixodbc-dev build-essential autoconf pkg-config php-pear)
for ver in "${PHP_VERSIONS[@]}"; do
    deps+=("php${ver}-dev" "php${ver}-xml")
done
apt-get install -y "${deps[@]}"

PECL_BIN=$(command -v pecl)
command -v phpenmod >/dev/null
process_version() {
    local ver="$1"
    local tool actual release php_bin ext_dir registry ext ini sapi
    local archive_dir archive fpm_info installed_any=0
    local -a pecl_args
    for tool in php phpize php-config; do
        [[ -x "/usr/bin/${tool}${ver}" ]] || {
            echo "Missing /usr/bin/${tool}${ver}" >&2; return 1;
        }
    done
    actual=$(/usr/bin/php-config"$ver" --version)
    [[ "$actual" == "$ver".* ]] || {
        echo "php-config${ver} reports unexpected version: $actual" >&2; return 1;
    }
    case "$ver" in
        7.4|8.0) release=5.10.1 ;;
        8.1|8.2|8.3) release=5.12.0 ;;
        8.4) release=5.13.2 ;;
    esac
    echo "=== PHP $ver: SQL Server drivers $release ==="
    php_bin="/usr/bin/php${ver}"
    ext_dir=$(/usr/bin/php-config"$ver" --extension-dir)
    registry="/var/lib/pecl-multiphp/${ver}"
    mkdir -p "$registry/php" "$registry/metadata"

    # Per-command overrides; no update-alternatives or global PEAR config changes.
    # metadata_dir MUST be isolated too: Debian can configure a shared registry.
    pecl_args=(
        -d "php_bin=$php_bin"
        -d 'php_prefix=/usr/bin/'
        -d "php_suffix=$ver"
        -d "ext_dir=$ext_dir"
        -d "php_dir=$registry/php"
        -d "metadata_dir=$registry/metadata"
        -d 'php_ini='
    )
    for ext in sqlsrv pdo_sqlsrv; do
        # A shared/channel-specific registry can override the directory settings.
        # Forget only the registration, NEVER remove installed module files.
        if env PHP_PEAR_PHP_BIN="$php_bin" "$PECL_BIN" "${pecl_args[@]}" \
            info "pecl.php.net/$ext" >/dev/null 2>&1; then
            env PHP_PEAR_PHP_BIN="$php_bin" "$PECL_BIN" "${pecl_args[@]}" \
                uninstall --register-only "pecl.php.net/$ext"
        fi
        # Enable configuration first: an installed but disabled module needs no rebuild.
        ini="/etc/php/${ver}/mods-available/${ext}.ini"
        mkdir -p "$(dirname "$ini")"
        if [[ ! -e "$ini" ]]; then
            printf '; priority=30\nextension=%s.so\n' "$ext" > "$ini"
        fi
        for sapi in cli fpm; do
            if [[ -d "/etc/php/${ver}/${sapi}/conf.d" ]]; then
                phpenmod -v "$ver" -s "$sapi" "$ext"
            fi
        done

        # Check the actual PHP runtime, not the PECL registry or just the INI file.
        if "$php_bin" -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$ext" 2>/dev/null; then
            echo "SKIP PHP $ver: $ext already loads successfully."
            continue
        fi

        archive_dir=$(mktemp -d /var/tmp/pecl-sqlsrv.XXXXXX)
        archive="$archive_dir/${ext}-${release}.tgz"
        curl --fail --show-error --location --retry 3 \
            "https://pecl.php.net/get/${ext}-${release}.tgz" -o "$archive"
        tar -tzf "$archive" >/dev/null
        env PHP_PEAR_PHP_BIN="$php_bin" "$PECL_BIN" "${pecl_args[@]}" \
            install "$archive" </dev/null
        # Prevent later PECL installs from treating this binary as replaceable.
        env PHP_PEAR_PHP_BIN="$php_bin" "$PECL_BIN" "${pecl_args[@]}" \
            uninstall --register-only "pecl.php.net/$ext"
        rm -rf -- "$archive_dir"
        installed_any=1
        "$php_bin" -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$ext"
    done

    "$php_bin" -r '
        foreach (["sqlsrv", "pdo_sqlsrv"] as $ext) {
            if (!extension_loaded($ext)) {
                fwrite(STDERR, "$ext failed to load\n"); exit(1);
            }
            echo PHP_VERSION." ".$ext." ".phpversion($ext).PHP_EOL;
        }
        if (!in_array("sqlsrv", PDO::getAvailableDrivers(), true)) {
            fwrite(STDERR, "SQL Server PDO driver missing\n"); exit(1);
        }
    '
    if systemctl is-active --quiet "php${ver}-fpm"; then
        "/usr/sbin/php-fpm${ver}" -t
        # Confirm both modules load under the FPM configuration as well.
        fpm_info=$("/usr/sbin/php-fpm${ver}" -i)
        for ext in sqlsrv pdo_sqlsrv; do
            if ! grep -Eq "^${ext} support => enabled" <<< "$fpm_info"; then
                echo "PHP $ver FPM: $ext is not enabled." >&2; exit 1;
            fi
        done
        systemctl reload "php${ver}-fpm"
    else
        echo "PHP $ver FPM is inactive: skipping pool validation and reload."
    fi
    if (( installed_any )); then
        echo "=== PHP $ver: missing drivers installed and verified ==="
    else
        echo "=== PHP $ver: drivers already available; configuration verified ==="
    fi
}

failed=()
passed=()
for ver in "${PHP_VERSIONS[@]}"; do
    # Run as an unguarded subshell so errexit remains effective inside the function.
    # Capture its exit status in the parent and continue with the next PHP version.
    set +e
    (
        set -euo pipefail
        process_version "$ver"
    )
    status=$?
    set -e
    if (( status == 0 )); then
        passed+=("$ver")
    else
        failed+=("$ver")
        echo "FAILED PHP $ver (exit $status); continuing with remaining versions." >&2
    fi
done

# Recheck ALL runtimes after the last install, catching cross-version file removal.
echo '=== Final verification after all PECL installations ==='
for ver in "${PHP_VERSIONS[@]}"; do
    if ! "/usr/bin/php${ver}" -r '
        foreach (["sqlsrv", "pdo_sqlsrv"] as $ext) {
            if (!extension_loaded($ext)) {
                fwrite(STDERR, PHP_VERSION." missing ".$ext.PHP_EOL); exit(1);
            }
        }
        if (!in_array("sqlsrv", PDO::getAvailableDrivers(), true)) { exit(1); }
        echo PHP_VERSION." sqlsrv=".phpversion("sqlsrv").
            " pdo_sqlsrv=".phpversion("pdo_sqlsrv").PHP_EOL;
    '; then
        # Keep each failed version listed only once.
        if [[ " ${failed[*]} " != *" $ver "* ]]; then
            failed+=("$ver")
        fi
    fi
done

# Report success only for versions that also survived final verification.
verified=()
for ver in "${passed[@]}"; do
    if [[ " ${failed[*]} " != *" $ver "* ]]; then
        verified+=("$ver")
    fi
done
printf '\nSuccessful PHP versions: %s\n' "${verified[*]:-none}"
if (( ${#failed[@]} )); then
    printf 'Failed PHP versions: %s\n' "${failed[*]}" >&2
    exit 1
fi
echo 'All six PHP versions completed. Test a real SQL Server connection next.'
