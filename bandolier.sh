#!/usr/bin/env bash
# bandolier.sh — run from YOUR machine. Streams scripts to a server over SSH.
# Nothing is copied to the server's disk; secrets travel inside the SSH session on stdin,
# never on the command line (so never in `ps`, shell history, or logs).
#
#   ./bandolier.sh [--env FILE] bootstrap <host>                # first run: as root, hardens the box
#   ./bandolier.sh [--env FILE] role <host> postgres [php ...]  # later runs: as NEW_USER via sudo
#
# Reads ./.env by default (see .env.example). Keep one file per server and pick it with --env:
#   ./bandolier.sh --env .env.mynewserver bootstrap 203.0.113.10
# Any var can also be overridden inline (an empty value, e.g. CADDY_UPSTREAM=, also overrides):
#   SSH_PORT=2222 ./bandolier.sh role myhost caddy

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() { sed -n '2,14p' "$0"; exit 1; }

# ── Flags ──
ENV_FILE=".env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)    [[ -n "${2:-}" ]] || usage; ENV_FILE="$2"; shift 2 ;;
    --env=*)  ENV_FILE="${1#--env=}"; shift ;;
    -h|--help) usage ;;
    --*)      echo "Unknown flag: $1"; usage ;;
    *)        break ;;
  esac
done
[[ $# -ge 2 ]] || usage
MODE="$1"; HOST="$2"; shift 2

# ── Load env file (does not override vars already set in the environment) ──
if [[ -f "$ENV_FILE" ]]; then
  echo "==> Using config: $ENV_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"          # strip optional surrounding quotes
    [[ -n "${!key+x}" ]] || export "$key=$val"   # set-but-empty counts as an override
  done < "$ENV_FILE"
elif [[ "$ENV_FILE" != ".env" ]]; then
  echo "Config file not found: $ENV_FILE"; exit 1
fi

# ── Defaults ──
: "${NEW_USER:=admin}"
: "${SSH_PORT:=22}"
: "${SSH_PUBKEY_FILE_LOCAL:=$HOME/.ssh/id_ed25519.pub}"
: "${SUDO_NOPASSWD:=no}"

# Forward these to the remote script if set.
FORWARD_VARS=(NEW_USER NEW_USER_PASSWORD SUDO_NOPASSWD PROVIDER SSH_PUBKEY SSH_PORT OPEN_PORTS
              TIMEZONE AUTO_REBOOT AUTO_REBOOT_TIME BASE_PACKAGES BTOP_MIN_MEM_GB SWAP_SIZE
              PG_VERSION PG_PORT PG_ADMIN_USER PG_ADMIN_PASSWORD PG_MAX_CONNECTIONS PHP_VERSION
              CADDY_DOMAIN CADDY_EMAIL CADDY_UPSTREAM CADDY_ROOT CADDY_PHP CADDY_CLOUDFLARE)

env_block() {
  for v in "${FORWARD_VARS[@]}"; do
    [[ -n "${!v:-}" ]] || continue
    printf 'export %s=%q\n' "$v" "${!v}"
  done
  return 0
}

case "$MODE" in
  bootstrap)
    # Keys: SSH_PUBKEY (literal "\n" separates several) PLUS the local .pub file, so the machine
    # running this is never locked out by a key list written for another device. If neither is
    # set, the remote falls back to DigitalOcean's injected root keys (PROVIDER=digitalocean/auto).
    SSH_PUBKEY="${SSH_PUBKEY//\\n/$'\n'}"
    if [[ -s "$SSH_PUBKEY_FILE_LOCAL" ]]; then
      SSH_PUBKEY="${SSH_PUBKEY:+$SSH_PUBKEY$'\n'}$(cat "$SSH_PUBKEY_FILE_LOCAL")"
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
      # Role-specific secrets: prompted here (hidden) when not stored in .env, forwarded on stdin.
      if [[ "$role" == postgres && -z "${PG_ADMIN_PASSWORD:-}" ]]; then
        read -rsp "PostgreSQL password for admin role '${PG_ADMIN_USER:-$NEW_USER}' (blank = skip creating it): " PG_ADMIN_PASSWORD; echo
        if [[ -n "$PG_ADMIN_PASSWORD" ]]; then
          read -rsp "Confirm: " confirm; echo
          [[ "$PG_ADMIN_PASSWORD" == "$confirm" ]] || { echo "Passwords differ."; exit 1; }
        fi
      fi
      echo "==> Applying role '$role' on $HOST as $NEW_USER"
      { pw_line; env_block; cat lib.sh "$f"; } | ssh -p "$SSH_PORT" "$NEW_USER@$HOST" "$SUDO_CMD"
    done
    ;;
  *) usage ;;
esac