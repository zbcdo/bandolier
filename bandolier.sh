#!/usr/bin/env bash
# provision.sh — run from YOUR machine. Streams scripts to a server over SSH.
# Nothing is copied to the server's disk; secrets travel inside the SSH session on stdin,
# never on the command line (so never in `ps`, shell history, or logs).
#
#   ./provision.sh bootstrap <host>                # first run: as root, hardens the box
#   ./provision.sh role <host> postgres [php ...]  # later runs: as NEW_USER via sudo
#
# Reads ./.env (see .env.example). Any var can also be overridden inline:
#   SSH_PORT=2222 ./provision.sh role myhost caddy

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() { sed -n '2,12p' "$0"; exit 1; }
[[ $# -ge 2 ]] || usage
MODE="$1"; HOST="$2"; shift 2

# ── Load .env (does not override vars already set in the environment) ──
if [[ -f .env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"          # strip optional surrounding quotes
    [[ -n "${!key:-}" ]] || export "$key=$val"
  done < .env
fi

# ── Defaults ──
: "${NEW_USER:=admin}"
: "${SSH_PORT:=22}"
: "${SSH_PUBKEY_FILE_LOCAL:=$HOME/.ssh/id_ed25519.pub}"
: "${SUDO_NOPASSWD:=no}"

# Forward these to the remote script if set.
FORWARD_VARS=(NEW_USER NEW_USER_PASSWORD SUDO_NOPASSWD PROVIDER SSH_PUBKEY SSH_PORT OPEN_PORTS
              TIMEZONE AUTO_REBOOT AUTO_REBOOT_TIME BASE_PACKAGES BTOP_MIN_MEM_GB
              PG_VERSION PHP_VERSION CADDY_DOMAIN)

env_block() {
  for v in "${FORWARD_VARS[@]}"; do
    [[ -n "${!v:-}" ]] || continue
    printf 'export %s=%q\n' "$v" "${!v}"
  done
  return 0
}

case "$MODE" in
  bootstrap)
    # Key: explicit SSH_PUBKEY wins; else read the local .pub file; else let the remote
    # fall back to DigitalOcean's injected root keys (PROVIDER=digitalocean/auto).
    if [[ -z "${SSH_PUBKEY:-}" && -s "$SSH_PUBKEY_FILE_LOCAL" ]]; then
      SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE_LOCAL")"
    fi
    if [[ -z "${NEW_USER_PASSWORD:-}" && "$SUDO_NOPASSWD" != "yes" ]]; then
      read -rsp "Password for sudo user '$NEW_USER' (blank = no password, requires SUDO_NOPASSWD=yes): " NEW_USER_PASSWORD; echo
      [[ -n "$NEW_USER_PASSWORD" ]] || { echo "No password given and SUDO_NOPASSWD=no. Aborting."; exit 1; }
      read -rsp "Confirm: " confirm; echo
      [[ "$NEW_USER_PASSWORD" == "$confirm" ]] || { echo "Passwords differ."; exit 1; }
    fi
    echo "==> Bootstrapping $HOST as root (initial port ${BOOTSTRAP_SSH_PORT:-22}) → user $NEW_USER, final port $SSH_PORT"
    { env_block; cat bootstrap.sh; } | ssh -p "${BOOTSTRAP_SSH_PORT:-22}" "root@$HOST" 'bash -s'
    ;;
  role)
    [[ $# -ge 1 ]] || usage
    # Root login is disabled after bootstrap, so roles run as NEW_USER + sudo.
    # `sudo -S` takes the password as the FIRST line of stdin; the script follows it.
    if [[ "$SUDO_NOPASSWD" == "yes" ]]; then
      SUDO_CMD='sudo -n bash -s'; pw_line() { :; }
    else
      if [[ -z "${NEW_USER_PASSWORD:-}" ]]; then
        read -rsp "sudo password for $NEW_USER@$HOST: " NEW_USER_PASSWORD; echo
      fi
      SUDO_CMD='sudo -S -p "" bash -s'; pw_line() { printf '%s\n' "$NEW_USER_PASSWORD"; }
    fi
    # Roles only need the password on the sudo line, never in their environment.
    tmp=(); for v in "${FORWARD_VARS[@]}"; do [[ "$v" == NEW_USER_PASSWORD ]] || tmp+=("$v"); done
    FORWARD_VARS=("${tmp[@]}")
    for role in "$@"; do
      f="roles/$role.sh"
      [[ -f "$f" ]] || { echo "Unknown role: $role (no $f)"; exit 1; }
      echo "==> Applying role '$role' on $HOST as $NEW_USER"
      { pw_line; env_block; cat lib.sh "$f"; } | ssh -p "$SSH_PORT" "$NEW_USER@$HOST" "$SUDO_CMD"
    done
    ;;
  *) usage ;;
esac
