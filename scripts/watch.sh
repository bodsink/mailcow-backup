#!/bin/bash
# Watch the inbox and database commits, then back up after a quiet period.
set -euo pipefail

ROOT=/opt/mailcow-backup
MAILCOW=/opt/mailcow-dockerized
VMAIL=/var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data
BACKUP="$ROOT/bin/backup.sh"
QUIET="${QUIET_SECONDS:-60}"
INBOX_FIFO="$ROOT/state/inbox.events"
DB_FIFO="$ROOT/state/db.events"

log() {
  printf '%s %s\n' "$(date -Is)" "$*"
}

pids=()

cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -f "$INBOX_FIFO" "$DB_FIFO"
}
trap cleanup EXIT

conf_get() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$MAILCOW/mailcow.conf" | tail -n 1)
  printf '%s' "${line#*=}"
}

start_inbox_watch() {
  stdbuf -oL inotifywait -m -r \
    --exclude 'Maildir/tmp/' \
    -e close_write,moved_to,delete,move \
    --format '%e' \
    "$VMAIL" > "$INBOX_FIFO"
}

binlog_position() {
  local dbroot="$1" out
  out=$(docker compose --project-directory "$MAILCOW" exec -T \
    -e MYSQL_PWD="$dbroot" \
    mysql-mailcow \
    mysql --user=root --batch --skip-column-names -e "SHOW BINLOG STATUS;" 2>/dev/null || true)
  if [[ -z "$out" ]]; then
    out=$(docker compose --project-directory "$MAILCOW" exec -T \
      -e MYSQL_PWD="$dbroot" \
      mysql-mailcow \
      mysql --user=root --batch --skip-column-names -e "SHOW MASTER STATUS;")
  fi
  awk 'NR == 1 { print $1, $2 }' <<<"$out"
}

start_db_watch() {
  local dbroot file position
  dbroot=$(conf_get DBROOT)
  while true; do
    file=""
    position=""
    read -r file position < <(binlog_position "$dbroot") || true
    if [[ -z "${file:-}" || -z "${position:-}" ]]; then
      log "binlog is not ready, retrying"
      sleep 5
      continue
    fi
    log "following binlog ${file} from position ${position}"
    docker compose --project-directory "$MAILCOW" exec -T \
      -e MYSQL_PWD="$dbroot" \
      mysql-mailcow \
      mysqlbinlog \
        --no-defaults \
        --read-from-remote-server \
        --host=127.0.0.1 \
        --user=root \
        --stop-never \
        --start-position="$position" \
        "$file" \
      | while IFS= read -r _; do
          echo db
          sleep 1
        done > "$DB_FIFO" || true
    log "binlog stream ended, reconnecting"
    echo db > "$DB_FIFO" || true
    sleep 2
  done
}

run_backup() {
  local mode="$1" rc
  set +e
  "$BACKUP" "$mode"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$mode" == "db-incr" && "$rc" -eq 10 ]]; then
    log "binlog chain is broken, creating a base dump"
    "$BACKUP" db-base
    return 0
  fi
  log "backup ${mode} failed with status ${rc}"
  return "$rc"
}

mkdir -p "$ROOT/state"
"$BACKUP" check-config

rm -f "$INBOX_FIFO" "$DB_FIFO"
mkfifo "$INBOX_FIFO" "$DB_FIFO"
exec 3<>"$INBOX_FIFO"
exec 4<>"$DB_FIFO"

start_inbox_watch &
inbox_pid=$!
pids+=("$inbox_pid")
start_db_watch &
db_pid=$!
pids+=("$db_pid")

log "initial inbox backup"
run_backup inbox
log "syncing database"
run_backup db-incr

inbox_dirty=0
db_dirty=0
inbox_last=0
db_last=0

log "watcher is running, quiet period ${QUIET} seconds"
while true; do
  if ! kill -0 "$inbox_pid" 2>/dev/null || ! kill -0 "$db_pid" 2>/dev/null; then
    log "watcher process stopped"
    exit 1
  fi
  if IFS= read -r -t 1 -u 3 _; then
    inbox_dirty=1
    inbox_last=$(date +%s)
  fi
  if IFS= read -r -t 1 -u 4 _; then
    db_dirty=1
    db_last=$(date +%s)
  fi
  now=$(date +%s)
  if [[ "$inbox_dirty" -eq 1 && $((now - inbox_last)) -ge $QUIET ]]; then
    if run_backup inbox; then
      inbox_dirty=0
    else
      inbox_last=$now
    fi
  fi
  if [[ "$db_dirty" -eq 1 && $((now - db_last)) -ge $QUIET ]]; then
    if run_backup db-incr; then
      db_dirty=0
    else
      db_last=$now
    fi
  fi
done
