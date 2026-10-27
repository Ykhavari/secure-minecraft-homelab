# Minecraft Bedrock Server — Kit

A self-hosted Bedrock server in a Debian VM on Proxmox, for friends on **Xbox and PS5**.
No monthly cost. The step-by-step build lives in the **Minecraft Server Build** checklist;
this file is the quick reference for what's in the kit and how it fits together.

```
Friend's console ──► your public IP (OPNsense, GeoIP-filtered) ──► port forward ──► Minecraft VM
       ▲                                                                              │
       └── sees the server in the Friends tab ◄── bot Xbox account (MCXboxBroadcast) ◄─┘
```

## What's in the kit

| File | Purpose |
|---|---|
| `docker-compose.yml` | The server (`bedrock`) and the Friends-tab broadcaster (`broadcast`) |
| `.env.example` | Your settings: server name, world name, operators, backup location |
| `setup-vm.sh` | One-time VM prep: Docker, VM firewall, SSH hardening, safe-shutdown settings |
| `mc` | Day-to-day helper (`./mc allow`, `./mc logs`, `./mc backup`, …) |
| `snapshot.sh` | Live backup, no downtime |
| `backup.sh` | Full backup (brief restart, also updates Bedrock) |
| `ipwatch.sh` | Follows a changing public IP and restarts with a warning |
| `proxmox-vm-firewall.fw` | Proxmox firewall rules for the VM (`/etc/pve/firewall/<VMID>.fw`) |

## How the networking works

Bedrock **1.26.51+ only accepts NetherNet** connections, which need:

| Port | Protocol | Used for |
|---|---|---|
| 19132 | TCP | Handshake (signaling) |
| 19140–19149 | UDP | Gameplay, one port per player (10 players) |
| 19150–19159 | UDP | Friends-tab broadcaster joins |

These must be set in `data/server.properties` (the server image has no setting for them):
```
transport=nethernet
server-udp-ports=YOUR-PUBLIC-IP:19140-19149:19140-19149
```

**OPNsense:** three Destination NAT rules (WAN → the VM, same ports), source limited to a
GeoIP alias of allowed countries, Firewall rule = Pass. OPNsense must hold the **public IP** on WAN. If WAN shows
`192.168.1.x`, the ISP gateway's IP Passthrough isn't matching the firewall's WAN MAC.

## Security layers

- **GeoIP:** only allowed countries reach the game ports.
- **Allowlist + Xbox Live sign-in:** only gamertags you add can join, and names can't be faked.
- **Members only, cheats off:** friends can't run commands. There's no in-game operator (`OPS=""`); admin from the VM with `./mc cmd`.
- **Proxmox VM firewall:** the VM can't reach anything on your home network.
- **Container hardening:** non-root, no-new-privileges, auto-restart, weekly image update.

## Everyday commands (run from `/opt/minecraft`)

```bash
./mc allow "Gamertag"     ./mc deny "Gamertag"    ./mc list
./mc say <message>        ./mc kick "Gamertag"    ./mc cmd <any server command>
./mc status               ./mc logs               ./mc update
./mc snapshot             ./mc backup             ./mc backups
```

PS5 players are allowlisted by their **Microsoft gamertag** (shown in Minecraft once signed in), not their PSN name.

## Backups

- `snapshot.sh` every 2 hours (live), `backup.sh` nightly, `./mc update` weekly, all via `crontab -e`.
- `BACKUP_DIR` in `.env`: `/mnt/mc-backups` (the NAS share); falls back to `./backups` if it isn't mounted.
- Restore: `docker compose stop bedrock`, move `data/worlds` aside, `tar -xzf <backup> -C data`, `docker compose start bedrock`.

## Never do these

- Change `LEVEL_NAME` without renaming the folder in `data/worlds/`. The server would start a new, empty world.
- Delete `data/`.
- Use **Stop** on the VM in Proxmox, which pulls the plug. Use **Shutdown** or `sudo reboot`.

## If your public IP changes

`ipwatch.sh` handles it automatically (root cron, every 5 minutes). By hand: update `server-udp-ports` in
`data/server.properties` and `ip:` (under `session-info:`) in `xbox/config.yml`, then run `docker compose restart`.
