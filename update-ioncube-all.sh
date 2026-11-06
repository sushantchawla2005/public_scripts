#!/usr/bin/env bash
# Author: Sushant Chawla
# Last Updated: 6 Nov' 2026
# Debian/Cloudways Linux x86-64. Bash + standard Linux utilities;
# Default: stage all loaders; update INIs only for enabled versions.
# update-all: stage all loaders and normalize every existing ionCube INI.
# enable-all: update loaders and enable ionCube for installed CLI/FPM SAPIs.
set -Eeuo pipefail
export LC_ALL=C

log() { printf '%s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
usage() {
    log 'Usage: bash update-ioncube-all.sh [update-all|enable-all]'
    log 'No argument: stage all loaders; update INIs only where ionCube is enabled in CLI/FPM.'
    log 'update-all: update loaders for all installed PHP versions; retain enabled states.'
    log 'enable-all: update loaders and enable ionCube for all installed CLI/FPM SAPIs.'
}
(( $# <= 1 )) || { usage; exit 1; }
mode=${1:-default}
case $mode in
    default|update-all|enable-all) ;;
    -h|--help) usage; exit 0;;
    *) usage; die "Unknown mode: $mode";;
esac
[[ $EUID -eq 0 ]] || die "Run: sudo bash $0"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Requires Linux x86-64.'
for cmd in curl unzip awk sed find sort readlink mktemp cp mv cmp flock systemctl install cat date rm mkdir ln grep; do
    command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done
exec 9>/run/lock/update-ioncube-all.lock
flock -n 9 || die 'Another ionCube updater is running.'
work=$(mktemp -d /tmp/update-ioncube.XXXXXXXX)
backup="/var/backups/ioncube/$(date -u +%Y%m%dT%H%M%S)-$$"
declare -a changed=() restart_attempted=() summaries=() planned=() services=()
declare -A saved=() existed=() config_new=() loader_new=() expected_cli=() expected_fpm=() link_new=() remove_link=()
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

