#!/bin/bash
# Back up the Mailcow inbox and database to Cloudflare R2.
set -euo pipefail
umask 077

ROOT=/opt/mailcow-backup
MAILCOW=/opt/mailcow-dockerized
VMAIL=/var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data
MYSQL_DATA=/var/lib/docker/volumes/mailcowdockerized_mysql-vol-1/_data
STATE="$ROOT/state"
STAGING="$ROOT/staging"
LOCK="$STATE/backup.lock"

log() {
  printf '%s %s\n' "$(date -Is)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

conf_get() {
  local key="$1" file="$2" line
  line=$(grep -E "^${key}=" "$file" | tail -n 1 || true)
  [[ -n "$line" ]] || die "key ${key} is missing from ${file}"
  printf '%s' "${line#*=}"
}

load_config() {
  [[ -f "$ROOT/backup.env" ]] || die "backup.env is missing"
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/backup.env"
  set +a
  [[ -n "${R2_ACCOUNT_ID:-}" ]] || die "R2_ACCOUNT_ID is empty"
  [[ -n "${S3_ACCESS_KEY_ID:-}" ]] || die "S3_ACCESS_KEY_ID is empty"
  [[ -n "${S3_SECRET_ACCESS_KEY:-}" ]] || die "S3_SECRET_ACCESS_KEY is empty"
  [[ -n "${S3_BUCKET_NAME:-}" ]] || die "S3_BUCKET_NAME is empty"
  unset RESTIC_PASSWORD

  export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION="${S3_REGION:-auto}"
  export RESTIC_REPOSITORY="s3:https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${S3_BUCKET_NAME}"
  export RESTIC_CACHE_DIR="$ROOT/cache"
  export RESTIC_LIMIT_UPLOAD="${RESTIC_LIMIT_UPLOAD:-8192}"

  DBROOT=$(conf_get DBROOT "$MAILCOW/mailcow.conf")
  DBNAME=$(conf_get DBNAME "$MAILCOW/mailcow.conf")
}

restic_run() {
  restic --insecure-no-password -o "s3.region=${AWS_DEFAULT_REGION}" --limit-upload "$RESTIC_LIMIT_UPLOAD" "$@"
}

mysql_query() {
  docker compose --project-directory "$MAILCOW" exec -T \
    -e MYSQL_PWD="$DBROOT" \
    mysql-mailcow \
    mysql --user=root --batch --skip-column-names "$@"
}

binlog_status() {
  local out
  if ! out=$(mysql_query -e "SHOW BINLOG STATUS;" 2>/dev/null); then
    out=$(mysql_query -e "SHOW MASTER STATUS;")
  fi
  [[ -n "$out" ]] || return 1
  awk 'NR == 1 { print $1, $2 }' <<<"$out"
}

binlog_number() {
  local name="${1##*.}"
  echo $((10#$name))
}

require_binlog() {
  local value
  value=$(mysql_query -e "SHOW VARIABLES LIKE 'log_bin';" | awk '{ print $2 }')
  [[ "$value" == "ON" ]] || die "log_bin is off. Run install-on-host.sh to enable the binlog."
}

with_lock() {
  mkdir -p "$STATE" "$STAGING/binlog" "$ROOT/cache"
  exec 9>"$LOCK"
  flock 9
  "$@"
}

mode_check_config() {
  load_config
  log "backup configuration is complete"
}

mode_init() {
  load_config
  if restic_run cat config >/dev/null 2>&1; then
    log "R2 repository already exists"
    return 0
  fi
  log "creating R2 repository"
  restic_run init
}

mode_inbox() {
  load_config
  [[ -d "$VMAIL" ]] || die "inbox volume not found"
  log "backing up inbox"
  restic_run backup \
    --tag inbox \
    --host kantor-pos \
    --one-file-system \
    --exclude 'Maildir/tmp/**' \
    "$VMAIL"
  log "inbox backup finished"
}

mode_db_base() {
  load_config
  require_binlog
  local active position dump="$STAGING/mailcow.sql"
  read -r active position < <(binlog_status) || die "could not read the binlog position"
  log "dumping database ${DBNAME} at ${active}:${position}"
  docker compose --project-directory "$MAILCOW" exec -T \
    -e MYSQL_PWD="$DBROOT" \
    mysql-mailcow \
    mariadb-dump \
      --user=root \
      --single-transaction \
      --routines \
      --triggers \
      --events \
      --master-data=2 \
      "$DBNAME" > "${dump}.tmp"
  [[ -s "${dump}.tmp" ]] || die "database dump is empty"
  grep -q "AUTO_INCREMENT" "${dump}.tmp" || die "dump does not contain AUTO_INCREMENT"
  mv "${dump}.tmp" "$dump"
  log "uploading base dump"
  restic_run backup --tag db-base --host kantor-pos "$dump"
  printf '%s\n' "$active" > "$STATE/watermark"
  log "base dump stored, active binlog ${active}"
}

uploaded_has() {
  local name="$1"
  [[ -f "$STATE/uploaded" ]] || return 1
  grep -Fxq "$name" "$STATE/uploaded"
}

mode_db_incr() {
  load_config
  require_binlog
  [[ -f "$STATE/watermark" ]] || return 10
  local watermark active position wm_n active_n base num present
  watermark=$(<"$STATE/watermark")
  wm_n=$(binlog_number "$watermark")
  mysql_query -e "FLUSH BINARY LOGS;" >/dev/null
  if ! read -r active position < <(mysql_query -e "SHOW BINLOG STATUS;" | awk 'NR == 1 { print $1, $2 }'); then
    read -r active position < <(mysql_query -e "SHOW MASTER STATUS;" | awk 'NR == 1 { print $1, $2 }')
  fi
  [[ -n "$active" ]] || die "FLUSH BINARY LOGS did not return the active file"
  active_n=$(binlog_number "$active")

  declare -A present=()
  local file
  for file in "$MYSQL_DATA"/mysql-bin.[0-9]*; do
    [[ -f "$file" ]] || continue
    base=$(basename "$file")
    present[$base]=1
  done
  if [[ -f "$STATE/uploaded" ]]; then
    while IFS= read -r base; do
      [[ -n "$base" ]] || continue
      present[$base]=1
    done < "$STATE/uploaded"
  fi

  for ((num = wm_n; num < active_n; num++)); do
    base=$(printf 'mysql-bin.%06d' "$num")
    [[ -n "${present[$base]:-}" ]] || return 10
  done

  local copy_list=()
  for ((num = wm_n; num < active_n; num++)); do
    base=$(printf 'mysql-bin.%06d' "$num")
    uploaded_has "$base" && continue
    [[ -f "$MYSQL_DATA/$base" ]] || return 10
    cp -a "$MYSQL_DATA/$base" "$STAGING/binlog/$base"
    copy_list+=("$STAGING/binlog/$base")
  done

  if [[ ${#copy_list[@]} -eq 0 ]]; then
    log "no new binlog files"
    return 0
  fi

  log "uploading ${#copy_list[@]} binlog files"
  restic_run backup --tag db-incr --host kantor-pos "${copy_list[@]}"
  for file in "${copy_list[@]}"; do
    printf '%s\n' "$(basename "$file")" >> "$STATE/uploaded"
  done
  log "incremental binlog stored up to before ${active}"
}

oldest_base_days() {
  python3 - <<'PY'
import datetime
import json
import os
import subprocess

env = os.environ.copy()
raw = subprocess.check_output(
    ["restic", "--insecure-no-password", "-o", f"s3.region={env.get('AWS_DEFAULT_REGION', 'auto')}", "snapshots", "--tag", "db-base", "--json"],
    env=env,
)
snaps = json.loads(raw)
if not snaps:
    print(0)
    raise SystemExit
oldest = None
for snap in snaps:
    stamp = datetime.datetime.fromisoformat(snap["time"])
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=datetime.timezone.utc)
    if oldest is None or stamp < oldest:
        oldest = stamp
now = datetime.datetime.now(datetime.timezone.utc)
print(max(1, (now - oldest).days + 1))
PY
}

mode_prune() {
  load_config
  log "forgetting inbox and base snapshots past retention"
  restic_run forget --tag inbox --group-by tags --keep-daily 14 --keep-weekly 8 --keep-monthly 12
  restic_run forget --tag db-base --group-by tags --keep-daily 14 --keep-weekly 8 --keep-monthly 12
  local days
  days=$(oldest_base_days)
  if [[ "$days" != "0" ]]; then
    log "keeping incremental binlogs for ${days} days, matching the oldest base"
    restic_run forget --tag db-incr --group-by tags --keep-within "${days}d"
  fi
  log "pruning repository"
  restic_run prune
}

usage() {
  echo "usage: backup.sh {check-config|init|inbox|db-base|db-incr|prune}" >&2
  exit 2
}

main() {
  local mode="${1:-}"
  case "$mode" in
    check-config) mode_check_config ;;
    init) with_lock mode_init ;;
    inbox) with_lock mode_inbox ;;
    db-base) with_lock mode_db_base ;;
    db-incr) with_lock mode_db_incr ;;
    prune) with_lock mode_prune ;;
    *) usage ;;
  esac
}

main "$@"
