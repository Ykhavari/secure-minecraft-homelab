# Security Design

This server is an **internet-facing service on a home network**, which is the riskiest kind of service a homelab can run. The design goal was simple: **if the server is ever compromised, the attacker gets a game server and nothing else.**

## 1. Threat model

| Asset | Threats | Primary mitigations |
|---|---|---|
| Home network (Proxmox, router, NAS, IoT, personal devices) | Lateral movement from a compromised game server | Host-enforced VM firewall blocks all private ranges outbound; VM can't reach the hypervisor or the firewall UI |
| The game world and players' progress | Griefing, corruption, ransomware on the VM, hardware failure | Allowlist, no operators, live and nightly backups, off-VM NAS copies, whole-VM backups |
| The server VM | Brute force, exploitation of exposed services, privilege escalation | Only game ports exposed; SSH LAN-only and key-only; minimal OS; auto security updates; non-root containers, `no-new-privileges` |
| The bot Xbox account | Account takeover, abuse of its friend list | Dedicated adult account used only for this; strong unique password; auto-accept off |
| Admin credentials and secrets | Leak through the public repo | `.gitignore` for `.env`, tokens and world data; placeholders for every identifier |

## 2. Why port forwarding, and what I did about the risk

The original plan was a **tunnel**: no open ports, and the home IP hidden. That stopped being possible when Bedrock 1.26.51 became **NetherNet-only** (WebRTC-style: a TCP signaling port plus one UDP port per player). The free tunnel tier only supports the older RakNet protocol, and the server refuses RakNet outright.

Opening ports increases the attack surface, so I offset it with **compensating controls**:

1. **Exposure:** only the exact ports needed are forwarded. No ranges are wider than the player cap, and no management ports.
2. **GeoIP:** traffic from outside the allowed countries is dropped before NAT.
3. **Strong identity:** every player must authenticate with Xbox Live and be on the allowlist.
4. **Blast radius:** even a full compromise of the VM can't reach anything else at home.

## 3. Controls by layer

