#!/usr/bin/env bash
# bootstrap.sh — baseline hardening for a fresh Debian/Ubuntu server.
# Idempotent: safe to re-run. Runs as root. Normally invoked by ./provision.sh,
# which streams it over SSH with the environment prepended — nothing is copied to disk.
#
# Direct use (on the box, as root):
#   SSH_PUBKEY="ssh-ed25519 AAAA..." NEW_USER=me bash bootstrap.sh

set -euo pipefail

# ───────────────────────── Configuration (env overrides) ─────────────────────────
NEW_USER="${NEW_USER:-admin}"
NEW_USER_PASSWORD="${NEW_USER_PASSWORD:-}"   # Plain text, supplied via stdin stream by provision.sh. Blank = no password set.
SUDO_NOPASSWD="${SUDO_NOPASSWD:-no}"         # yes = passwordless sudo. Required if NEW_USER_PASSWORD is blank.
PROVIDER="${PROVIDER:-auto}"                 # auto | digitalocean | other
SSH_PUBKEY="${SSH_PUBKEY:-}"                 # One or more public keys, newline-separated
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"       # Alternative: path on the target to a keys file
SSH_PORT="${SSH_PORT:-22}"
OPEN_PORTS="${OPEN_PORTS:-80/tcp 443/tcp}"   # Extra ufw allows; SSH is always allowed (rate-limited)
TIMEZONE="${TIMEZONE:-UTC}"
AUTO_REBOOT="${AUTO_REBOOT:-true}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"
BASE_PACKAGES="${BASE_PACKAGES:-curl wget git unzip vim nano screen tmux htop ncdu jq ca-certificates gnupg lsb-release apt-transport-https software-properties-common ufw fail2ban unattended-upgrades apt-listchanges}"
BTOP_MIN_MEM_GB="${BTOP_MIN_MEM_GB:-2}"
# ──────────────────────────────────────────────────────────────────────────────────

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew)

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
command -v apt-get >/dev/null || die "This script targets Debian/Ubuntu (apt)."
[[ -n "$NEW_USER_PASSWORD" || "$SUDO_NOPASSWD" == "yes" ]] \
  || die "No NEW_USER_PASSWORD and SUDO_NOPASSWD=no: sudo would be unusable. Set one of them."

# ── Provider detection ──
if [[ "$PROVIDER" == "auto" ]]; then
  vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
  case "$vendor" in
    *DigitalOcean*) PROVIDER=digitalocean ;;
    *)              PROVIDER=other ;;
  esac
fi
log "Provider: $PROVIDER"

# ── SSH key resolution ──
resolve_keys() {
  if [[ -n "$SSH_PUBKEY" ]]; then
    printf '%s\n' "$SSH_PUBKEY"
  elif [[ -n "$SSH_PUBKEY_FILE" && -s "$SSH_PUBKEY_FILE" ]]; then
    cat "$SSH_PUBKEY_FILE"
  elif [[ "$PROVIDER" == "digitalocean" && -s /root/.ssh/authorized_keys ]]; then
    log "DigitalOcean: copying root's injected authorized_keys to $NEW_USER"
    cat /root/.ssh/authorized_keys
  else
    die "No SSH public key. Set SSH_PUBKEY or SSH_PUBKEY_FILE (or PROVIDER=digitalocean to reuse root's keys)."
  fi
}
KEYS="$(resolve_keys)"
grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-|sk-)' <<< "$KEYS" || die "Resolved key material doesn't look like a public key."

# ───────────────────────── 1. System update ─────────────────────────
log "Updating and upgrading packages (maintainer's config versions on conflict)"
apt-get update -q
apt-get "${APT_OPTS[@]}" full-upgrade
apt-get "${APT_OPTS[@]}" autoremove --purge

# ───────────────────────── 2. Base packages ─────────────────────────
log "Installing base packages"
# shellcheck disable=SC2086
apt-get "${APT_OPTS[@]}" install $BASE_PACKAGES

MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if (( MEM_KB >= BTOP_MIN_MEM_GB * 1024 * 1024 )); then
  log "Memory >= ${BTOP_MIN_MEM_GB}GB — installing btop"
  apt-get "${APT_OPTS[@]}" install btop || warn "btop not in this release's repos; skipping."
else
  log "Memory < ${BTOP_MIN_MEM_GB}GB — sticking with htop"
fi

log "Setting timezone to $TIMEZONE"
timedatectl set-timezone "$TIMEZONE" || warn "Could not set timezone."

# ───────────────────────── 3. Unattended upgrades ─────────────────────────
log "Configuring unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<EOF
// Always take the package maintainer's version of config files.
Dpkg::Options { "--force-confdef"; "--force-confnew"; };
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-Time "${AUTO_REBOOT_TIME}";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

# ───────────────────────── 4. Admin user ─────────────────────────
log "Creating user '$NEW_USER' with sudo and SSH keys"
id -u "$NEW_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$NEW_USER"
usermod -aG sudo "$NEW_USER"

if [[ -n "$NEW_USER_PASSWORD" ]]; then
  # Password goes in via stdin — never appears in argv / process list.
  printf '%s:%s\n' "$NEW_USER" "$NEW_USER_PASSWORD" | chpasswd
  unset NEW_USER_PASSWORD
fi

install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/$NEW_USER/.ssh"
AUTH_KEYS="/home/$NEW_USER/.ssh/authorized_keys"
touch "$AUTH_KEYS"
while IFS= read -r key; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  grep -qxF "$key" "$AUTH_KEYS" || printf '%s\n' "$key" >> "$AUTH_KEYS"
done <<< "$KEYS"
chmod 600 "$AUTH_KEYS"
chown "$NEW_USER:$NEW_USER" "$AUTH_KEYS"

if [[ "$SUDO_NOPASSWD" == "yes" ]]; then
  echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$NEW_USER"
  chmod 440 "/etc/sudoers.d/90-$NEW_USER"
  visudo -cf "/etc/sudoers.d/90-$NEW_USER" >/dev/null || die "sudoers file invalid"
else
  rm -f "/etc/sudoers.d/90-$NEW_USER"
fi

# ───────────────────────── 5. SSH hardening ─────────────────────────
log "Hardening sshd (key-only, no root login, port $SSH_PORT)"
mkdir -p /etc/ssh/sshd_config.d
# Must sort BEFORE 50-cloud-init.conf: sshd takes the first value it sees for each option.
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
UsePAM yes
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ${NEW_USER}
EOF
grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config \
  || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
sshd -t || die "sshd config invalid — NOT restarting ssh. Fix /etc/ssh/sshd_config.d/00-hardening.conf"

# ───────────────────────── 6. Firewall ─────────────────────────
log "Configuring ufw"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw limit "${SSH_PORT}/tcp" comment 'SSH (rate-limited)'
for p in $OPEN_PORTS; do ufw allow "$p"; done
ufw logging low
ufw --force enable

# Firewall now permits the new port — apply sshd config. Ubuntu 22.10+ uses socket activation.
if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl restart ssh.socket
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd

# ───────────────────────── 7. fail2ban ─────────────────────────
log "Configuring fail2ban"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# ───────────────────────── 8. sysctl hardening ─────────────────────────
log "Applying sysctl hardening"
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
sysctl --system >/dev/null

# ───────────────────────── Summary ─────────────────────────
log "Done."
cat <<EOF

  Provider:    $PROVIDER
  User:        $NEW_USER (sudo$( [[ "$SUDO_NOPASSWD" == yes ]] && echo ", NOPASSWD" || echo ", password set"))
  SSH:         port $SSH_PORT, key-only, root login disabled
  Firewall:    deny in / allow out; open: ${SSH_PORT}/tcp (limited) $OPEN_PORTS
  fail2ban:    sshd jail, backend=systemd
  Updates:     unattended, maintainer configs, auto-reboot=$AUTO_REBOOT @ $AUTO_REBOOT_TIME

  >>> Verify from a NEW terminal before closing anything:
      ssh -p $SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')
EOF
