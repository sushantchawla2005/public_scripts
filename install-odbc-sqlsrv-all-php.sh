#!/usr/bin/env bash
# Debian 12: ODBC 18 + sqlsrv/pdo_sqlsrv through version-specific PECL builds.
# PECL compiles internally. Run as root during an appropriate maintenance window.
set -Eeuo pipefail
trap 'echo "ERROR at line $LINENO. Installation stopped; earlier versions may already be installed/reloaded." >&2' ERR

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
for ver in "${PHP_VERSIONS[@]}"; do
    for tool in phpize php-config; do
        [[ -x "/usr/bin/${tool}${ver}" ]] || {
            echo "Missing /usr/bin/${tool}${ver}" >&2; exit 1;
        }
    done
    actual=$(/usr/bin/php-config"$ver" --version)
    [[ "$actual" == "$ver".* ]] || {
        echo "php-config${ver} reports unexpected version: $actual" >&2; exit 1;
    }
done

for ver in "${PHP_VERSIONS[@]}"; do
    case "$ver" in
        7.4|8.0) release=5.10.1 ;;
        8.1|8.2|8.3) release=5.12.0 ;;
        8.4) release=5.13.2 ;;
    esac
    echo "=== PHP $ver: SQL Server drivers $release ==="
    php_bin="/usr/bin/php${ver}"
    ext_dir=$(/usr/bin/php-config"$ver" --extension-dir)
    registry="/var/lib/pecl-multiphp/${ver}"
    mkdir -p "$registry"

    # Per-command overrides; no update-alternatives or global PEAR config changes.
    # php_dir provides a separate PECL registry for each PHP version.
    pecl_args=(
        -d "php_bin=$php_bin"
        -d 'php_prefix=/usr/bin/'
        -d "php_suffix=$ver"
        -d "ext_dir=$ext_dir"
        -d "php_dir=$registry"
        -d 'php_ini='
    )
    for ext in sqlsrv pdo_sqlsrv; do
        # Download separately: avoid the channel-update XML request that failed.
        archive_dir=$(mktemp -d /var/tmp/pecl-sqlsrv.XXXXXX)
        archive="$archive_dir/${ext}-${release}.tgz"
        curl --fail --show-error --location --retry 3 \
            "https://pecl.php.net/get/${ext}-${release}.tgz" -o "$archive"
        # Reject an HTML/error response before passing the archive to PECL.
        tar -tzf "$archive" >/dev/null
        # Force allows a repeat run to rebuild the pinned release.
        # /dev/null accepts the extensions' default configure answers.
        env PHP_PEAR_PHP_BIN="$php_bin" "$PECL_BIN" "${pecl_args[@]}" \
            install -f "$archive" </dev/null
        rm -rf -- "$archive_dir"

        [[ -s "$ext_dir/$ext.so" ]] || {
            echo "Missing installed module: $ext_dir/$ext.so" >&2; exit 1;
        }
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
    if [[ -d "/etc/php/${ver}/fpm" ]]; then
        "/usr/sbin/php-fpm${ver}" -t
        # Confirm both modules load under the FPM configuration as well.
        fpm_info=$("/usr/sbin/php-fpm${ver}" -i)
        for ext in sqlsrv pdo_sqlsrv; do
            if ! grep -Eq "^${ext} support => enabled" <<< "$fpm_info"; then
                echo "PHP $ver FPM: $ext is not enabled." >&2; exit 1;
            fi
        done
        if systemctl is-active --quiet "php${ver}-fpm"; then
            systemctl reload "php${ver}-fpm"
        fi
    fi
    echo "=== PHP $ver completed ==="
done

echo 'All six PHP versions completed. Test a real SQL Server connection next.'
