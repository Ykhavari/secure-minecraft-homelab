#!/usr/bin/env bash
# Every 5 minutes: push a phone alert (ntfy) if the server or bot container is down,
# or the bot is logging errors (for example "Failed to relay offer", which means
# joins are failing). One alert per problem per hour, then an all-clear when it's fixed.
# Root crontab:
#   */5 * * * * /opt/minecraft/botwatch.sh >> /var/log/mc-botwatch.log 2>&1
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a; [ -f .env ] && . ./.env; set +a
STATE=.botwatch-state                   # "epoch|message" of the last alert sent
ts() { date '+%F %T'; }
notify() {                              # title, priority, message
  [ -n "${NTFY_TOPIC:-}" ] || return 0
  curl -fsS -m 10 -H "Title: $1" -H "Priority: $2" -d "$3" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
}

problems=()
for c in bedrock broadcast; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" = true ] \
    || problems+=("$c container is not running")
done
errs=$(docker logs --since 6m broadcast 2>&1 | tr -d '\r' | grep 'ERROR' \
  | grep -oE 'Failed to [a-z]+( [a-z]+)?|[A-Za-z.]*Exception|could not be reached' | sort -u | head -3 | paste -sd ';' - || true)
[ -n "$errs" ] && problems+=("bot errors: $errs")

msg=""
[ ${#problems[@]} -gt 0 ] && msg=$(printf '%s\n' "${problems[@]}" | paste -sd '|' -)

prev=$(cat "$STATE" 2>/dev/null || true)
prev_t=${prev%%|*}; prev_m=${prev#*|}
now=$(date +%s)

if [ -n "$msg" ]; then
  if [ "$msg" != "$prev_m" ] || [ $(( now - ${prev_t:-0} )) -ge 3600 ]; then
    echo "$(ts) ALERT: $msg"
    notify "Minecraft server problem" 5 "$msg"
    echo "$now|$msg" > "$STATE"
  fi
elif [ -n "$prev_m" ]; then
  echo "$(ts) recovered"
  notify "Minecraft server OK again" 3 "Server and bot are running with no errors."
  rm -f "$STATE"
fi
