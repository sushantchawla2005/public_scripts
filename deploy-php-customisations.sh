#!/usr/bin/env bash
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }

assignment_pattern='^[[:blank:]]*([A-Za-z0-9_.-]+)[[:blank:]]*=(.*)$'
version_pattern='^[0-9]+\.[0-9]+$'
[[ $# == 2 && ( $1 == all || $1 =~ $version_pattern ) ]] ||
    die "Usage: $0 <PHP_VERSION|all> 'directive=value'"
[[ $2 != *$'\n'* && $2 != *$'\r'* && $2 =~ $assignment_pattern ]] ||
    die 'Provide one INI assignment, such as opcache.memory_consumption=256M.'
key=${BASH_REMATCH[1]}
value=${BASH_REMATCH[2]}
assignment="$key=$value"
[[ ! $value =~ ^[[:blank:]]*= ]] ||
    die "Invalid INI assignment: $assignment"

cloudways_ui_only=0
case "$key" in
    max_execution_time|upload_max_filesize|memory_limit|date.timezone|error_reporting|\
    display_errors|max_input_vars|max_input_time|opcache.memory_consumption|short_open_tag)
        cloudways_ui_only=1
        ;;
    zend_extension)
        xdebug_pattern="^[[:blank:]]*([\"']?)([^\"']*/)?xdebug\\.so\\1[[:blank:]]*(;.*)?$"
        if [[ $value =~ $xdebug_pattern ]]; then
            cloudways_ui_only=1
        fi
        ;;
esac

show_cloudways_ui_message() {
    printf 'PHP 8.2 skipped. Apply %s through the Cloudways UI.\n' "$assignment" >&2
}

if [[ $1 == 8.2 && $cloudways_ui_only == 1 ]]; then
    show_cloudways_ui_message
    exit 0
fi
(( EUID == 0 )) || die 'Run this script as root.'

# PHP can emit startup or INI errors even when the command exits successfully.
check_php_output() {
    local output=$1 diagnostics
    diagnostics=$(awk '
        /^PHP:.*syntax error/ ||
        /^(PHP )?(Warning|Fatal error|Parse error):/ ||
        /^PHP:.*(Unable to|Failed to)/ ||
        /^(PHP: )?(Cannot load|Failed loading|Cannot unload)/ { print }
    ' <<< "$output")
    if [[ -n $diagnostics ]]; then
        printf '%s\n' "$diagnostics" >&2
        return 1
    fi
}

php_root=/etc/php
exec 9>"$php_root/.custom-manual.lock"
flock 9

files=() links=() targets=() fpm_versions=() cli_versions=()
skipped_php82=0
skipped_unsupported=0
for directory in "$php_root"/*; do
    version=${directory##*/}
    [[ -d $directory && $version =~ $version_pattern ]] || continue
    [[ $1 == all || $1 == "$version" ]] || continue
    [[ -d $directory/cli/conf.d || -d $directory/fpm/conf.d ]] || continue

    if [[ $version == 8.2 && $cloudways_ui_only == 1 ]]; then
        show_cloudways_ui_message
        skipped_php82=1
        continue
    fi

    if [[ $1 == all && -d $directory/fpm/conf.d ]]; then
        info_sapi=fpm
        info_binary="php-fpm$version"
    else
        info_sapi=cli
        info_binary="php$version"
    fi

    if [[ $key != extension && $key != zend_extension ]]; then
        command -v "$info_binary" >/dev/null || die "$info_binary is missing."
        if ! info=$(PHP_INI_SCAN_DIR="$directory/$info_sapi/conf.d" "$info_binary" \
            -c "$directory/$info_sapi/php.ini" -i 2>&1); then
            check_php_output "$info" || true
            die "Could not inspect PHP $version $info_sapi directives."
        fi
        check_php_output "$info" || die "Fix the existing PHP $version $info_sapi configuration first."
        if ! awk -F ' => ' -v key="$key" '$1 == key && NF >= 3 { found = 1 } END { exit !found }' \
            <<< "$info"; then
            message="Directive '$key' is not registered in PHP $version $info_sapi."
            [[ $1 == all ]] || die "$message"
            printf 'Skipping PHP %s. %s\n' "$version" "$message" >&2
            skipped_unsupported=1
            continue
        fi
    fi

    ini="$php_root/custom-manual-${version/.}.ini"
    if [[ -L $ini || ( -e $ini && ! -f $ini ) ]]; then
        die "Expected a regular file at $ini."
    fi
    files+=("$ini")
    if [[ -d $directory/fpm/conf.d ]]; then
        command -v "php-fpm$version" >/dev/null || die "php-fpm$version is missing."
        fpm_versions+=("$version")
    fi
    if [[ -d $directory/cli/conf.d ]] && command -v "php$version" >/dev/null; then
        cli_versions+=("$version")
    fi


    for sapi in cli fpm; do
        [[ -d $directory/$sapi/conf.d ]] || continue
        link="$directory/$sapi/conf.d/zzzz-custom-manual.ini"
        if [[ -L $link && $(realpath -m -- "$link") == "$ini" ]]; then
            continue
        fi
        [[ ! -e $link && ! -L $link ]] || die "Conflicting file or symlink at $link."
        links+=("$link")
        targets+=("$ini")
    done