### Perimeter (OPNsense)
- **Destination NAT** for exactly three ranges, all to one internal host:
  - TCP+UDP 19132 (NetherNet signaling)
  - UDP 19140–19149 (gameplay, one per player; the cap is 10)
  - UDP 19150–19159 (broadcaster ICE ports, deliberately narrowed from the OS's whole ephemeral range)
- **Source restricted to a GeoIP alias** built from MaxMind GeoLite2 (updated automatically).
- Associated filter rules are created as Pass rules tied to the NAT rule, so nothing broader is opened.
- **WAN audit:** checked that no other forwards or WAN rules existed. Fixing the double NAT (see troubleshooting) made any forgotten rules live, so this mattered.

### Identity and access (application)
- `online-mode=true`: Xbox Live authentication is required, so gamertags can't be spoofed.
- `allow-list=true`: deny by default. New players are added one at a time by an admin.
- `default-player-permission-level=member`, `allow-cheats=false`, and **no operators at all**. There's no in-game account that can run commands, so there's nothing to steal or social-engineer. Admin commands are only possible from a shell on the VM.
- **Discovery control:** the broadcaster bot uses `auto-friend: false`. Following the bot or sending it a request doesn't reveal the server; the admin approves every friend. Automatic friend expiry is off, so approved players aren't silently removed.

### Segmentation (Proxmox per-VM firewall)
Enforced by the **hypervisor**, outside the VM, so a root-level compromise inside the VM can't switch it off.

```
policy_in:  DROP          policy_out: ACCEPT
IN  SSH  from LAN-SUBNET only
IN  game ports (TCP+UDP 19132, UDP 19140-19159)
IN  TCP 9001 from the Portainer VM only        <- container dashboard agent
OUT NFS (TCP 2049) to the NAS only          <- the single outbound exception
OUT DROP 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16
```

The VM can reach the internet (Xbox Live, Mojang updates, Debian mirrors) and **nothing private**: not the router UI, the Proxmox UI, other VMs, the NAS's management interface or IoT devices. The MAC filter (`macfilter: 1`) stops it from spoofing other machines' MAC addresses.

### Remote administration
- No management port is ever forwarded. Remote access goes through a private mesh VPN with a subnet router, so the game VM needs no extra software and its isolation rules don't change.
- Each admin device has its own SSH key, which can be revoked individually. Password authentication stays off.
- **Container dashboard:** a Portainer agent lets a separate admin VM show logs, stats and status. The agent needs the Docker socket, which is root-equivalent on this VM, so it is treated as an admin credential: a shared agent secret is required, and the hypervisor firewall only lets that one VM reach port 9001. Docker-published ports bypass UFW, which is exactly why this rule lives at the hypervisor. Starting and stopping the server stays with `./mc`, so the world always saves cleanly.

### Host hardening (Debian VM)
- Minimal install: no desktop, only SSH and standard utilities.
- **SSH:** key-only authentication, password and keyboard-interactive login disabled, root login disabled, reachable only from the LAN (UFW plus the Proxmox firewall). It's never forwarded.
- **UFW** default-deny inbound, as a second firewall layer behind the hypervisor's.
- **unattended-upgrades** for automatic security patches.
- Static IP plus a DNS reservation on the firewall, so its rules always target the right host.

### Container hardening (Docker)
- Game server processes drop to an unprivileged UID; the broadcaster runs as its own non-root UID.
- `security_opt: no-new-privileges:true` on both containers.
- **One capability added on purpose:** `SYS_PTRACE` on the server container only. After the image drops privileges, the server process can't be inspected, so the admin tool couldn't find it to send commands. I chose this over running the container fully privileged: it applies to processes inside that container only and gives no access to the host.
- The broadcaster uses host networking, which is needed for WebRTC ICE, with its ports pinned to a 10-port range and allowed by UFW.
- Log rotation (20 MB × 5) so logs can't fill the disk.
- Containers update weekly through a scheduled `docker compose pull`.

### Monitoring
- **Uptime Kuma runs on a separate admin VM**, not on the server it watches, so a failure of the game VM can't also silence its monitor.
- It checks, every 60 seconds: the game's TCP port, SSH on the VM, the NAS's NFS port (the backup target), the hypervisor's web UI and an internet reachability ping. The checks are layered so a single red result points at the failing piece: game port red with SSH green means the server process, everything red with internet red means the uplink.
- **Alerting:** monitors push to the admin's phone through ntfy, with down events at the highest priority. The topic is a long random string kept out of the repo (anyone who knows a public ntfy topic can read it), and alerts carry only monitor names and up/down state.
- **No new exposure:** every check uses a port the VM already accepts from the LAN, so the VM's firewall didn't change. The dashboard is LAN-only (never port-forwarded) and its admin login requires a strong password plus **two-factor authentication (TOTP)**.

### Configuration integrity
- The public-IP watcher only rewrites config when **two independent services agree** on a valid public address, and it rejects private, CGNAT, loopback and link-local results, so a bad lookup or a transient private WAN lease can't redirect players. It backs up both files before every change.

### Patch management
- **Game server:** `autoupdate.sh` checks Mojang's download feed every 30 minutes and updates only when a **newer** server version exists: in-game warning, then about a minute of restart, then an optional phone alert. It acts only when it can read both the latest and the running version, never downgrades, and records each version it attempted so a failed update can't restart the server in a loop.
- **Containers:** a weekly `docker compose pull` catches image and broadcaster updates.
- **Configuration drift after updates:** every update backs up the broadcaster's config, then `postupdate.sh` re-applies the settings this design depends on (local relay address, no auto-accept, no auto-unfriend) and verifies the bot signed in. An update can change software, but it can't silently undo a security decision.
- **Watchdog:** `botwatch.sh` checks every 5 minutes that both containers run and the bot isn't logging errors, and pushes one alert per problem per hour plus an all-clear.
- **OS:** unattended security updates on the VM.

### Resilience and integrity
- **Live hot-backups every 2 hours** using Bedrock's official sequence (`save hold`, `save query`, copy each file truncated to its reported length, `save resume`). The copies are consistent, with no downtime.
- **Nightly full backups** with the server cleanly stopped, a configurable in-game warning, and 14-day retention.
- **Off-VM copies** on a NAS over NFS. The share's NFS permission is locked to the VM's IP, and the VM firewall allows only that one port.
- **Weekly whole-VM backups** (Proxmox vzdump to the NAS) for a full rebuild.
- **Clean-shutdown tuning** at every level (Docker `stop_grace_period`, the daemon's `shutdown-timeout`, systemd `TimeoutStopSec`, Proxmox shutdown timeout) so the world is never killed mid-write.
- VM snapshots are taken before changes, and treated as an undo button, not a backup.

## 4. Verification (how I proved each control works)

| Control | Test | Result |
|---|---|---|
| Segmentation | From the VM: `ping 1.1.1.1`, `ping <gateway>`, `ping <proxmox>`, `apt update` | Internet ✅, gateway ❌, Proxmox ❌, updates ✅ |
| Port forward + GeoIP | From a phone hotspot (outside the LAN): `nc -vz <public-ip> 19132`, while watching the firewall's live log | Connects; the log shows a Pass on the NAT rule |
| No double NAT | Firewall WAN interface address | A public IP, not 192.168.x.x |
| Allowlist | A non-listed account tries to join | Refused ("not invited") |
| SSH hardening | `ssh -o PubkeyAuthentication=no user@vm` | `Permission denied (publickey)` |
| Segmentation (observed) | Before the NFS exception existed: TCP test to the NAS on 2049 from the VM, and from the Proxmox host | VM blocked, host open; after adding the one rule, the VM reached only that port |
| Persistence | The nightly full backup stops and restarts the server every day while friends build | Builds survive every restart; the container comes back on its own |
| Backups | `./mc snapshot` and `./mc backup` to the NAS, then extract the newest NAS copy to a scratch folder | Archives land on the NAS; the extracted copy holds the complete world (`level.dat` and the world database) |

## 5. Trade-offs and residual risk

- **The public IP is exposed** to anyone who learns it, which is mitigated by GeoIP, allowlisting and segmentation. A tunnel would be preferable if one supported NetherNet for free.
- **GeoIP isn't authentication.** It cuts noise and opportunistic scanning; the allowlist is the real access control.
- **`SYS_PTRACE`** slightly widens what happens inside the container, in exchange for working admin tooling. It's documented and scoped.
- **The Portainer agent is a powerful path.** Anyone who controlled the Portainer VM could control containers here. Mitigated by the agent secret, the single-source firewall rule and keeping the Portainer VM LAN-only.
- **The bot account is a dependency.** If Microsoft flags it, discovery stops, but the server and data are unaffected.

## 6. What's never in this repo

Public and private IPs, MAC addresses, the MaxMind license key, `.env`, the broadcaster's auth token (`xbox/`), gamertags and emails, world data and backups. The `.gitignore` enforces it, and every value in the configs is a placeholder.
