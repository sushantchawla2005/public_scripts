#!/usr/bin/env bash
# Run on the Cloudways server as root. Requires curl, jq, mysql and Shorewall.
# Usage: bash cloudways-snapshooter-setup.sh [SNAPSHOOTER_TOKEN CLOUDWAYS_TOKEN]
# Environment: SNAPSHOOTER_TOKEN, CW_TOKEN (or CLOUDWAYS_TOKEN),
# MYSQL_BACKUP_PASSWORD, SSH_KEY_ID, STORAGE_ID, STORAGE_BUCKET, SOURCE_SCHEDULE_ID.
# Missing values are prompted via /dev/tty, including when piped into bash.
# Optional: MYSQL_DEFAULTS_FILE, RECIPE_ID, DRY_RUN=1.
# DRY_RUN performs API reads only, without server/account mutations.
set +x
set -Eeuo pipefail
umask 077
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*" >&2; }
STEP=0
step() { STEP=$((STEP + 1)); log "[$STEP] $*"; sleep 1; }
[[ $# == 0 || $# == 2 ]] || die 'Usage: bash cloudways-snapshooter-setup.sh [SNAPSHOOTER_TOKEN CLOUDWAYS_TOKEN]'
if [[ $# == 2 ]]; then
  SNAPSHOOTER_TOKEN=$1
  CW_TOKEN=$2
else
  SNAPSHOOTER_TOKEN=${SNAPSHOOTER_TOKEN:-}
  CW_TOKEN=${CW_TOKEN:-${CLOUDWAYS_TOKEN:-}}
fi
[[ $EUID == 0 ]] || die 'Run as root on the target Cloudways server.'
# Never read prompts from stdin: it may contain the rest of this script.
get_setting() {
  local name=$1 label=$2 hidden=${3:-0}
  [[ -z ${!name:-} ]] || return 0
  if [[ $hidden == 1 ]]; then
    if ! IFS= read -r -s -p "$label: " "$name" < /dev/tty; then
      die "Set $name in the environment when no interactive terminal is available."
    fi
    printf '\n' >&2
  else
    if ! IFS= read -r -p "$label: " "$name" < /dev/tty; then
      die "Set $name in the environment when no interactive terminal is available."
    fi
  fi
  [[ -n ${!name:-} ]] || die "$name is empty."
}
get_setting SNAPSHOOTER_TOKEN 'SnapShooter API token (hidden)' 1
get_setting CW_TOKEN 'Cloudways access token (hidden)' 1
get_setting MYSQL_BACKUP_PASSWORD 'MySQL backup password (hidden)' 1
get_setting SSH_KEY_ID 'SnapShooter SSH key ID'
get_setting STORAGE_ID 'SnapShooter storage ID'
get_setting STORAGE_BUCKET 'SnapShooter storage bucket'
get_setting SOURCE_SCHEDULE_ID 'Source schedule ID'
for setting in SSH_KEY_ID STORAGE_ID SOURCE_SCHEDULE_ID; do
  [[ ${!setting} =~ ^[1-9][0-9]*$ ]] || die "$setting must be a positive integer without leading zeros."
done
[[ $STORAGE_BUCKET != *$'\n'* && $STORAGE_BUCKET != *$'\r'* ]] || die 'Storage bucket contains a newline.'
step 'Checking required commands and setup lock...'
for cmd in curl jq mysql mysqldump gzip flock getent awk shorewall ssh-keygen; do
  command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
done
exec 9>/run/lock/cloudways-snapshooter.lock
flock -n 9 || die 'Another setup is running.'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'log "Stopped at line $LINENO. Earlier changes may remain; resolve the error and rerun. No automatic rollback of API resources."' ERR
DRY_RUN=${DRY_RUN:-0}
MYSQL_USER=snapshooter-backup
MACRO=/etc/shorewall/macro.ALLOW_SSH
[[ -n $MYSQL_BACKUP_PASSWORD ]] || die 'MYSQL_BACKUP_PASSWORD is empty.'
# Password restricted to these characters so SQL and MySQL option-file escaping
# are unambiguous.
[[ $MYSQL_BACKUP_PASSWORD =~ ^[a-zA-Z0-9._@%+=:-]+$ ]] || die 'Use an alphanumeric password or ._@%+=:- characters.'
[[ $CW_TOKEN != *$'\n'* && $CW_TOKEN != *$'\r'* && $SNAPSHOOTER_TOKEN != *$'\n'* && $SNAPSHOOTER_TOKEN != *$'\r'* ]] || die 'Token contains a newline.'
printf 'Authorization: Bearer %s\n' "$CW_TOKEN" >"$TMP/cw.header"
printf 'Authorization: Bearer %s\n' "$SNAPSHOOTER_TOKEN" >"$TMP/ss.header"
SS=https://api.snapshooter.com/v1

# No automatic POST retries: an ambiguous timeout must be reconciled by listing
# resources on the next run. Error bodies are kept private, never printed.
api() {
  local header=$1 method=$2 url=$3 output=$4 payload=${5:-} code curl_status
  [[ $url != *[[:space:]]* ]] || die 'API URL contains whitespace; check the pagination response.'
  local args=(--silent --show-error --connect-timeout 15 --max-time 180
    --header "@$header" --header 'Accept: application/json' --request "$method"
    --output "$output" --write-out '%{http_code}')
  [[ -z $payload ]] || args+=(--header 'Content-Type: application/json' --data-binary "@$payload")
  # -q must be first: ignore system/user curl configuration that could add URLs.
  if code=$(curl -q "${args[@]}" --url "$url"); then
    :
  else
    curl_status=$?
    die "$method ${url%%\?*} failed (curl exit $curl_status); rerun to reconcile resources."
  fi
  if [[ $code != 2?? ]]; then
    log "$method ${url%%\?*} returned HTTP $code."
    # Print field names only; never expose response or request values.
    if [[ $code == 422 ]]; then
      log 'Rejected fields:'
      jq -r '
        (.errors // {}) | keys[]
        | select(test("^[A-Za-z0-9_.-]+$"))
        | "    - " + .
      ' "$output" >&2 2>/dev/null || true
    fi
    die 'API request failed. Response values omitted to protect credentials.'
  fi
  jq -e . "$output" >/dev/null || die 'API did not return JSON.'
}
# Follow Laravel links.next, validating the origin before forwarding credentials.
ss_list() {
  local path=$1 out=$2 url="$SS/$1" next count=0
  echo '[]' >"$out"
  while [[ -n $url ]]; do
    ((count+=1)); ((count <= 10000)) || die 'Pagination loop detected.'
    [[ $url == "$SS/"* ]] || die 'Unexpected pagination URL.'
    api "$TMP/ss.header" GET "$url" "$TMP/page.json"
    jq -e '.data | type == "array"' "$TMP/page.json" >/dev/null || die 'Expected a data array.'
    jq -s '.[0] + .[1].data' "$out" "$TMP/page.json" >"$TMP/merged.json"
    mv "$TMP/merged.json" "$out"
    next=$(jq -r '.links.next // empty | if type == "string" then . else error("Non-string pagination URL") end' "$TMP/page.json")
    if [[ $next == /* ]]; then next="https://api.snapshooter.com$next"; fi
    url=$next
  done
}

step 'Detecting the public server IP...'
SERVER_IP=$(curl -q -4fsS --connect-timeout 10 --max-time 30 --url https://ifconfig.me/ip)
[[ $SERVER_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'Invalid public IPv4 response.'
log "    Public IP: $SERVER_IP"
step 'Looking up the server name in Cloudways...'
api "$TMP/cw.header" GET https://api.cloudways.com/api/v2/server "$TMP/cw.json"
jq --arg ip "$SERVER_IP" '[.servers[] | select(.public_ip == $ip)]' "$TMP/cw.json" >"$TMP/match.json"
[[ $(jq length "$TMP/match.json") == 1 ]] || die "Expected exactly one Cloudways server matching $SERVER_IP."
SERVER_NAME=$(jq -er '.[0].label | select(type == "string" and length > 0)' "$TMP/match.json")
log "    Server name: $SERVER_NAME"
step 'Detecting the master SSH user and checking local MySQL access...'
# Read directly: an early awk exit in a getent pipeline can trigger SIGPIPE
# under pipefail, even when the master user was found successfully.
MASTER_USER=$(awk -F: '$6 == "/home/master" {print $1; exit}' /etc/passwd)
[[ -n $MASTER_USER ]] || die 'No master account with home /home/master found.'
MASTER_GROUP=$(id -gn "$MASTER_USER")
JOB_NAME="$SERVER_NAME-DBOnlyBackups"
[[ -f $MACRO && ! -L $MACRO ]] || die "Expected a regular Shorewall macro: $MACRO"
mysql_admin=(mysql)
[[ -z ${MYSQL_DEFAULTS_FILE:-} ]] || mysql_admin+=(--defaults-extra-file="$MYSQL_DEFAULTS_FILE")
"${mysql_admin[@]}" -NBe 'SELECT 1' >/dev/null || die 'Root MySQL login failed; set MYSQL_DEFAULTS_FILE.'
log "    Master user: $MASTER_USER | Local MySQL access: OK"

step "Checking SnapShooter SSH key $SSH_KEY_ID..."
ss_list 'ssh-keys' "$TMP/keys.json"
jq --arg id "$SSH_KEY_ID" '[.[] | select((.id|tostring)==$id)]' "$TMP/keys.json" >"$TMP/key.json"
[[ $(jq length "$TMP/key.json") == 1 ]] || die "SSH key $SSH_KEY_ID was not found uniquely in this team."
# Fetch the actual public key for the selected ID instead of embedding a potentially
# stale copy. This is the key used for the server registration below.
PUBLIC_KEY=$(jq -er '.[0].public_key | select(startswith("ssh-rsa "))' "$TMP/key.json")
[[ $PUBLIC_KEY != *$'\n'* ]] || die 'Unexpected multiline SSH key.'
printf '%s\n' "$PUBLIC_KEY" >"$TMP/key.pub"
ssh-keygen -lf "$TMP/key.pub" >/dev/null

step 'Checking the SSH public key in /home/master/.openssh/authorized_keys...'
KEY_DIR=/home/master/.openssh
AUTH_KEYS=$KEY_DIR/authorized_keys
KEY_BLOB=$(awk '{print $2}' "$TMP/key.pub")
[[ ! -L $AUTH_KEYS ]] || die 'Refusing to inspect a symlinked authorized_keys.'
if [[ -f $AUTH_KEYS ]] && awk -v blob="$KEY_BLOB" '{for(i=1;i<=NF;i++) if($i==blob) found=1} END{exit !found}' "$AUTH_KEYS"; then
  log '    SSH key already present.'
else
  log '    SSH key is missing; it will be added if setup proceeds.'
fi

step 'Checking the MySQL All Databases backup recipe...'
ss_list recipes "$TMP/recipes.json"
jq '[.[] | select(.slug == "mysql-all")]' "$TMP/recipes.json" >"$TMP/recipe.json"
[[ $(jq length "$TMP/recipe.json") == 1 ]] || die 'mysql-all recipe not found uniquely.'
RECIPE_ID=${RECIPE_ID:-$(jq -r '.[0].id // empty' "$TMP/recipe.json")}
[[ $RECIPE_ID =~ ^[0-9]+$ ]] || die 'Recipes response has no numeric mysql-all id. Set RECIPE_ID to the verified numeric ID; the public docs omit it.'
# Select the recipe-provided image before making any local or API changes.
SNAPSHOOTER_IMAGE=$(jq -er '
  [.[0].config.snapshooter_image.default, .[0].default_image]
  | map(select(type == "string" and length > 0))
  | .[0] // empty
' "$TMP/recipe.json") || die 'No default SnapShooter image found in the mysql-all recipe.'
log "    SnapShooter image: $SNAPSHOOTER_IMAGE"
step "Checking backup storage: $STORAGE_BUCKET (ID $STORAGE_ID)..."
ss_list storage "$TMP/storage.json"
jq -e --arg id "$STORAGE_ID" --arg bucket "$STORAGE_BUCKET" 'any(.[]; (.id|tostring)==$id and .bucket==$bucket)' "$TMP/storage.json" >/dev/null || die 'Storage ID/bucket mismatch.'
step "Reading backup jobs and source schedule $SOURCE_SCHEDULE_ID..."
ss_list 'jobs?page_size=100' "$TMP/jobs.json"
jq --arg id "$SOURCE_SCHEDULE_ID" '[.[] | (.schedule // .schedules // [])[] | select((.id|tostring)==$id)]' "$TMP/jobs.json" >"$TMP/source.json"
[[ $(jq length "$TMP/source.json") == 1 ]] || die "Schedule $SOURCE_SCHEDULE_ID not found uniquely in jobs. Set SOURCE_SCHEDULE_ID to a valid source."
# Copy settings only; never reuse another job's schedule/resource ID.
jq -e '.[0] | if .frequency_mode == "cron" then
  {order:0, timezone:.timezone, frequency:"cron", cron:.cron, retention:.retention.hourly}
  elif .frequency_mode == "hour" or .frequency_mode == "minute" then
  {order:0, timezone:.timezone,
   frequency:((if .frequency_mode=="hour" then "h" else "m" end)+(.frequency|tostring)),
   run_offset:(.run_offset//0), retention_hourly:.retention.hourly,
   retention_daily:.retention.daily, retention_weekly:.retention.weekly, retention_monthly:.retention.monthly}
  else error("Unsupported source schedule mode") end
  | if any(.[]; . == null) then error("Incomplete source schedule") else . end' "$TMP/source.json" >"$TMP/schedule.json"
step 'Checking whether this server already exists in SnapShooter...'
ss_list "servers?host=$SERVER_IP&page_size=100" "$TMP/servers.json"
jq --arg ip "$SERVER_IP" '[.[] | select(.host==$ip)]' "$TMP/servers.json" >"$TMP/existing-server.json"
[[ $(jq length "$TMP/existing-server.json") -le 1 ]] || die 'Multiple SnapShooter servers use this IP.'
if [[ $(jq length "$TMP/existing-server.json") == 1 ]]; then
  jq -e --arg user "$MASTER_USER" --arg key "$SSH_KEY_ID" '.[0] | .user==$user and (.port|tostring)=="22" and (.key.id|tostring)==$key' "$TMP/existing-server.json" >/dev/null || die 'Existing server user/port/key differs; reconcile it first.'
  log "    Server already exists: $SERVER_NAME (ID $(jq -r '.[0].id' "$TMP/existing-server.json")). SSH settings match."
else
  log "    Server is not registered yet; it will be added during setup."
fi
step 'Checking for an existing DBOnlyBackup or DBOnlyBackups job...'
jq --arg singular "$SERVER_NAME-DBOnlyBackup" --arg plural "$JOB_NAME" \
  '[.[] | select(.name==$singular or .name==$plural)]' "$TMP/jobs.json" >"$TMP/existing-job.json"
if [[ $(jq length "$TMP/existing-job.json") -gt 0 ]]; then
  jq -e --arg ip "$SERVER_IP" 'all(.[]; .recipe=="mysql-all" and ((.compute.host // .compute.server.host)==$ip))' "$TMP/existing-job.json" >/dev/null || die 'Existing job name belongs to different compute/recipe.'
  log "Job already exists: $(jq -r 'map(.name + " (" + (.id|tostring) + ")") | join(", ")' "$TMP/existing-job.json"). No changes made."
  exit 0
fi
log '    No matching backup job found.'
log "Server: $SERVER_NAME | IP: $SERVER_IP | SSH user: $MASTER_USER"
log "Job: $JOB_NAME | recipe ID: $RECIPE_ID | storage: $STORAGE_ID"
log "Schedule copied from $SOURCE_SCHEDULE_ID: $(jq -c . "$TMP/schedule.json")"
if [[ $DRY_RUN == 1 ]]; then log 'DRY_RUN complete: all preflight checks passed. No changes made.'; exit 0; fi

step 'Installing the SnapShooter public key for the master user...'
# Append without replacing other keys. Preserve existing permissions/ownership;
# establish correct permissions for newly created directory/file only.
if [[ ! -d $KEY_DIR ]]; then install -d -m 700 -o "$MASTER_USER" -g "$MASTER_GROUP" "$KEY_DIR"; fi
[[ ! -L $AUTH_KEYS ]] || die 'Refusing to append to a symlinked authorized_keys.'
if [[ ! -e $AUTH_KEYS ]]; then install -m 600 -o "$MASTER_USER" -g "$MASTER_GROUP" /dev/null "$AUTH_KEYS"; fi
KEY_BLOB=$(awk '{print $2}' "$TMP/key.pub")
if ! awk -v blob="$KEY_BLOB" '{for(i=1;i<=NF;i++) if($i==blob) found=1} END{exit !found}' "$AUTH_KEYS"; then
  cp -a "$AUTH_KEYS" "$AUTH_KEYS.before-snapshooter.$(date +%s)"
  printf '\n## snapshooter.com Backup Key\n%s\n' "$PUBLIC_KEY" >>"$AUTH_KEYS"
  log '    SSH key added.'
else
  log '    SSH key already present.'
fi

step 'Preparing the MySQL backup user and verifying its login...'
# MySQL 8-compatible syntax; never reset a pre-existing user's password.
"${mysql_admin[@]}" <<SQL
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_BACKUP_PASSWORD';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, RELOAD, REPLICATION CLIENT ON *.* TO '$MYSQL_USER'@'%';
SQL
printf '[client]\nuser=%s\npassword=%s\nhost=127.0.0.1\nport=3306\nprotocol=tcp\n' "$MYSQL_USER" "$MYSQL_BACKUP_PASSWORD" >"$TMP/mysql.cnf"
mysql --defaults-file="$TMP/mysql.cnf" -NBe 'SELECT 1' >/dev/null || die 'Backup MySQL login failed; an existing account may have a different password.'
log '    Backup user privileges applied; login verified.'

step 'Checking SnapShooter firewall allowlist entries...'
BACKUP_MACRO="$MACRO.before-snapshooter.$(date +%s)"
cp -a "$MACRO" "$BACKUP_MACRO"
CHANGED=0
for ip in 46.51.158.3 54.228.167.152 54.72.152.22; do
  if ! awk -v net="net:$ip" '$1=="PARAM" && $2==net {found=1} END{exit !found}' "$MACRO"; then
    printf '\nPARAM     net:%s\n' "$ip" >>"$MACRO"
    CHANGED=1
  fi
done
if [[ $CHANGED == 1 ]]; then
  log '    Entries added. Validating and reloading Shorewall...'
  if ! shorewall check; then cp -a "$BACKUP_MACRO" "$MACRO"; die 'Shorewall validation failed; macro restored.'; fi
  if ! shorewall reload; then
    cp -a "$BACKUP_MACRO" "$MACRO"
    shorewall reload || log 'Shorewall rollback reload failed; inspect firewall immediately.'
    die 'Shorewall reload failed; original macro restored.'
  fi
  log '    Firewall validated and reloaded.'
else
  log '    All allowlist entries already present; no reload needed.'
fi

step 'Registering or reusing the SnapShooter server...'
if [[ $(jq length "$TMP/existing-server.json") == 1 ]]; then
  SERVER_ID=$(jq -r '.[0].id' "$TMP/existing-server.json")
  log "Reusing SnapShooter server $SERVER_ID"
else
  jq -n --arg name "$SERVER_NAME" --arg host "$SERVER_IP" --arg user "$MASTER_USER" --argjson key "$SSH_KEY_ID" \
    '{name:$name,ssh_host:$host,ssh_port:"22",ssh_user:$user,ssh_key:$key}' >"$TMP/server-payload.json"
  api "$TMP/ss.header" POST "$SS/servers" "$TMP/server-response.json" "$TMP/server-payload.json"
  SERVER_ID=$(jq -er '.data.id' "$TMP/server-response.json")
  log "Created SnapShooter server $SERVER_ID"
fi
[[ $SERVER_ID =~ ^[0-9]+$ ]] || die 'Invalid server ID.'
step "Creating backup job: $JOB_NAME..."
# Password loaded from a private file so jq receives no password in argv.
printf '%s' "$MYSQL_BACKUP_PASSWORD" >"$TMP/password"
jq -n --arg name "$JOB_NAME" --argjson recipe "$RECIPE_ID" --argjson server "$SERVER_ID" \
  --arg image "$SNAPSHOOTER_IMAGE" --argjson storage "$STORAGE_ID" --rawfile password "$TMP/password" --slurpfile schedule "$TMP/schedule.json" \
  '{name:$name,recipe_id:$recipe,
    compute:{type:"server",server_id:$server},
    config:{snapshooter_image:$image,
      mysql_username:"snapshooter-backup",mysql_password:$password,
      mysql_host:"127.0.0.1",mysql_port:3306,
      mysql_flags:"--single-transaction --quick --routines --max-allowed-packet=1024M",
      single_file:false,compression_level:2,create_manual_restore:true},
    storage:[{storage_id:$storage,priority:1}],schedules:$schedule}' >"$TMP/job-payload.json"
api "$TMP/ss.header" POST "$SS/jobs" "$TMP/job-response.json" "$TMP/job-payload.json"
JOB_ID=$(jq -er '.data.id' "$TMP/job-response.json")
log "Created backup job: $JOB_ID"
step 'Verifying the new backup job configuration...'
api "$TMP/ss.header" GET "$SS/jobs/$JOB_ID" "$TMP/verify.json"
jq -e --arg name "$JOB_NAME" --arg host "$SERVER_IP" --argjson storage "$STORAGE_ID" \
  '.data | .name==$name and .recipe=="mysql-all" and
   ((.compute.host // .compute.server.host)==$host) and
   any(.storage[]; .id==$storage) and ((.schedule // .schedules)|length>0)' "$TMP/verify.json" >/dev/null || die 'Created job verification failed; inspect the job before rerunning.'
log "Done: $JOB_NAME | server=$SERVER_ID | job=$JOB_ID"
log 'Registration complete. Check the first scheduled backup for a successful dump and upload.'
