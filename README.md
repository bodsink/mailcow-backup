# Mailcow backup to Cloudflare R2

This service runs on the Mailcow host, in `/opt/mailcow-backup`. It backs up only the inbox and the database. Mailcow's own backup notes are in [Backup](https://docs.mailcow.email/backup_restore/b_n_r-backup/) and [Restore](https://docs.mailcow.email/backup_restore/b_n_r-restore/).

## Behavior

Inbox changes are seen through `inotify` on the vmail volume. Database changes are seen through the MariaDB binlog. After 60 seconds with no new event on the same path, the service uploads the delta to R2.

- The inbox uses restic. Only changed files are uploaded.
- The database gets one full dump per day at 02:30 Asia/Jakarta. That dump includes `AUTO_INCREMENT` values and the binlog position.
- Each later commit uploads closed binlog files, not another full dump.

The official Mailcow script is not called automatically. Running it archives the whole inbox again and loads CPU and disk. [Mailcow's manual](https://docs.mailcow.email/backup_restore/b_n_r-backup/#manual) says to run `helper-scripts/backup_and_restore.sh` from its original path and not to copy it. The unattended form for inbox and database is:

```bash
MAILCOW_BACKUP_LOCATION=/opt/mailcow-backup/mailcow-script THREADS=2 \
  /opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh backup vmail mysql
```

## Service directory

- `backup.env` holds the R2 account ID and token
- `bin/watch.sh` watches for changes
- `bin/backup.sh` uploads the inbox, the base dump, or binlogs
- `state/` stores the binlog watermark
- `staging/` holds the dump and binlogs being uploaded
- `cache/` is the restic cache
- `mailcow-script/` is the destination for a manual run of the official script

## Install

On the Mailcow server, as root:

```bash
scripts/install-on-host.sh
```

Fill in `/opt/mailcow-backup/backup.env`:

```bash
R2_ACCOUNT_ID=
S3_ACCESS_KEY_ID=
S3_SECRET_ACCESS_KEY=
S3_BUCKET_NAME=mailcow
S3_REGION=auto
```

```bash
/opt/mailcow-backup/bin/backup.sh init
systemctl enable --now mailcow-backup-watch.service mailcow-backup-base.timer
```

`init` creates the repository in the bucket. The watch service then uploads the current inbox and one base dump. The first inbox upload follows the maildir size. The default upload limit is 8 MiB/s.

The R2 bucket must not have a lifecycle rule that deletes objects. Retention is handled by `backup.sh prune`: 14 daily snapshots, 8 weekly, and 12 monthly. Incremental binlogs are kept for as long as the oldest base dump is kept.

## R2 token

`S3_BUCKET_NAME` is the bucket name, `mailcow` by default. `R2_ACCOUNT_ID` is the Cloudflare account ID. The API token only needs **Object Read & Write** on that bucket. Token values stay in `backup.env` on the server.

## Restore

Objects in the bucket are restic repository packs, not mail files or SQL that can be opened directly. Restore uses restic on the Mailcow server. There is no separate restic password.

Restore into a working directory first. Do not overwrite a volume that is still serving mail.

```bash
set -a
source /opt/mailcow-backup/backup.env
set +a
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"
export RESTIC_REPOSITORY="s3:https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${S3_BUCKET_NAME}"
export RESTIC_CACHE_DIR=/opt/mailcow-backup/cache

restic --insecure-no-password -o s3.region=auto snapshots
```

Choose the newest inbox snapshot (`inbox` tag) and one base dump (`db-base` tag) that is not newer than that inbox. Then restore every `db-incr` snapshot taken after that base. Replace the IDs below with the `snapshots` output.

```bash
mkdir -p /opt/mailcow-backup/restore
restic --insecure-no-password -o s3.region=auto restore <inbox-id> --target /opt/mailcow-backup/restore
restic --insecure-no-password -o s3.region=auto restore <db-base-id> --target /opt/mailcow-backup/restore
restic --insecure-no-password -o s3.region=auto restore <db-incr-id> --target /opt/mailcow-backup/restore
```

Restic restores the original paths under the restore directory:

- Inbox: `var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data`
- Dump: `opt/mailcow-backup/staging/mailcow.sql`
- Binlog: `opt/mailcow-backup/staging/binlog/`

Putting this back onto a running Mailcow replaces the live inbox and database. Stop `postfix-mailcow`, `dovecot-mailcow`, and `sogo-mailcow` first. Mailcow documents the same data as [Maildir](https://docs.mailcow.email/backup_restore/b_n_r-backup_restore-maildir/) and [MySQL (mysqldump)](https://docs.mailcow.email/backup_restore/b_n_r-backup_restore-mysql/). On a new install, check `MAILDIR_SUB` in `mailcow.conf` before restoring mail: [Restore](https://docs.mailcow.email/backup_restore/b_n_r-restore/) says a changed value hides every message.

```bash
cd /opt/mailcow-dockerized
docker compose stop postfix-mailcow dovecot-mailcow sogo-mailcow

rsync -a /opt/mailcow-backup/restore/var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data/ \
  /var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data/
```

Inbox ownership follows the restored files. The Mailcow mail user is usually `5000:5000`.

Load the database from the dump. The start of `mailcow.sql` has a `CHANGE MASTER TO` line with the binlog file and position. Replay binlog files from that file onward, and start the first file at the recorded position. Older files are not replayed. `$DBROOT` comes from `mailcow.conf`.

```bash
DBROOT=$(grep -E '^DBROOT=' /opt/mailcow-dockerized/mailcow.conf | tail -1)
DBROOT=${DBROOT#DBROOT=}
docker compose exec -T -e MYSQL_PWD="$DBROOT" mysql-mailcow \
  mysql --user=root mailcow \
  < /opt/mailcow-backup/restore/opt/mailcow-backup/staging/mailcow.sql
```

Restored binlogs are on the host. Copy the file you need into the container, then replay it. Use the dump position for the first file. Replay later files in numeric order without `--start-position`.

```bash
BINLOG=/opt/mailcow-backup/restore/opt/mailcow-backup/staging/binlog/mysql-bin.000001
docker compose cp "$BINLOG" mysql-mailcow:/tmp/mysql-bin.000001
docker compose exec -T mysql-mailcow \
  mysqlbinlog --no-defaults --start-position=<position> /tmp/mysql-bin.000001 \
  | docker compose exec -T -e MYSQL_PWD="$DBROOT" mysql-mailcow \
      mysql --user=root mailcow
```

After the import:

```bash
docker compose start sogo-mailcow dovecot-mailcow postfix-mailcow
```

## Mailcow documentation

- [Backup](https://docs.mailcow.email/backup_restore/b_n_r-backup/) covers `backup_and_restore.sh`, including the [manual](https://docs.mailcow.email/backup_restore/b_n_r-backup/#manual) run and the rsync strategy
- [Maildir](https://docs.mailcow.email/backup_restore/b_n_r-backup_restore-maildir/) is the vmail volume this service stores as the `inbox` snapshot
- [MySQL (mysqldump)](https://docs.mailcow.email/backup_restore/b_n_r-backup_restore-mysql/) is the logical database dump, matched here by the daily `db-base` snapshot
- [Restore](https://docs.mailcow.email/backup_restore/b_n_r-restore/) is the helper-script restore, including the `MAILDIR_SUB` check
- [mailcow-dockerized](https://github.com/mailcow/mailcow-dockerized) is the application this host runs
