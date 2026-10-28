#!/usr/bin/env bash
# Automatic Bedrock updates. Every run checks Mojang's download feed; when a NEWER
# server version is out, it warns players in-game, then updates the server and bot.
# When the server is already current it does nothing (nobody gets kicked).
# Cron (every 30 minutes):
#   */30 * * * * /opt/minecraft/autoupdate.sh >> /home/USER/mc-autoupdate.log 2>&1
# Test without changing anything:  DRYRUN=1 ./autoupdate.sh
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a; [ -f .env ] && . ./.env; set +a
WARN="${UPDATE_WARNING:-300}"          # seconds of in-game warning before the restart
API="https://net-secondary.web.minecraft-services.net/api/v1.0/download/links"
STATE=.autoupdate-last                  # last version an update was attempted for
VER_RE='[0-9]+(\.[0-9]+){2,3}'
ts() { date '+%F %T'; }

server_version() {   # version the running server printed at startup
  docker logs bedrock 2>&1 | tr -d '\r' | grep -oE "Version:? *$VER_RE" | tail -1 | grep -oE "$VER_RE" || true
}

latest=$(curl -fsS --max-time 20 "$API" 2>/dev/null \
  | jq -r '.result.links[]? | select(.downloadType=="serverBedrockLinux") | .downloadUrl' 2>/dev/null \
  | grep -oE "$VER_RE" | head -1 || true)
current=$(server_version)
if [ -z "$current" ]; then   # fall back to the newest server binary the image saved
  current=$(ls data 2>/dev/null | sed -n 's/^bedrock_server-\([0-9.]*\)$/\1/p' | sort -V | tail -1 || true)
fi

if [ "${DRYRUN:-0}" = 1 ]; then
  echo "latest available: '${latest:-?}'   server running: '${current:-?}'   last attempted: '$(cat "$STATE" 2>/dev/null || echo none)'"
  exit 0
fi

# Only act on clear information
if [ -z "$latest" ] || [ -z "$current" ]; then
  echo "$(ts) can't tell (latest='$latest' current='$current'), no change"; exit 0
fi
[ "$latest" = "$current" ] && exit 0
[ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)" = "$latest" ] || exit 0   # never downgrade
[ "$(cat "$STATE" 2>/dev/null || true)" = "$latest" ] && exit 0                            # already tried this one

echo "$(ts) new Bedrock version: $current -> $latest"
echo "$latest" > "$STATE"
say() { docker exec -u 0 bedrock send-command say "$1" >/dev/null 2>&1 || true; }
if [ "$WARN" -gt 60 ]; then
  say "Minecraft update: server restarting in $(( WARN / 60 )) minutes"
  sleep $(( WARN - 60 ))
fi
say "Minecraft update: restarting in 1 minute"; sleep 50
say "Restarting now. Rejoin in about a minute."; sleep 10

docker compose pull -q
docker compose up -d --force-recreate   # the server downloads the new version as it starts
sleep 90
now=$(server_version)
echo "$(ts) update finished; server now reports '${now:-unknown}'"

if [ -n "${NTFY_TOPIC:-}" ]; then        # optional phone alert
  curl -fsS -m 10 -H "Title: Minecraft server updated" -d "Bedrock $current -> ${now:-$latest}" \
    "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
fi
