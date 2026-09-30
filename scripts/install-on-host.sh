#!/bin/bash
# Install on the Mailcow server. Copy the service to /opt/mailcow-backup and enable the binlog.
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
ROOT=/opt/mailcow-backup
MAILCOW=/opt/mailcow-dockerized
CNF_DST="$MAILCOW/data/conf/mysql/99-backup-binlog.cnf"

log() {
  printf '%s %s\n' "$(date -Is)" "$*"
}

[[ $(id -u) -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -d "$MAILCOW" ]] || { echo "Mailcow is not installed at ${MAILCOW}" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-upgrade restic inotify-tools python3

install -d -m 0750 "$ROOT" "$ROOT/bin" "$ROOT/state" "$ROOT/staging/binlog" "$ROOT/cache" "$ROOT/systemd"
install -d -m 0757 "$ROOT/mailcow-script"
install -m 0750 "$SRC/scripts/backup.sh" "$ROOT/bin/backup.sh"
install -m 0750 "$SRC/scripts/watch.sh" "$ROOT/bin/watch.sh"
install -m 0644 "$SRC/systemd/mailcow-backup-watch.service" "$ROOT/systemd/mailcow-backup-watch.service"
install -m 0644 "$SRC/systemd/mailcow-backup-base.service" "$ROOT/systemd/mailcow-backup-base.service"
install -m 0644 "$SRC/systemd/mailcow-backup-base.timer" "$ROOT/systemd/mailcow-backup-base.timer"

if [[ ! -f "$ROOT/backup.env" ]]; then
  install -m 0600 "$SRC/env/backup.env.example" "$ROOT/backup.env"
  log "created backup.env from the example"
else
  chmod 0600 "$ROOT/backup.env"
  log "left the existing backup.env in place"
fi

if ! cmp -s "$SRC/mysql/99-backup-binlog.cnf" "$CNF_DST"; then
  install -m 0644 "$SRC/mysql/99-backup-binlog.cnf" "$CNF_DST"
  log "enabling the binlog and restarting mysql-mailcow"
  dbroot=$(grep -E '^DBROOT=' "$MAILCOW/mailcow.conf" | tail -n 1)
  dbroot=${dbroot#DBROOT=}
  docker compose --project-directory "$MAILCOW" restart mysql-mailcow
  ready=0
  for _ in $(seq 1 40); do
    if docker compose --project-directory "$MAILCOW" exec -T \
      -e MYSQL_PWD="$dbroot" \
      mysql-mailcow \
      mysql --user=root --batch --skip-column-names -e "SELECT 1" >/dev/null 2>&1; then
      value=$(docker compose --project-directory "$MAILCOW" exec -T \
        -e MYSQL_PWD="$dbroot" \
        mysql-mailcow \
        mysql --user=root --batch --skip-column-names -e "SHOW VARIABLES LIKE 'log_bin';" | awk '{ print $2 }')
      if [[ "$value" == "ON" ]]; then
        ready=1
        break
      fi
    fi
    sleep 3
  done
  if [[ "$ready" -ne 1 ]]; then
    log "MariaDB is unhealthy after enabling the binlog, configuration reverted"
    rm -f "$CNF_DST"
    docker compose --project-directory "$MAILCOW" restart mysql-mailcow
    exit 1
  fi
  log "log_bin ON"
else
  log "binlog configuration is already installed"
fi

ln -sfn "$ROOT/systemd/mailcow-backup-watch.service" /etc/systemd/system/mailcow-backup-watch.service
ln -sfn "$ROOT/systemd/mailcow-backup-base.service" /etc/systemd/system/mailcow-backup-base.service
ln -sfn "$ROOT/systemd/mailcow-backup-base.timer" /etc/systemd/system/mailcow-backup-base.timer
systemctl daemon-reload

log "service installed at ${ROOT}"
log "set R2_ACCOUNT_ID, S3_ACCESS_KEY_ID, and S3_SECRET_ACCESS_KEY in ${ROOT}/backup.env"
log "then run: ${ROOT}/bin/backup.sh init && systemctl enable --now mailcow-backup-watch.service mailcow-backup-base.timer"
