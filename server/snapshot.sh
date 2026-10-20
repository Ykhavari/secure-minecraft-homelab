#!/usr/bin/env bash
# Live world snapshot - NO downtime, players keep playing.
# Uses Bedrock's official hot-backup sequence:
#   save hold   -> server finishes writing and freezes the file set
#   save query  -> server lists exactly which files to copy and how long each is
#   (copy those files, truncated to the listed length)
#   save resume -> back to normal
# Cron example (every 2 hours):  0 */2 * * * /opt/minecraft/snapshot.sh >> ~/mc-snapshot.log 2>&1
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
set -a; [ -f .env ] && . ./.env; set +a
BACKUP_DIR="${BACKUP_DIR:-./backups}"
SNAPSHOT_KEEP_HOURS="${SNAPSHOT_KEEP_HOURS:-48}"

if [[ "$BACKUP_DIR" == /mnt/* ]] && ! mountpoint -q "$BACKUP_DIR" 2>/dev/null; then
  echo "$(date) WARNING: $BACKUP_DIR is not mounted; using ./backups instead"
  BACKUP_DIR="./backups"
fi
mkdir -p "$BACKUP_DIR"

if [ "$(docker inspect -f '{{.State.Running}}' bedrock 2>/dev/null)" != "true" ]; then
  echo "$(date) bedrock is not running; nothing to snapshot"; exit 0
fi

STAMP="$(date +%Y-%m-%d_%H%M)"
mkdir -p ./backups
STAGE="$(mktemp -d ./backups/.stage.XXXXXX)"
chmod 755 "$STAGE"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cleanup() {
  docker exec -u 0 bedrock send-command save resume >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

docker exec -u 0 bedrock send-command save hold >/dev/null

# Poll until the server says the files are ready (normally a few seconds)
filelist=""
for _ in $(seq 1 30); do
  sleep 2
  docker exec -u 0 bedrock send-command save query >/dev/null
  sleep 1
  filelist="$(docker logs --since "$SINCE" bedrock 2>&1 | tr -d '\r' \
              | grep -A1 'Files are now ready to be copied' | tail -n1 || true)"
  [[ -n "$filelist" && "$filelist" != *"Files are now ready"* ]] && break
  filelist=""
done
[ -n "$filelist" ] || { echo "$(date) ERROR: server never reported files ready; snapshot skipped"; exit 1; }

# Copy each listed file, truncated to the length the server gave (required for a valid copy)
python3 -I - "$filelist" "data/worlds" "$STAGE/worlds" <<'PY'
import os, re, shutil, sys
line, src_root, dst_root = sys.argv[1], sys.argv[2], sys.argv[3]
line = re.sub(r'^\[[^\]]*\]\s*', '', line.strip())     # drop a "[timestamp INFO]" prefix if present
count = 0
for entry in line.split(', '):
    path, _, length = entry.strip().rpartition(':')
    if not path or not length.isdigit():
        sys.exit(f"Unexpected file list entry: {entry!r}")
    src = os.path.join(src_root, path)
    dst = os.path.join(dst_root, path)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    with open(dst, 'r+b') as f:
        f.truncate(int(length))
    count += 1
print(f"copied {count} files")
PY

# Server can resume now; the archive is built from the staged copy
docker exec -u 0 bedrock send-command save resume >/dev/null

for f in allowlist.json permissions.json server.properties; do
  [ -e "data/$f" ] && cp "data/$f" "$STAGE/"
done

OUT="$BACKUP_DIR/snapshot_${STAMP}.tar.gz"
tar -czf "$OUT" -C "$STAGE" .
echo "$(date) Snapshot written: $OUT ($(du -h "$OUT" | cut -f1))"

find "$BACKUP_DIR" -name 'snapshot_*.tar.gz' -mmin +$(( SNAPSHOT_KEEP_HOURS * 60 )) -delete
