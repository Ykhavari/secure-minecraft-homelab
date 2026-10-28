#!/usr/bin/env bash
# Run after every update. A new broadcaster build can migrate config.yml and carry
# old values into new settings (build 160 copied the public IP into remote-address,
# so every join timed out). This re-applies the settings this setup depends on,
# restarts the bot only if something changed, then confirms the bot signed in.
# Run as root: the bot's config belongs to its own user (UID 1001).
#   sudo /opt/minecraft/postupdate.sh
set -euo pipefail
cd "$(dirname "$0")"
CFG=xbox/config.yml
ts() { date '+%F %T'; }
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
[ -f "$CFG" ] || { echo "$(ts) no $CFG, nothing to check"; exit 1; }

before=$(sha256sum "$CFG")
sed -i \
  -e 's/^\(\s*remote-address:\).*/\1 127.0.0.1/' \
  -e 's/^\(\s*auto-friend:\).*/\1 false/' \
  -e 's/^\(\s*auto-follow:\).*/\1 false/' \
  -e '/^\s*expiry:/{n;s/^\(\s*enabled:\).*/\1 false/}' \
  "$CFG"
chown 1001:1001 "$CFG"

warn=""
grep -qE '^\s*remote-address:\s*127\.0\.0\.1\s*$' "$CFG" \
  || warn="no remote-address setting found; the bot's config format may have changed"

if [ "$before" != "$(sha256sum "$CFG")" ]; then
  echo "$(ts) bot settings re-applied; restarting the bot"
  docker compose restart broadcast >/dev/null
  sleep 5
fi

# Signed in since its most recent start? (the bot logs this once it is listed on
# Xbox Live again; allow up to a minute)
signed_in() {
  docker logs broadcast 2>&1 | tr -d '\r' \
    | awk '/Starting MCXboxBroadcast/{ok=0} /session was successful/{ok=1} END{exit !ok}'
}
ok=no
for _ in $(seq 1 12); do
  if signed_in; then ok=yes; break; fi
  sleep 5
done
running=$(docker inspect -f '{{.State.Running}}' bedrock 2>/dev/null || echo false)

echo "$(ts) post-update check: server running=$running, bot signed in=$ok${warn:+, WARNING: $warn}"
[ "$ok" = yes ] && [ "$running" = true ] && [ -z "$warn" ]
