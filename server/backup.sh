#!/usr/bin/env bash
# World backup. Stops the server briefly so the world files are consistent,
# archives the world + allowlist/permissions, then starts it again (~1 min downtime
# including the in-game warning, BACKUP_WARNING seconds in .env).
# Cron example (5:00 AM daily):  0 5 * * * /opt/minecraft/backup.sh >> /var/log/mc-backup.log 2>&1
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
set -a; [ -f .env ] && . ./.env; set +a
BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"

# If the target is meant to be a network mount (/mnt/...) but isn't mounted, don't
# silently fill the VM's own disk under /mnt - fall back to ./backups and say so.
if [[ "$BACKUP_DIR" == /mnt/* ]] && ! mountpoint -q "$BACKUP_DIR" 2>/dev/null; then
  echo "$(date) WARNING: $BACKUP_DIR is not mounted; using ./backups instead"
  BACKUP_DIR="./backups"
fi
mkdir -p "$BACKUP_DIR"
OUT="$BACKUP_DIR/world_$(date +%Y-%m-%d_%H%M).tar.gz"

# Only include files that exist (some appear only after first start / first op)
items=()
for f in worlds allowlist.json permissions.json server.properties; do
  [ -e "data/$f" ] && items+=("$f")
done
[ ${#items[@]} -gt 0 ] || { echo "Nothing to back up yet (has the server run?)"; exit 1; }

running=false
if [ "$(docker inspect -f '{{.State.Running}}' bedrock 2>/dev/null)" = "true" ]; then
  running=true
  docker exec -u 0 bedrock send-command say "Backup: server restarting in ${BACKUP_WARNING:-60} seconds" || true
  sleep $(( ${BACKUP_WARNING:-60} > 10 ? ${BACKUP_WARNING:-60} - 10 : 0 ))
  docker exec -u 0 bedrock send-command say "Backup in 10 seconds..." || true
  sleep 10
  docker compose stop bedrock
fi

# Always bring the server back up, even if tar fails
trap '$running && docker compose start bedrock >/dev/null' EXIT

tar -czf "$OUT" -C data "${items[@]}"
echo "$(date) Backup written: $OUT ($(du -h "$OUT" | cut -f1))"

find "$BACKUP_DIR" -name 'world_*.tar.gz' -mtime +"$BACKUP_KEEP_DAYS" -delete
