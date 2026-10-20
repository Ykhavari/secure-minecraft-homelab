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
