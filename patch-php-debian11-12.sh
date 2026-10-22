#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run this script as root.' >&2; exit 1; }
source /etc/os-release
if [[ ${ID:-} != debian || ! ${VERSION_ID:-} =~ ^(11|12)$ ]]; then
    echo "Unsupported OS: ${PRETTY_NAME:-unknown}. Debian 11/12 only." >&2
    exit 1
fi

versions=(7.4 8.0 8.1 8.2 8.3 8.4)
extensions=(bcmath bz2 cgi cli common curl dba dev enchant fpm gd gmp igbinary imagick imap interbase intl mbstring memcached mongodb msgpack mysql odbc opcache pgsql phpdbg readline redis soap sqlite3 sybase tidy xdebug xml xmlrpc xsl zip)
packages=(dh-php newrelic-php5 newrelic-php5-common php-common php-pear pkg-php-tools)
for v in "${versions[@]}"; do
    packages+=("libphp$v-embed" "php$v")
    for ext in "${extensions[@]}"; do
        packages+=("php$v-$ext")
    done
done

# Requires the existing PHP and New Relic package repositories.
echo "Updating package lists on $PRETTY_NAME..."
apt-get update

# Keep existing configuration files when dpkg encounters modified conffiles.
echo 'Installing/upgrading PHP packages...'
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::='--force-confdef' \
    -o Dpkg::Options::='--force-confold' \
    "${packages[@]}"

echo 'Checking PHP-FPM PID paths...'
failed=0
for v in "${versions[@]}"; do
    conf="/etc/php/$v/fpm/php-fpm.conf"
    expected="/run/php/php$v-fpm.pid"
    if [[ ! -f $conf ]]; then
        echo "FAIL: Missing $conf" >&2
        failed=1
        continue
    fi
    actual=$(awk '/^[[:space:]]*pid[[:space:]]*=/ {
        sub(/^[[:space:]]*pid[[:space:]]*=[[:space:]]*/, "")
        sub(/[[:space:]]*;.*/, "")
        sub(/[[:space:]]*$/, "")
        print
    }' "$conf")
    if [[ $actual == "$expected" ]]; then
        echo "OK: $conf:pid = $actual"
    else
        echo "FAIL: $conf: expected '$expected', found '${actual:-unset}'" >&2
        failed=1
    fi
done

if (( failed )); then
    echo 'Package installation completed, but PID verification failed.' >&2
    exit 1
fi
echo 'Package installation and PID verification completed successfully.'