remember() {
    local path=$1
    [[ ${saved[$path]+yes} ]] && return 0
    install -d -m 0700 "$backup"
    saved["$path"]=1
    if [[ -e $path || -L $path ]]; then
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
                if [[ $path == *.so && ! -L $backup$path ]]; then
                    put_loader "$backup$path" "$path" || log "RESTORE FAILED: $path" >&2
                else
                    rm -f -- "$path"
                    cp -a -- "$backup$path" "$path" || log "RESTORE FAILED: $path" >&2
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

# Rewrite every existing ionCube directive to this PHP version's correct loader.
# Keep leading semicolons, quotes and trailing comments intact.
normalize_version() {
    sed -E "s@^([ \t]*(;.*)?(zend_extension|extension)[ \t]*=[ \t]*[\"']?)[^; \t\"']*ioncube_loader_lin_[0-9]+\\.[0-9]+(_ts)?\\.so([\"']?)([ \t;].*|\r?)\$@\\1/usr/local/ioncube/$name\\5\\6@" "$1"
}
# enable-all neutralizes alternative active directives before adding one canonical INI.
disable_active() {
    awk '
    /^[ \t]*(zend_extension|extension)[ \t]*=.*ioncube_loader_lin_[0-9]+\.[0-9]+(_ts)?\.so/ {
        print "; disabled by enable-all: " $0; next
    }
    {print}' "$1"
}
canonical_ini() {
    awk -v target="/usr/local/ioncube/$name" '
    {lines[++n]=$0}
    END {
        found=0
        for (i=1; i<=n; i++)
            if (lines[i] ~ /^[ \t]*(zend_extension|extension)[ \t]*=.*ioncube_loader_lin_[0-9]+\.[0-9]+(_ts)?\.so/) found=1
        if (!n) print "; priority=00"
        if (!found) print "zend_extension=" target
        used=0
        for (i=1; i<=n; i++) {
            if (lines[i] ~ /^[ \t]*(zend_extension|extension)[ \t]*=.*ioncube_loader_lin_[0-9]+\.[0-9]+(_ts)?\.so/) {
                if (!used++) print "zend_extension=" target
                else print "; disabled duplicate: " lines[i]
            } else print lines[i]
        }
    }' "$1"
}

# Plan an entire PHP version before merging its changes into the transaction.
plan_version() {
    local v=$1 root="/etc/php/$1" php="/usr/bin/php$1"
    local sapi exe info scan loaded path real state oldpath oldname old candidate new
    local suffix name canonical canonical_real link link_target normalized count enabled
    local cli_enabled=0 fpm_enabled=0 any_enabled=0 changes=0
    local -a files=() live=() state_notes=() old_notes=() sapis=()
    local -A seen=() edits=() links=() removals=()
    log "Checking PHP $v..."
    suffix=$("$php" -n -r 'echo PHP_ZTS ? "_ts" : "";') || return 1
    name="ioncube_loader_lin_$v$suffix.so"
    find -L "$root" -type f -name '*.ini' -print0 > "$work/files-$v" || return 1
    while IFS= read -r -d '' path; do
        real=$(readlink -f -- "$path") || return 1
        if [[ ! ${seen[$real]+yes} ]]; then files+=("$real"); seen["$real"]=1; fi
    done < "$work/files-$v"
    for sapi in cli fpm; do
        [[ -d $root/$sapi ]] || continue
        sapis+=("$sapi")
        exe=$php
        [[ $sapi != fpm ]] || exe="/usr/sbin/php-fpm$v"
        [[ -x $exe ]] || { log "  Missing binary: $exe"; return 1; }
        info=$("$exe" -i 2>&1) || { log "$info"; return 1; }
        scan=$(awk -F ' => ' '/^Scan this dir for additional .ini files => / {print $2; exit}' <<< "$info")
        [[ $scan == "$root/$sapi/conf.d" ]] || { log "  Nonstandard $sapi scan directory: $scan; review manually."; return 1; }
        [[ $info != *'Thread Safety => enabled'* || $suffix == _ts ]] || { log '  CLI/FPM thread-safety mismatch; review manually.'; return 1; }
        [[ $info != *'Thread Safety => disabled'* || $suffix != _ts ]] || { log '  CLI/FPM thread-safety mismatch; review manually.'; return 1; }
        live=()
        for path in "$scan/"*.ini; do
            [[ -f $path ]] || continue
            real=$(readlink -f -- "$path") || return 1
            live+=("$real")
        done
        loaded=$(awk -F ' => ' '/^Loaded Configuration File => / {print $2; exit}' <<< "$info")
        if [[ -n $loaded && $loaded != '(none)' ]]; then
            [[ -f $loaded ]] || return 1
            live+=("$(readlink -f -- "$loaded")")
        fi
        count=0
        for path in "${live[@]}"; do
            if [[ ! ${seen[$path]+yes} ]]; then files+=("$path"); seen["$path"]=1; fi
            refs "$path" > "$work/refs" || return 1
            while IFS=$'\t' read -r state oldpath oldname; do
                [[ $state == ENABLED ]] || continue
                count=$((count+1))
                if [[ $oldpath != /* ]]; then
                    oldpath="$("$php" -n -r 'echo ini_get("extension_dir");')/$oldpath"
                fi
                old=$(probe "$php" "$oldpath") || old='unavailable'
                old_notes+=("${sapi^^} $old")
            done < "$work/refs"
        done
        if (( count > 1 )) && [[ $mode != enable-all ]]; then
            log "  Duplicate active ionCube directives for $sapi; use enable-all or review manually."
            return 1
        fi
        enabled=0
        (( count == 0 )) || enabled=1
        (( enabled == 0 )) || any_enabled=1
        [[ $sapi != cli ]] || cli_enabled=$enabled
        [[ $sapi != fpm ]] || fpm_enabled=$enabled
        if [[ $mode == enable-all ]]; then enabled=1; fi
        if (( enabled )); then state_notes+=("${sapi^^}=ENABLED"); else state_notes+=("${sapi^^}=DISABLED"); fi
    done
    candidate="$work/$name"
    if ! unzip -p "$work/loaders.zip" "ioncube/$name" > "$candidate"; then
        log "  Matching loader unavailable: $name; unchanged."
        return 1
    fi
    new=$(probe "$php" "$candidate") || { log "  New loader failed validation: $name"; return 1; }
    [[ $new != 'missing loader file' ]] || return 1
    if [[ $mode == default ]] && (( ! any_enabled )); then
        if ! cmp -s -- "$candidate" "/usr/local/ioncube/$name"; then
            loader_new["/usr/local/ioncube/$name"]=$candidate
            summaries+=("PHP $v: DISABLED | Latest loader staged: $new; INIs and enabled states unchanged")
        else
            summaries+=("PHP $v: DISABLED | UNCHANGED — loader $new already staged; INIs unchanged")
        fi
        return 0
    fi
    canonical="$root/mods-available/ioncube.ini"
    canonical_real=$(readlink -m -- "$canonical") || return 1
    # Shared files across PHP versions cannot safely reference one version's SO.
    for path in "${files[@]}"; do
        refs "$path" > "$work/refs" || return 1
        [[ -s $work/refs ]] || continue
        [[ $path == "$root/"* ]] || { log "  Shared ionCube INI outside $root: $path; review manually."; return 1; }
        normalized=$(mktemp "$work/ini.XXXXXXXX") || return 1
        normalize_version "$path" > "$normalized" || return 1
        if [[ $mode == enable-all && $path != "$canonical_real" ]]; then
            real=$(mktemp "$work/ini.XXXXXXXX") || return 1
            disable_active "$normalized" > "$real" || return 1
            normalized=$real
        fi
        if ! cmp -s -- "$path" "$normalized"; then edits["$path"]=$normalized; fi
    done
    if [[ $mode == enable-all ]]; then
        [[ $canonical_real == "$root/"* ]] || { log "  Canonical INI points outside $root; review manually."; return 1; }
        normalized=$(mktemp "$work/canonical.XXXXXXXX") || return 1
        if [[ -e $canonical_real ]]; then
            canonical_ini "${edits[$canonical_real]:-$canonical_real}" > "$normalized" || return 1
        else
            canonical_ini /dev/null > "$normalized" || return 1
        fi
        if ! cmp -s -- "$canonical_real" "$normalized"; then edits["$canonical_real"]=$normalized; fi
        for sapi in "${sapis[@]}"; do
            link="$root/$sapi/conf.d/00-ioncube.ini"
            # Preserve a pre-existing regular/custom 00-ioncube.ini. Its loader
            # directive was neutralized above; use an earlier canonical link.
            if [[ -e $link || -L $link ]]; then
                if [[ ! -L $link || $(readlink -m -- "$link") != "$canonical_real" ]]; then
                    link="$root/$sapi/conf.d/00-00-ioncube.ini"
                fi
            fi
            if [[ -e $link || -L $link ]]; then
                [[ -L $link && $(readlink -m -- "$link") == "$canonical_real" ]] || {
                    log "  Cannot replace existing noncanonical $link; review manually."; return 1;
                }
            else
                links["$link"]=$canonical
            fi
            # Remove only redundant symlinks to the same canonical INI.
            for path in "$root/$sapi/conf.d/"*.ini; do
                [[ -L $path && $path != "$link" ]] || continue
                if [[ $(readlink -m -- "$path") == "$canonical_real" ]]; then removals["$path"]=1; fi
            done
        done
    fi
    if ! cmp -s -- "$candidate" "/usr/local/ioncube/$name"; then changes=1; fi
    changes=$((changes + ${#edits[@]} + ${#links[@]} + ${#removals[@]}))
    if (( ! changes )); then
        summaries+=("PHP $v: ${state_notes[*]} | UNCHANGED — loader $new already installed; no backup or restart")
        return 0
    fi
    for path in "${!edits[@]}"; do
        if [[ ${config_new[$path]+yes} ]] && ! cmp -s -- "${config_new[$path]}" "${edits[$path]}"; then
            log "  Conflicting shared INI edits: $path"; return 1
        fi
    done
    if ! cmp -s -- "$candidate" "/usr/local/ioncube/$name"; then loader_new["/usr/local/ioncube/$name"]=$candidate; fi
    for path in "${!edits[@]}"; do config_new["$path"]=${edits[$path]}; done
    for path in "${!links[@]}"; do link_new["$path"]=${links[$path]}; done
    for path in "${!removals[@]}"; do remove_link["$path"]=1; done
    if [[ $mode == enable-all ]]; then
        [[ ! -d $root/cli ]] || cli_enabled=1
        [[ ! -d $root/fpm ]] || fpm_enabled=1
    fi
    expected_cli["$v"]=$cli_enabled
    expected_fpm["$v"]=$fpm_enabled
    planned+=("$v")
    if (( fpm_enabled )) && systemctl is-active --quiet "php$v-fpm.service"; then services+=("php$v-fpm.service"); fi
    summaries+=("PHP $v: ${state_notes[*]} | OLD: ${old_notes[*]:-DISABLED} -> NEW: $new")
}

log "Mode: $mode"
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
if (( ${#loader_new[@]} )); then mkdir -p /usr/local/ioncube; fi
for path in "${!loader_new[@]}"; do
    real=$(readlink -m -- "$path")
    remember "$real"
    put_loader "${loader_new[$path]}" "$real"
done
for path in "${!config_new[@]}"; do
    mkdir -p "$(dirname "$path")"
    remember "$path"
    if [[ -e $path ]]; then
        # Retain existing resolved INI inode, owner and permissions.
        cat -- "${config_new[$path]}" > "$path"
    else
        install -m 0644 -- "${config_new[$path]}" "$path"
    fi
done
for path in "${!remove_link[@]}"; do
    remember "$path"
    rm -f -- "$path"
done
for path in "${!link_new[@]}"; do
    mkdir -p "$(dirname "$path")"
    remember "$path"
    ln -s -- "${link_new[$path]}" "$path"
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
    if [[ -d /etc/php/$v/fpm ]]; then
        "/usr/sbin/php-fpm$v" -t
        info=$("/usr/sbin/php-fpm$v" -i 2>&1)
        if [[ ${expected_fpm[$v]} == 1 ]]; then
            grep -Eq 'ionCube PHP Loader|ionCube Loader version' <<< "$info" || die "PHP $v FPM ionCube did not load."
        else
            if grep -Eq 'ionCube PHP Loader|ionCube Loader version' <<< "$info"; then die "PHP $v FPM unexpectedly enabled ionCube."; fi
        fi
        if grep -Eiq 'failed loading|cannot load|already loaded|must appear as' <<< "$info"; then
            die "PHP $v FPM reported a loader error: $info"
        fi
    fi
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
if (( ${#changed[@]} )); then
    log "Backups: $backup"
else
    log 'No changes required; no backups created or services restarted.'
fi
if [[ $mode == enable-all ]]; then
    log 'ionCube enabled through mods-available/ioncube.ini and CLI/FPM early-loading symlinks.'
else
    log 'Existing enabled states preserved. No INI files or enablement symlinks created.'
fi
(( failures == 0 ))
