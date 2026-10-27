# Troubleshooting Log

Every problem below happened during the build. Each entry gives the symptom, the root cause, the fix, and what I took away from it.

---

## 1. The free tunnel stopped working (protocol change)

**Symptom:** with the tunnel agent connected, consoles still couldn't join. The server log showed a transport error whenever it was set to the older protocol.

**Root cause:** Bedrock **1.26.51+ only accepts NetherNet**, a WebRTC-style transport: a TCP signaling port plus one UDP port per player. The tunnel's free tier only carries **RakNet** (the legacy UDP protocol), and the server now rejects `transport=raknet` at startup.

**Fix:** dropped the tunnel and switched to port forwarding with compensating controls (GeoIP, allowlist, segmentation; see [security.md](security.md)). NetherNet also needs the server to advertise its **public** IP, which the container image has no setting for, so I set it directly in `server.properties`:

```properties
transport=nethernet
server-udp-ports=<PUBLIC-IP>:19140-19149:19140-19149
```

**Lesson:** check which protocols every hop supports before choosing an architecture. A design that worked last month can break with a client update.

---

## 2. A hidden double NAT

**Symptom:** the port forward was set up correctly, but an outside connection test (`nc` from a phone hotspot) timed out. The firewall's live log showed nothing arriving at all.

**Investigation:** the firewall's WAN interface had a **192.168.1.x** address, not a public one. That meant it was sitting behind the ISP gateway's own NAT, and probably had been since it was installed.

**Root cause:** the ISP gateway's IP Passthrough was bound to the firewall NIC's **hardware MAC**, but the firewall's WAN was using a **spoofed MAC** left over from an old dual-WAN failover configuration. Since the MACs didn't match, the gateway treated the firewall as an ordinary LAN client.

**Fix:** pointed the gateway's passthrough at the MAC the firewall actually uses (found under Interfaces → Assignments), then renewed the WAN lease. The WAN then held the real public IP.

**Follow-ups:**
- **Audited every NAT and WAN rule.** Any old port forwards were now actually reachable from the internet.
- **Kept access to the gateway's admin page** (a private address that the firewall no longer routes to) with a WAN-side **virtual IP** and a **hybrid outbound NAT** rule scoped to the LAN subnet.

**Lesson:** "my port forward doesn't work" is often a NAT problem one level up. Check the WAN address first.

---

## 3. A health check that always failed

**Symptom:** `docker compose ps` showed the server as **(unhealthy)** permanently, even though it ran fine.

**Root cause:** the image's built-in health check pings the server over **RakNet**, which a NetherNet-only server never answers.

**Fix:** disabled the health check (`healthcheck: disable: true`) and monitored the broadcaster's session updates and an external port test instead. I didn't replace it with a homemade probe, to avoid false confidence.

**Lesson:** a monitoring check that always fails trains you to ignore alerts. Fix it or remove it.

---

## 4. The broadcaster couldn't write its config (UID mismatch)

**Symptom:** the broadcaster crashed on start with `AccessDeniedException: /opt/app/config/...config.yml.tmp`.

**Root cause:** the bind-mounted folder belonged to the admin user (UID 1000), but the broadcaster image runs as **UID 1001**.

**Fix:** asked the image which user it runs as, then gave that user the folder. I didn't make it world-writable:

```bash
U=$(docker compose run --rm -T --no-deps --entrypoint id broadcast -u)
G=$(docker compose run --rm -T --no-deps --entrypoint id broadcast -g)
sudo chown -R "$U:$G" xbox
```

**Lesson:** check the container's real UID before changing permissions. `chmod 777` would have "worked" and quietly created a security problem.

---

## 5. Admin commands failed: "failed to search for bedrock server process"

**Symptom:** `./mc allow <gamertag>` printed `find: '/proc/1/exe': Permission denied` and failed.

**Root cause:** the image's `send-command` tool finds the server by reading `/proc/<pid>/exe`. After the entrypoint drops privileges, those processes are **not dumpable**, so neither the default exec user nor root inside the container could inspect them without `CAP_SYS_PTRACE`.

**Fix:** two parts, kept as narrow as possible:
1. run `docker exec -u 0 ... send-command` in the helper and backup scripts
2. add only `SYS_PTRACE` to the server container, instead of making it `privileged`

**Lesson:** add the single missing capability, not all of them. Documenting why it's needed is part of the fix.

