#!/usr/bin/env bash
# Every 5 minutes: push a phone alert (ntfy) if the server or bot container is down,
# joins are failing ("Failed to relay offer"), or the bot is stuck (errors with no
# successful Xbox Live refresh for 10 minutes). Brief Xbox Live hiccups that fix
# themselves don't alert. One alert per problem per hour, then an all-clear.
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
recent=$(docker logs --since 6m broadcast 2>&1 | tr -d '\r' || true)
# Joins failing: alert straight away
if grep -q 'Failed to relay offer' <<<"$recent"; then
  problems+=("joins are failing: the bot can't relay joins to the server")
fi
# Any other bot error: the bot refreshes its Xbox Live listing every few seconds and
# an occasional refresh fails on Xbox Live's side, then the next one succeeds. Only
# alert when it's stuck: errors AND no successful refresh in the last 10 minutes.
if grep 'ERROR' <<<"$recent" | grep -vq 'Failed to relay offer'; then
  if ! docker logs --since 10m broadcast 2>&1 | grep -qE 'Updated session|session was successful'; then
    errs=$(grep 'ERROR' <<<"$recent" | grep -oE 'Failed to [a-z]+( [a-z]+)?|[A-Za-z.]*Exception' \
      | sort -u | head -3 | paste -sd ';' - || true)
    problems+=("bot stuck: no Xbox Live refresh for 10 minutes (${errs:-errors})")
  fi
fi

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
