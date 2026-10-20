# Operations

All commands run on the VM, from `/opt/minecraft`.

## Day to day

```bash
./mc allow "Gamertag"     # add a player (Microsoft gamertag, not PSN name)
./mc deny  "Gamertag"     # remove + kick
./mc list                 # show the allowlist
./mc say   "message"      # broadcast in game
./mc status               # both containers should be Up
./mc logs                 # live server log (Ctrl+C to exit; server keeps running)
./mc xbox-login           # live broadcaster log
```

**Adding a friend:**
1. `./mc allow "TheirGamertag"`
2. Become Xbox friends with the bot account. The admin accepts or sends the request, since auto-follow is off.
3. They join from **Play → Friends**.

## Backup schedule (cron)

Example schedule; pick your own times:

```cron
0 */2 * * * /opt/minecraft/snapshot.sh >> ~/mc-snapshot.log 2>&1        # live, no downtime, 48 h kept
0 5 * * *   /opt/minecraft/backup.sh   >> ~/mc-backup.log   2>&1        # full, warned restart, 14 days kept
30 5 * * 0  cd /opt/minecraft && ./mc update >> ~/mc-update.log 2>&1    # weekly image update
```

Retention and the warning length are set in `.env` (`SNAPSHOT_KEEP_HOURS`, `BACKUP_KEEP_DAYS`, `BACKUP_WARNING`). Proxmox also backs up the whole VM weekly to the NAS.

## Restore

```bash
docker compose stop bedrock
mv data/worlds data/worlds.broken
tar -xzf /path/to/backup.tar.gz -C data
docker compose start bedrock
```

## If the public IP changes

Update `server-udp-ports` in `data/server.properties` and `ip:` under `session-info:` in `xbox/config.yml`, then run `docker compose restart`.

## Never

- Change `LEVEL_NAME` without renaming the world folder (the server would create a new, empty world).
- Use **Stop** on the VM in Proxmox; use **Shutdown**.
- Forward SSH or any management port.
