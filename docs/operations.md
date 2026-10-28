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
2. Become Xbox friends with the bot account. The admin accepts or sends the request, since auto-accept is off.
3. They join from **Play → Friends**.

## Watching joins live

```bash
docker compose logs -f --since 1m bedrock | grep --line-buffered -E "Player (connected|Spawned|disconnected)"
```

Saved as a shell alias (`joins`) in `~/.bashrc`. Recent history:

```bash
docker compose logs bedrock | grep -E "Player (connected|disconnected)" | tail -20
```

## "Can't join" checklist (check the player's side first)

1. Signed into Minecraft with their **Microsoft account**. The allowlisted name is their Microsoft gamertag, not their PSN name.
2. **Cross-platform play** is on in Minecraft settings.
3. **PlayStation only:** PS Plus is active (Essential is enough).
4. They're **friends with the bot**, and the admin has accepted the request.
5. They're on the allowlist: `./mc list`. The exact name they tried is in `./mc logs`.
6. **Admin side:** the firewall's WAN holds the public IP, not a private one.

## Remote admin

Over a private mesh VPN with a subnet router at home, using key-only SSH from a phone with its own key. SSH is never port-forwarded.

## Backup schedule (cron)

Example schedule; pick your own times:

```cron
0 */2 * * * /opt/minecraft/snapshot.sh >> ~/mc-snapshot.log 2>&1        # live, no downtime, 48 h kept
0 5 * * *   /opt/minecraft/backup.sh   >> ~/mc-backup.log   2>&1        # full, warned restart, 14 days kept
30 5 * * 0  cd /opt/minecraft && ./mc update >> ~/mc-update.log 2>&1    # weekly image update
```

Backups are written to the NAS share mounted at `/mnt/mc-backups`; if it isn't mounted, the scripts fall back to `./backups` and log a warning. Retention and the warning length are set in `.env` (`SNAPSHOT_KEEP_HOURS`, `BACKUP_KEEP_DAYS`, `BACKUP_WARNING`). Proxmox also backs up the whole VM weekly to the NAS in snapshot mode, so players aren't disconnected.

```cron
*/5 * * * * /opt/minecraft/ipwatch.sh >> /var/log/mc-ipwatch.log 2>&1   # root crontab: public-IP watcher
```

## Automatic updates

`autoupdate.sh` runs from cron every 30 minutes and does nothing unless Mojang has released a newer Bedrock server:

Root crontab (offset from the backup and snapshot times so they never overlap):

```cron
15,45 * * * * /opt/minecraft/autoupdate.sh >> /var/log/mc-autoupdate.log 2>&1   # new Bedrock version? update
*/5 * * * *   /opt/minecraft/botwatch.sh   >> /var/log/mc-botwatch.log   2>&1   # alert on down/errors
30 5 * * 0    cd /opt/minecraft && ./mc update >> /var/log/mc-update.log 2>&1  # weekly catch-all
```

Every update (automatic or `./mc update`) backs up `xbox/config.yml` to `config.yml.bak-update`, then runs `postupdate.sh`, which re-applies the bot's settings and confirms it signed in. Run it by hand any time with `sudo ./postupdate.sh`.

- Test without changing anything: `DRYRUN=1 ./autoupdate.sh` (prints the latest and running versions).
- Warning length: `UPDATE_WARNING` in `.env` (seconds, default 300). Optional phone alert: `NTFY_TOPIC` in `.env`.
- To update immediately instead: `./mc update`.

## Monitoring

Uptime Kuma (`monitoring/docker-compose.yml`) runs on a separate admin VM and checks every 60 seconds:

| Monitor | Check | Red means |
|---|---|---|
| Game port | TCP to the VM on 19132 | The Bedrock server stopped listening |
| VM SSH | TCP to the VM on 22 | The whole VM is down or unreachable |
| Backup NAS | TCP to the NAS on 2049 | Backups are falling back to the VM's own disk |
| Hypervisor | HTTPS to the Proxmox UI (self-signed cert allowed) | The host itself has a problem |
| Internet | Ping a public resolver | The uplink is down, not the servers |

Retries are set to 2 so a single dropped check doesn't raise a false alarm. Down and recovery events push to the admin's phone through ntfy (down events at urgent priority). Update with `docker compose pull && docker compose up -d`; monitors and history live in `./data`.

## Restore

```bash
docker compose stop bedrock
mv data/worlds data/worlds.broken
tar -xzf /path/to/backup.tar.gz -C data
docker compose start bedrock
```

## If the public IP changes

Handled automatically by `ipwatch.sh` (root cron, every 5 minutes; log in `/var/log/mc-ipwatch.log`). To do it by hand: update `server-udp-ports` in `data/server.properties` and `ip:` under `session-info:` in `xbox/config.yml`, then run `docker compose restart`.

## Never

- Change `LEVEL_NAME` without renaming the world folder (the server would create a new, empty world).
- Use **Stop** on the VM in Proxmox; use **Shutdown**.
- Forward SSH or any management port.
