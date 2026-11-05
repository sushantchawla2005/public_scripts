#!/usr/bin/env bash
# Debian/Cloudways Linux x86-64. Bash + standard Linux utilities; no Python.
# Updates existing loader references only. Never creates/deletes/enables an INI.
set -Eeuo pipefail
export LC_ALL=C

log() { printf '%s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Run: sudo bash $0"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Requires Linux x86-64.'
for cmd in curl unzip awk sed find sort readlink mktemp cp mv cmp flock systemctl install cat date rm mkdir; do
    command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done
exec 9>/run/lock/update-ioncube-all.lock
flock -n 9 || die 'Another ionCube updater is running.'
work=$(mktemp -d /tmp/update-ioncube.XXXXXXXX)
backup="/var/backups/ioncube/$(date -u +%Y%m%dT%H%M%S)-$$"
install -d -m 0700 "$backup"
declare -a changed=() restart_attempted=() summaries=() planned=() services=()
declare -A saved=() existed=() config_new=() loader_new=() expected_cli=()
transaction=0
success=0
failures=0

# Read active and commented loader directives; output state, path and basename.
# Also recognizes comments left by the previous updater.
refs() {
    awk '
    /^[ \t]*(;.*)?(zend_extension|extension)[ \t]*=/ {
        original=$0; state=(original ~ /^[ \t]*;/ ? "DISABLED" : "ENABLED")
        sub(/^.*(zend_extension|extension)[ \t]*=[ \t]*/, "", $0)
        sub(/^["\047]/, "", $0)
        split($0, parts, /[ \t;"\047\r]/); path=parts[1]
        n=split(path, bits, "/"); name=bits[n]
        if (name ~ /^ioncube_loader_lin_[0-9]+\.[0-9]+(_ts)?\.so$/)
            printf "%s\t%s\t%s\n", state, path, name
    }' "$1"
}

normalize() {
    # Substitute only the loader path token. Preserve quotes, comments and CRLF.
    sed -E "s@^([ \t]*(;.*)?(zend_extension|extension)[ \t]*=[ \t]*[\"']?)[^; \t\"']*(ioncube_loader_lin_[0-9]+\\.[0-9]+(_ts)?\\.so)([\"']?)([ \t;].*|\r?)\$@\\1/usr/local/ioncube/\\4\\6\\7@" "$1"
}

remember() {
    local path=$1
    [[ ${saved[$path]+yes} ]] && return 0
    saved["$path"]=1
    if [[ -e $path ]]; then
        existed["$path"]=1
        mkdir -p "$backup$(dirname "$path")"
        cp -a -- "$path" "$backup$path"
    else
        existed["$path"]=0
    fi
    changed+=("$path")
}

put_loader() {
    local source=$1 target=$2 stage
    stage=$(mktemp "$(dirname "$target")/.ioncube.XXXXXXXX")
    if ! install -m 0644 "$source" "$stage" || ! mv -f -- "$stage" "$target"; then
        rm -f -- "$stage"
        return 1
    fi
}

cleanup() {
    local status=$? path service i
    trap - EXIT INT TERM
    if (( transaction && ! success )); then
        log 'Update failed; restoring changed files...' >&2
        for ((i=${#changed[@]}-1; i>=0; i--)); do
            path=${changed[i]}
            if [[ ${existed[$path]} == 1 ]]; then
                if [[ $path == *.so ]]; then
                    if ! put_loader "$backup$path" "$path"; then
                        log "RESTORE FAILED: $path" >&2
                    fi
                elif ! cp --preserve=mode,ownership,timestamps -- "$backup$path" "$path"; then
                    log "RESTORE FAILED: $path" >&2
                fi
            else
                rm -f -- "$path" || log "RESTORE FAILED: $path" >&2
            fi
        done
        for service in "${restart_attempted[@]}"; do
            systemctl restart "$service" || log "RECOVERY RESTART FAILED: $service" >&2
        done
    fi
    rm -rf -- "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

probe() {
    local php=$1 loader=$2 output
    [[ -f $loader ]] || { printf 'missing loader file'; return 0; }
    if ! output=$("$php" -n -d "zend_extension=$loader" -r \
        'if (!function_exists("ioncube_loader_version")) exit(1); echo "IONCUBE_VERSION=",ioncube_loader_version();' 2>&1); then
        log "$output" >&2; return 1
    fi
    [[ $output =~ IONCUBE_VERSION=([0-9][0-9A-Za-z._-]*) ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# Plan each version entirely before committing any changes.
plan_version() {
    local v=$1 root="/etc/php/$1" php="/usr/bin/php$1" sapi exe info scan loaded
    local path real state oldpath name loader_v old new candidate service enabled count
    local -a files=() live=() state_notes=() old_notes=() local_services=()
    local -A seen=() names=() edits=() candidates=() new_versions=()
    local cli_enabled=0
    log "Checking PHP $v..."
    find -L "$root" -type f -name '*.ini' -print0 > "$work/files-$v" || return 1
    while IFS= read -r -d '' path; do
        real=$(readlink -f -- "$path") || return 1
        if [[ ! ${seen[$real]+yes} ]]; then files+=("$real"); seen["$real"]=1; fi
    done < "$work/files-$v"
    for path in "${files[@]}"; do
        refs "$path" > "$work/refs" || return 1
        while IFS=$'\t' read -r state oldpath name; do
            [[ -n $name ]] || continue
            loader_v=${name#ioncube_loader_lin_}; loader_v=${loader_v%.so}; loader_v=${loader_v%_ts}
            [[ $loader_v == "$v" ]] || { log "  Mismatched loader in $path; review manually."; return 1; }
            names["$name"]=1
        done < "$work/refs"
    done
    if (( ${#names[@]} == 0 )); then
        summaries+=("PHP $v: DISABLED — no existing loader directive; unchanged")
        return 0
    fi
    for sapi in cli fpm; do
        [[ -d $root/$sapi ]] || continue
        exe=$php
        [[ $sapi != fpm ]] || exe="/usr/sbin/php-fpm$v"
        [[ -x $exe ]] || { log "  Missing binary: $exe"; return 1; }
        info=$("$exe" -i 2>&1) || { log "$info"; return 1; }
        scan=$(awk -F ' => ' '/^Scan this dir for additional .ini files => / {print $2; exit}' <<< "$info")
        [[ $scan == "$root/$sapi/conf.d" ]] || { log "  Nonstandard $sapi scan directory: $scan; review manually."; return 1; }
        live=()
        for path in "$root/$sapi/conf.d/"*.ini; do
            [[ -f $path ]] || continue
            live+=("$(readlink -f -- "$path")")
        done
        loaded=$(awk -F ' => ' '/^Loaded Configuration File => / {print $2; exit}' <<< "$info")
        if [[ -n $loaded && $loaded != '(none)' ]]; then
            [[ -f $loaded ]] || return 1
            real=$(readlink -f -- "$loaded") || return 1
            live+=("$real")
            if [[ ! ${seen[$real]+yes} ]]; then files+=("$real"); seen["$real"]=1; fi
        fi
        count=0
        for path in "${live[@]}"; do
            refs "$path" > "$work/refs" || return 1
            while IFS=$'\t' read -r state oldpath name; do
                [[ $state == ENABLED ]] || continue
                count=$((count+1))
                loader_v=${name#ioncube_loader_lin_}; loader_v=${loader_v%.so}; loader_v=${loader_v%_ts}
                [[ $loader_v == "$v" ]] || return 1
                names["$name"]=1
                if [[ $oldpath != /* ]]; then
                    oldpath="$("$php" -n -r 'echo ini_get("extension_dir");')/$oldpath"
                fi
                old=$(probe "$php" "$oldpath") || { log "  Unable to probe old loader: $oldpath"; return 1; }
                old_notes+=("${sapi^^} $old")
            done < "$work/refs"
        done
        (( count <= 1 )) || { log "  Duplicate active ionCube directives for $sapi; unchanged."; return 1; }
        enabled=DISABLED
        (( count == 0 )) || enabled=ENABLED
        state_notes+=("${sapi^^}=$enabled")
        [[ $sapi != cli || $enabled != ENABLED ]] || cli_enabled=1
        if [[ $sapi == fpm ]] && systemctl is-active --quiet "php$v-fpm.service"; then
            local_services+=("php$v-fpm.service")
        fi
    done
    for name in "${!names[@]}"; do
        candidate="$work/$name"
        if ! unzip -p "$work/loaders.zip" "ioncube/$name" > "$candidate"; then
            summaries+=("PHP $v: SKIPPED — matching loader unavailable: $name; unchanged")
            return 0
        fi
        new=$(probe "$php" "$candidate") || { log "  New loader failed validation: $name"; return 1; }
        candidates["$name"]=$candidate
        new_versions["$new"]=1
    done
    for path in "${files[@]}"; do
        candidate=$(mktemp "$work/ini.XXXXXXXX") || return 1
        normalize "$path" > "$candidate" || return 1
        if ! cmp -s -- "$path" "$candidate"; then
            if [[ ${config_new[$path]+yes} ]] && ! cmp -s -- "${config_new[$path]}" "$candidate"; then
                log "  Conflicting shared INI edits: $path"; return 1
            fi
            edits["$path"]=$candidate
        fi
    done
    # Merge only fully validated plans.
    for name in "${!candidates[@]}"; do loader_new["/usr/local/ioncube/$name"]=${candidates[$name]}; done
    for path in "${!edits[@]}"; do config_new["$path"]=${edits[$path]}; done
    expected_cli["$v"]=$cli_enabled
    planned+=("$v")
    services+=("${local_services[@]}")
    if (( ${#old_notes[@]} )); then
        summaries+=("PHP $v: ${state_notes[*]} | OLD: ${old_notes[*]} -> NEW: ${!new_versions[*]}")
    else
        summaries+=("PHP $v: ${state_notes[*]} | ionCube DISABLED; loader files updated to ${!new_versions[*]}")
    fi
}

log 'Downloading official ionCube archive...'
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 \
    'https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.zip' -o "$work/loaders.zip"
unzip -tq "$work/loaders.zip" >/dev/null
find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V > "$work/versions"
for v in $(cat "$work/versions"); do
    [[ $v =~ ^([0-9]+)\.([0-9]+)$ ]] || continue
    (( BASH_REMATCH[1] > 7 || (BASH_REMATCH[1] == 7 && BASH_REMATCH[2] >= 4) )) || continue
    [[ -x /usr/bin/php$v ]] || continue
    if ! plan_version "$v"; then
        summaries+=("PHP $v: FAILED — validation failed; unchanged")
        failures=$((failures+1))
    fi
done
(( ${#summaries[@]} )) || die 'No installed PHP binaries >= 7.4 found.'

transaction=1
if (( ${#planned[@]} )); then mkdir -p /usr/local/ioncube; fi
for path in "${!loader_new[@]}"; do
    real=$(readlink -m -- "$path")
    remember "$real"
    put_loader "${loader_new[$path]}" "$real"
done
for path in "${!config_new[@]}"; do
    remember "$path"
    # Existing resolved file only: retain symlinks, inode, owner and permissions.
    cat -- "${config_new[$path]}" > "$path"
done
for v in "${planned[@]}"; do
    actual=$("/usr/bin/php$v" -r 'echo function_exists("ioncube_loader_version") ? ioncube_loader_version() : "DISABLED";' 2>&1)
    if [[ ${expected_cli[$v]} == 0 ]]; then
        [[ $actual == DISABLED ]] || die "PHP $v unexpectedly enabled ionCube: $actual"
    else
        suffix=$("/usr/bin/php$v" -n -r 'echo PHP_ZTS ? "_ts" : "";')
        expected=$(probe "/usr/bin/php$v" "/usr/local/ioncube/ioncube_loader_lin_${v}${suffix}.so")
        [[ $actual == "$expected" ]] || die "PHP $v loader version verification failed: $actual"
    fi
    [[ ! -d /etc/php/$v/fpm ]] || "/usr/sbin/php-fpm$v" -t
done
for service in "${services[@]}"; do
    restart_attempted+=("$service")
    systemctl restart "$service"
    systemctl is-active --quiet "$service"
done
success=1
log ''
log 'RESULTS'
printf '%s\n' "${summaries[@]}"
log "Backups: $backup"
log 'No INI files created or deleted. Comments and enabled states preserved.'
(( failures == 0 ))
