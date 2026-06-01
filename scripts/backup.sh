#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

LABEL="${BACKUP_LABEL:-PI_BACKUP}"
DEST="${BACKUP_MOUNT:-/mnt/backup}"
STATE="${PI_GUARDIAN_STATE_DIR:-/var/lib/pi-guardian}"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    umount "$DEST" || true
  fi
}
trap cleanup EXIT

mkdir -p "$STATE"

if ! mountpoint -q "$DEST"; then
  DEV="$(blkid -L "$LABEL" || true)"
  if [[ -z "$DEV" ]]; then
    echo "No device labeled $LABEL; skipping backup."
    exit 0
  fi

  mkdir -p "$DEST"
  mount "$DEV" "$DEST"
  MOUNTED=1
fi

STAMP="$(date +%F-%H%M)"
ARCHIVE="$DEST/pi-backup-$STAMP.tgz"

set +e
tar --warning=no-file-changed --ignore-failed-read -czf "$ARCHIVE" /etc /home
TAR_STATUS=$?
set -e

if (( TAR_STATUS > 1 )); then
  rm -f "$ARCHIVE"
  echo "Backup failed; tar exited with status $TAR_STATUS."
  exit "$TAR_STATUS"
fi

if [[ ! -s "$ARCHIVE" ]]; then
  rm -f "$ARCHIVE"
  echo "Backup failed; archive was not created."
  exit 1
fi

find "$DEST" -name "pi-backup-*.tgz" -type f -mtime +7 -delete
{
  printf 'timestamp=%s\n' "$(date -Is)"
  printf 'archive=%s\n' "$ARCHIVE"
  printf 'status=ok\n'
} > "$STATE/last_backup.txt"