---

## 6. The broadcaster couldn't query the server, and wanted the whole ephemeral port range

**Symptom:** `Failed to ping server` timeouts. By default, the broadcaster also uses ICE ports anywhere in the OS's ephemeral range.

**Root cause:** the broadcaster's status query also uses RakNet. Unpinned ICE ports would have meant forwarding thousands of UDP ports.

**Fix:** `query-server: false` with `config-fallback: true` (the server name and player cap are supplied from config), plus `ice-port-range` pinned to **19150–19159**. That's 10 forwarded ports instead of about 28,000.

---

## 7. GeoIP alias wouldn't populate

**Symptom:** the firewall alias stayed empty, and the editor complained about a missing source.

**Root cause:** the alias had been created as **Host(s)** instead of **GeoIP**, and GeoIP aliases need a data source configured first.

**Fix:** added the MaxMind GeoLite2 download URL (with a free license key) under Aliases → GeoIP settings, then recreated the alias with type GeoIP. The ranges then loaded, which I confirmed in Diagnostics.

---

## 8. Avoiding a firewall lockout

**Risk:** enabling a default-deny firewall on the hypervisor over SSH can cut off your own access.

**Fix:** every change was applied with a **dead-man switch**, and the rollback was cancelled only after I'd confirmed the web UI and a **new** SSH session both still worked:

```bash
nohup bash -c 'sleep 600; pve-firewall stop' >/dev/null 2>&1 &   # auto-rollback in 10 min
# ...apply rules, test from a second session...
pkill -f 'sleep 600; pve-firewall stop'                           # cancel only when safe
```

**Lesson:** always have a way back before changing access controls remotely. Network engineers do the same with `reload in 10`.

---

## 9. Debian VM setup issues

| Symptom | Cause | Fix |
|---|---|---|
| Couldn't SSH in after install | SSH server not selected in the installer | `tasksel` → SSH server + standard utilities |
| `apt` asked for the install DVD | The installer left a `cdrom:` source | Commented it out in `/etc/apt/sources.list` |
| DNS settings kept disappearing | `dhcpcd` was rewriting `/etc/resolv.conf` | `nohook resolv.conf` in its config; disabled `dhcpcd` since the IP is static |
| Lost the VM login | n/a | Reset through GRUB (`init=/bin/bash`, remount read-write, `passwd`) |

---

## 10. The bot account was blocked at sign-up

**Symptom:** Microsoft refused to create a new account ("unusual activity").

**Root cause:** anti-fraud checks on new sign-ups from a home network.

**Fix:** used an existing spare Microsoft account instead, changed its gamertag (the first change is free) and set its privacy for cross-network play, multiplayer and online visibility.

---

## 11. The bot accepted every friend request on its own

**Symptom:** strangers who sent the bot a friend request were accepted automatically, even with `auto-follow: false` set.

**Root cause:** this version of the broadcaster has a separate setting, `auto-friend`, that auto-accepts incoming requests. A second setting, `expiry`, silently unfriended anyone who hadn't joined for 15 days.

**Fix:** turned both off, so the admin approves every friend and friends who take a break aren't dropped:

```bash
sudo sed -i -e 's/^\(\s*auto-friend:\).*/\1 false/' \
            -e '/expiry:/,/check:/s/^\(\s*enabled:\).*/\1 false/' xbox/config.yml
docker compose restart broadcast
```

**Lesson:** read the actual config file rather than assuming setting names from documentation. The allowlist meant no stranger could join, but discovery should be controlled too.

---

## 12. Joins failed intermittently: the WAN fell back to a private address

**Symptom:** a test join from a phone on cellular reached the bot, which logged a successful transfer, but the server logged nothing. Other tests at other times had passed.

**Investigation:** the firewall's own log showed outbound traffic leaving the WAN from a **private 192.168.1.x address** for several hours that morning, while the evening before and the afternoon after showed the public IP. The failed join fell inside that window.

**Root cause:** when the ISP gateway reboots or loses its uplink, it briefly hands out a private lease. The firewall accepted it and kept it until the lease expired, which silently disabled every port forward.

**What didn't work:** OPNsense's *Reject Leases From* the gateway's address. The gateway serves the public passthrough lease from that same address, so the firewall lost its connection entirely. I reverted it straight away.

