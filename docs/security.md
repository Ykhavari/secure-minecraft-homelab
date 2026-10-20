# Security Design

This server is an **internet-facing service on a home network**, which is the riskiest kind of service a homelab can run. The design goal was simple: **if the server is ever compromised, the attacker gets a game server and nothing else.**

## 1. Threat model

| Asset | Threats | Primary mitigations |
|---|---|---|
| Home network (Proxmox, router, NAS, IoT, personal devices) | Lateral movement from a compromised game server | Host-enforced VM firewall blocks all private ranges outbound; VM can't reach the hypervisor or the firewall UI |
| The game world and players' progress | Griefing, corruption, ransomware on the VM, hardware failure | Allowlist, no operators, live and nightly backups, off-VM NAS copies, whole-VM backups |
| The server VM | Brute force, exploitation of exposed services, privilege escalation | Only game ports exposed; SSH LAN-only and key-only; minimal OS; auto security updates; non-root containers, `no-new-privileges` |
| The bot Xbox account | Account takeover, abuse of its friend list | Dedicated adult account used only for this; strong unique password; auto-follow off |
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
  - TCP 19132 (NetherNet signaling)
  - UDP 19140–19149 (gameplay, one per player; the cap is 10)
  - UDP 19150–19159 (broadcaster ICE ports, deliberately narrowed from the OS's whole ephemeral range)
- **Source restricted to a GeoIP alias** built from MaxMind GeoLite2 (updated automatically).
- Associated filter rules are created as Pass rules tied to the NAT rule, so nothing broader is opened.
- **WAN audit:** checked that no other forwards or WAN rules existed. Fixing the double NAT (see troubleshooting) made any forgotten rules live, so this mattered.

### Identity and access (application)
- `online-mode=true`: Xbox Live authentication is required, so gamertags can't be spoofed.
- `allow-list=true`: deny by default. New players are added one at a time by an admin.
- `default-player-permission-level=member`, `allow-cheats=false`, and **no operators at all**. There's no in-game account that can run commands, so there's nothing to steal or social-engineer. Admin commands are only possible from a shell on the VM.
- **Discovery control:** the broadcaster bot uses `auto-follow: false` and `auto-friend: false`. Following the bot or sending it a request doesn't reveal the server; the admin approves every friend. Automatic friend expiry is off, so approved players aren't silently removed.

### Segmentation (Proxmox per-VM firewall)
Enforced by the **hypervisor**, outside the VM, so a root-level compromise inside the VM can't switch it off.

```
policy_in:  DROP          policy_out: ACCEPT
IN  SSH  from LAN-SUBNET only
IN  game ports (TCP 19132, UDP 19140-19159)
OUT NFS (TCP 2049) to the NAS only          <- the single exception
OUT DROP 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16
```

The VM can reach the internet (Xbox Live, Mojang updates, Debian mirrors) and **nothing private**: not the router UI, the Proxmox UI, other VMs, the NAS's management interface or IoT devices. The MAC filter (`macfilter: 1`) stops it from spoofing other machines' MAC addresses.

### Remote administration
- No management port is ever forwarded. Remote access goes through a private mesh VPN with a subnet router, so the game VM needs no extra software and its isolation rules don't change.
- Each admin device has its own SSH key, which can be revoked individually. Password authentication stays off.

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

### Resilience and integrity
- **Live hot-backups every 2 hours** using Bedrock's official sequence (`save hold`, `save query`, copy each file truncated to its reported length, `save resume`). The copies are consistent, with no downtime.
- **Nightly full backups** with the server cleanly stopped, a configurable in-game warning, and 14-day retention.
- **Off-VM copies** on a NAS over NFS. The share's NFS permission is locked to the VM's IP, and the VM firewall allows only that one port.
- **Weekly whole-VM backups** (Proxmox vzdump to the NAS) for a full rebuild.
- **Clean-shutdown tuning** at every level (Docker `stop_grace_period`, the daemon's `shutdown-timeout`, systemd `TimeoutStopSec`, Proxmox shutdown timeout) so the world is never killed mid-write.
- VM snapshots are taken before changes, and treated as an undo button, not a backup.

## 4. Verification (how I proved each control works)

| Control | Test | Expected |
|---|---|---|
| Segmentation | From the VM: `ping 1.1.1.1`, `ping <gateway>`, `ping <proxmox>`, `apt update` | Internet ✅, gateway ❌, Proxmox ❌, updates ✅ |
| Port forward + GeoIP | From a phone hotspot (outside the LAN): `nc -vz <public-ip> 19132`, while watching the firewall's live log | Connects; the log shows a Pass on the NAT rule |
| No double NAT | Firewall WAN interface address | A public IP, not 192.168.x.x |
| Allowlist | A non-listed account tries to join | Refused ("not invited") |
| SSH hardening | `ssh -o PubkeyAuthentication=no user@vm` | `Permission denied (publickey)` |
| Persistence | Place a block, reboot the VM, rejoin | The block is still there; containers came back on their own |
| Backups | `./mc snapshot`, `./mc backup`, then a test restore | Archives created; restore loads the world |

## 5. Trade-offs and residual risk

- **The public IP is exposed** to anyone who learns it, which is mitigated by GeoIP, allowlisting and segmentation. A tunnel would be preferable if one supported NetherNet for free.
- **GeoIP isn't authentication.** It cuts noise and opportunistic scanning; the allowlist is the real access control.
- **`SYS_PTRACE`** slightly widens what happens inside the container, in exchange for working admin tooling. It's documented and scoped.
- **The bot account is a dependency.** If Microsoft flags it, discovery stops, but the server and data are unaffected.

## 6. What's never in this repo

Public and private IPs, MAC addresses, the MaxMind license key, `.env`, the broadcaster's auth token (`xbox/`), gamertags and emails, world data and backups. The `.gitignore` enforces it, and every value in the configs is a placeholder.