done
if (( ${#files[@]} == 0 )); then
    if (( skipped_unsupported )); then
        die "No eligible PHP versions support '$key'. No changes applied."
    fi
    (( skipped_php82 )) && exit 0
    die "No matching PHP CLI or FPM configuration directories for $1."
fi

work=$(mktemp -d "$php_root/.custom-manual.XXXXXXXX")
changed=() created_links=()
validated=0
cleanup() {
    local status=$? item backup
    if (( ! validated )); then
        for item in "${created_links[@]}"; do
            rm -f -- "$item" || printf 'Could not remove %s\n' "$item" >&2
        done
        for item in "${changed[@]}"; do
            backup="$work/${item##*/}"
            if [[ -e $backup ]]; then
                mv -fT -- "$backup" "$item" || {
                    printf 'Could not restore %s. Backup kept in %s\n' "$item" "$work" >&2
                    return 1
                }
            else
                rm -f -- "$item" || printf 'Could not remove %s\n' "$item" >&2
            fi
        done
    fi
    rm -rf -- "$work"
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for ini in "${files[@]}"; do
    source_file=/dev/null
    if [[ -f $ini ]]; then
        source_file=$ini
        cp -a -- "$ini" "$work/${ini##*/}"
        cp -a -- "$ini" "$work/new.ini"
    else
        install -m 0644 /dev/null "$work/new.ini"
    fi

    # Update global assignments and leave any scoped sections intact.
    PHP_CUSTOM_KEY="$key" PHP_CUSTOM_ASSIGNMENT="$assignment" awk '
        /^[[:blank:]]*\[/ && !section {
            if (!written) print ENVIRON["PHP_CUSTOM_ASSIGNMENT"]
            written = section = 1
        }
        !section && /^[[:blank:]]*[A-Za-z0-9_.-]+[[:blank:]]*=/ {
            name = $0
            sub(/^[[:blank:]]*/, "", name)
            sub(/[[:blank:]]*=.*/, "", name)
            if (name == ENVIRON["PHP_CUSTOM_KEY"]) {
                if (!written) print ENVIRON["PHP_CUSTOM_ASSIGNMENT"]
                written = 1
                next
            }
        }
        { print }
        END { if (!written) print ENVIRON["PHP_CUSTOM_ASSIGNMENT"] }
    ' "$source_file" > "$work/new.ini"
    if ! cmp -s -- "$source_file" "$work/new.ini"; then
        changed+=("$ini")
        mv -fT -- "$work/new.ini" "$ini"
    fi
    rm -f -- "$work/new.ini"
done

for index in "${!links[@]}"; do
    ln -sT -- "${targets[index]}" "${links[index]}"
    created_links+=("${links[index]}")
done

for version in "${cli_versions[@]}"; do
    directory="$php_root/$version/cli"
    if ! output=$(PHP_INI_SCAN_DIR="$directory/conf.d" "php$version" \
        -c "$directory/php.ini" -v 2>&1) || ! check_php_output "$output"; then
        die "PHP $version CLI configuration test failed. Rolling back file changes."
    fi
done

for version in "${fpm_versions[@]}"; do
    directory="$php_root/$version/fpm"
    if ! output=$(PHP_INI_SCAN_DIR="$directory/conf.d" "php-fpm$version" -t \
        -c "$directory/php.ini" -y "$directory/php-fpm.conf" 2>&1); then
        printf '%s\n' "$output" >&2
        die "PHP-FPM $version configuration test failed. Rolling back file changes."
    fi
    check_php_output "$output" ||
        die "PHP-FPM $version reported a configuration error. Rolling back file changes."
    printf '%s\n' "$output"
done

validated=1
status=0
for version in "${fpm_versions[@]}"; do
    service="php$version-fpm.service"
    if ! unit_state=$(systemctl show --property=UnitFileState --value "$service"); then
        status=1
        continue
    fi
    case "$unit_state" in
        masked|masked-runtime)
            printf 'Skipping restart of %s because it is masked.\n' "$service"
            ;;
        *)
            systemctl restart "$service" || status=1
            ;;
    esac
done
exit "$status"
