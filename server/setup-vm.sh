#!/usr/bin/env bash
# One-time VM prep for a fresh Debian VM.
# Run:  sudo LAN_SUBNET=192.168.1.0/24 bash setup-vm.sh
# - Installs Docker (official repo), jq, qemu-guest-agent, automatic security updates
# - Firewall inside the VM: deny all inbound except SSH from your LAN
# - SSH: key-only login, no root login
set -euo pipefail

LAN_SUBNET="${LAN_SUBNET:-192.168.1.0/24}"   # override: LAN_SUBNET=192.168.10.0/24 sudo -E bash setup-vm.sh
ADMIN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
INSTALL_DIR=/opt/minecraft

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

echo "==> Packages"
apt-get update
apt-get install -y ca-certificates curl gnupg jq ufw qemu-guest-agent unattended-upgrades nfs-common
systemctl enable --now qemu-guest-agent || true
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Clean shutdowns = no lost progress. When the VM shuts down or reboots, give the
# Minecraft container time to save the world instead of being killed after 15s.
#  - shutdown-timeout: Docker waits up to 90s for containers to stop
#  - TimeoutStopSec:   systemd waits up to 150s for Docker itself
#  - log rotation:     container logs can't fill the disk
cat > /etc/docker/daemon.json <<'EOF'
{
  "shutdown-timeout": 90,
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
EOF
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/10-graceful-stop.conf <<'EOF'
[Service]
TimeoutStopSec=150
EOF
systemctl daemon-reload
systemctl enable docker
systemctl restart docker
[ "$ADMIN_USER" != "root" ] && usermod -aG docker "$ADMIN_USER"

echo "==> Firewall (inbound: SSH from $LAN_SUBNET only)"
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$LAN_SUBNET" to any port 22 proto tcp
# Broadcaster uses host networking, so UFW applies to it (Docker-published game ports bypass UFW)
ufw allow 19150:19159/udp
ufw --force enable

echo "==> SSH hardening"
if [ -s "/home/$ADMIN_USER/.ssh/authorized_keys" ] || [ -s /root/.ssh/authorized_keys ]; then
  cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  systemctl reload ssh || systemctl reload sshd
  echo "    Password login disabled (key found)."
else
  echo "    SKIPPED: no SSH key in authorized_keys yet. Add one with ssh-copy-id, then re-run."
fi

echo "==> Server folder at $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/{data,xbox,backups}
chown -R 1000:1000 "$INSTALL_DIR"/data
[ "$ADMIN_USER" != "root" ] && chown "$ADMIN_USER":"$ADMIN_USER" "$INSTALL_DIR" "$INSTALL_DIR"/backups
# The broadcaster image runs as UID 1001, not 1000; it must own its config folder
chown -R 1001:1001 "$INSTALL_DIR"/xbox

echo
echo "Done. Next: copy the kit files into $INSTALL_DIR, log out and back in (for the docker group),"
echo "then continue with the build guide."