**Fix:** shortened the gateway's private DHCP lease and the passthrough lease, so a wrong lease is replaced within minutes instead of hours. As a further option, a watchdog can renew the WAN lease automatically whenever no public address is present.

**Lesson:** "it worked yesterday" can be a network that changes underneath you. Correlating timestamps across the firewall and application logs found it.

---

## 13. One console player couldn't join at all

**Symptom:** a PlayStation player could see the server but never connect.

**Root cause:** not the server. Online multiplayer on PlayStation requires an active PS Plus subscription, and theirs had lapsed.

**Fix:** PS Plus Essential is enough. Nothing changed on the server.

**Lesson:** rule out client-side entitlements before changing infrastructure. A per-platform checklist (Microsoft account signed in, cross-platform play on, PS Plus active, accepted bot friend request) now comes first for "can't join" reports.

---

## 14. Managing the server remotely without opening anything

**Need:** check logs and add players while away from home, without exposing SSH to the internet.

**Approach:** a private mesh VPN with a subnet router at home, and a mobile SSH client using its **own Ed25519 key**. Password login stays disabled; only the phone's public key was added to `authorized_keys`. Nothing new was installed on the game VM, so its isolation rules are unchanged.

**Small fixes along the way:**

| Symptom | Cause | Fix |
|---|---|---|
| `no configuration file provided: not found` | New sessions start in `~`, not the stack folder | `echo 'cd /opt/minecraft' >> ~/.bashrc` |
| Password rejected in the SSH app | Key-only SSH (by design) | Generate a key in the app; add its public key |

---

## 15. Consoles timed out joining while the server looked healthy

**Symptom:** the bot handed players over and the server logged the connection attempt, then the client failed with a connection timeout.

**Root cause:** Docker's default bridge network adds its own NAT layer. NetherNet is WebRTC-style: the server advertises an address and UDP port for the gameplay connection, and behind the bridge those didn't match what the client could actually reach.

**Fix:** `network_mode: host` for the server container, with the VM's own firewall (UFW) opening exactly the game ports. I also confirmed the edge NAT rule for 19132 covered **TCP and UDP**, because NetherNet signals over TCP.

**Lesson:** "the container is up" and "the protocol works through the container's network" are different checks. Packet captures on the VM showed the handshake arriving and the gameplay connection never completing.

---

## 16. Following a changing public IP automatically

**Need:** the server advertises the home public IP in two places (`server-udp-ports` and the bot's `ip:`). If the ISP changes it, joins break until someone notices.

**Approach:** `server/ipwatch.sh`, run from cron every 5 minutes. It asks **two independent lookup services** and only acts when both return the same valid public address (private, CGNAT, loopback and link-local results are rejected). That way a bad lookup or a moment of the WAN holding a private lease can never rewrite the config. On a real change it backs up both files, rewrites them, warns players in-game and restarts both containers 30 seconds later. Tested against mocked lookups before going live.

---

## 17. Off-VM backups: the NFS mount just hung

**Symptom:** `mount -a` for the NAS share never returned, and a TCP test to the NAS's port 2049 from the VM timed out. The same test from the Proxmox host succeeded.

**Root cause:** the VM's hypervisor firewall blocks every private range outbound, and the single NFS exception had never been applied to the live rules. The segmentation was doing exactly its job.

**Fix:** added `OUT ACCEPT -dest <NAS> -p tcp -dport 2049` **above** the `OUT DROP` lines (first match wins), after backing up the rules file. Players stayed connected throughout.

**Two follow-ups on the NAS side:**

| Symptom | Cause | Fix |
|---|---|---|
| `Protocol not supported` for NFS 4.2 / 4.1 | The NAS's maximum NFS version was set lower | Pin `vers=4.0` in fstab (or raise the NAS's maximum) |
| `No such file or directory` from the server | The share had no NFS permission for the VM's IP yet | Added a Read/Write rule for that one IP only |

**Hardening the mount:** the fstab line uses `nofail` so the VM still boots if the NAS is off, and the backup scripts fall back to a local folder (with a warning) if the mount is missing, rather than silently filling the VM's disk under `/mnt`. The share's recycle bin is off so retention pruning really frees space, and a quota caps it.

**Lesson:** when a default-deny design breaks something, test from both sides of the boundary. "Host can reach it, guest can't" pointed straight at the hypervisor firewall.
