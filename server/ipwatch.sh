#!/usr/bin/env bash
# Public IP watcher. If the home public IP changes, update server-udp-ports (the
# address the server advertises for gameplay) and restart the server, with an
# in-game warning first. Does nothing when the IP is unchanged. The bot is not
# touched: since broadcaster build 160 it relays joins to the server locally
# (remote-address 127.0.0.1), so it no longer needs the public IP.
# Runs from root's crontab every 5 minutes:
#   */5 * * * * /opt/minecraft/ipwatch.sh >> /var/log/mc-ipwatch.log 2>&1
set -euo pipefail
cd "$(dirname "$0")"

PROPS=data/server.properties

valid_public() {  # dotted IPv4, not private / CGNAT / loopback / link-local
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
  for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done
  (( a == 10 || a == 127 || a == 0 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 100 && b >= 64 && b <= 127 )) && return 1
  return 0
}

# Ask two independent services; only act when they agree (no change on a bad lookup)
IP1=$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)
IP2=$(curl -4 -fsS --max-time 10 https://ifconfig.me/ip || true)
if [ -z "$IP1" ] || [ "$IP1" != "$IP2" ] || ! valid_public "$IP1"; then
  echo "$(date '+%F %T') lookup unclear (ipify='$IP1' ifconfig='$IP2'), no change"
  exit 0
fi
NEW=$IP1

CUR=$(sed -n 's/^server-udp-ports=\([0-9.]*\):.*/\1/p' "$PROPS")
[ "$CUR" = "$NEW" ] && exit 0

echo "$(date '+%F %T') public IP changed: '$CUR' -> '$NEW'"
cp "$PROPS" "$PROPS.bak-ip"
sed -i "s/^server-udp-ports=.*/server-udp-ports=$NEW:19140-19149:19140-19149/" "$PROPS"
chown 1000:1000 "$PROPS" "$PROPS.bak-ip"

docker exec -u 0 bedrock send-command say "Network change: server restarting in 30 seconds" >/dev/null 2>&1 || true
sleep 30
docker compose restart bedrock
echo "$(date '+%F %T') updated to $NEW and restarted"
