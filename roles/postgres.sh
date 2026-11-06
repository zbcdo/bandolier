# roles/postgres.sh — PostgreSQL from the official PGDG repo, bound to localhost only.
# Reach it from a desktop client through an SSH tunnel; the port is never opened in ufw.
#
#   PG_VERSION        16 | 17 | 18            (default 16)
#   PG_PORT           TCP port on the server  (default 5432)
#   PG_ADMIN_USER     role with a password for the desktop client (default: NEW_USER)
#   PG_ADMIN_PASSWORD prompted by bandolier.sh when blank; blank at this point = skip role creation
#   PG_MAX_CONNECTIONS override for the RAM-derived default (30 below 2GB, else 100)

PG_VERSION="${PG_VERSION:-16}"
PG_PORT="${PG_PORT:-5432}"
PG_ADMIN_USER="${PG_ADMIN_USER:-${NEW_USER:-admin}}"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-}"
SSH_PORT="${SSH_PORT:-22}"

case "$PG_VERSION" in
  16|17|18) ;;
  *) die "PG_VERSION must be 16, 17 or 18 (got '$PG_VERSION')." ;;
esac
is_port "$PG_PORT" || die "PG_PORT must be 1-65535 (got '$PG_PORT')."
[[ "$PG_ADMIN_USER" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] \
  || die "PG_ADMIN_USER must be a simple lowercase identifier (got '$PG_ADMIN_USER')."

CODENAME="$(os_codename)"
[[ -n "$CODENAME" ]] || die "Could not read VERSION_CODENAME from /etc/os-release."

# ───────────────────────── 1. PGDG apt repository ─────────────────────────
log "Adding the PostgreSQL (PGDG) apt repository for $CODENAME"
apt-get update -q
apt-get "${APT_OPTS[@]}" install curl ca-certificates gnupg
PGDG_KEY=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
install -d -m 755 "$(dirname "$PGDG_KEY")"
[[ -s "$PGDG_KEY" ]] || curl -fsSL -o "$PGDG_KEY" https://www.postgresql.org/media/keys/ACCC4CF8.asc
PGDG_LIST=/etc/apt/sources.list.d/pgdg.list
PGDG_LINE="deb [signed-by=$PGDG_KEY] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main"
if [[ ! -f "$PGDG_LIST" ]] || ! grep -qxF "$PGDG_LINE" "$PGDG_LIST"; then
  printf '%s\n' "$PGDG_LINE" > "$PGDG_LIST"
  apt-get update -q
fi

# ───────────────────────── 2. Install ─────────────────────────
log "Installing postgresql-$PG_VERSION"
apt-get "${APT_OPTS[@]}" install "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION"

# Refuse to steal a port from another cluster on this box (e.g. an older major still running).
while read -r ver name port _; do
  [[ "$ver" == "$PG_VERSION" && "$name" == main ]] && continue
  [[ "$port" == "$PG_PORT" ]] && die "Cluster $ver/$name already uses port $PG_PORT. Pick another PG_PORT or drop that cluster."
done < <(pg_lsclusters --no-header 2>/dev/null || true)

# ───────────────────────── 3. Configure: localhost only, chosen port ─────────────────────────
CONF_DIR="/etc/postgresql/$PG_VERSION/main"
[[ -d "$CONF_DIR" ]] || die "Expected cluster config at $CONF_DIR — did the install create the 'main' cluster?"
log "Binding cluster $PG_VERSION/main to 127.0.0.1/::1 port $PG_PORT"
# Debian's postgresql.conf ends with include_dir = 'conf.d'; files there override it.
install -d -m 755 -o postgres -g postgres "$CONF_DIR/conf.d"
# Memory-aware sizing. postgresql-common's defaults assume a dedicated multi-GB host
# (effective_cache_size ends up at 5GB on a 512MB droplet). Scale from MemTotal instead.
MEM_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
# Under 2GB the box is shared with the app and the proxy: 1/8 of RAM, else the usual 1/4.
if (( MEM_MB < 2048 )); then PG_SHARED_BUFFERS_MB=$(( MEM_MB / 8 )); else PG_SHARED_BUFFERS_MB=$(( MEM_MB / 4 )); fi
(( PG_SHARED_BUFFERS_MB < 64 )) && PG_SHARED_BUFFERS_MB=64
PG_CACHE_MB=$(( MEM_MB / 2 ))
PG_MAINT_MB=$(( MEM_MB / 16 ));                (( PG_MAINT_MB < 32 )) && PG_MAINT_MB=32; (( PG_MAINT_MB > 1024 )) && PG_MAINT_MB=1024
if (( MEM_MB < 2048 )); then PG_MAX_CONN=30; PG_WORK_MEM_MB=2; else PG_MAX_CONN=100; PG_WORK_MEM_MB=4; fi
PG_MAX_CONN="${PG_MAX_CONNECTIONS:-$PG_MAX_CONN}"
cat > "$CONF_DIR/conf.d/10-bandolier.conf" <<CONF
# Managed by bandolier (roles/postgres.sh). Re-running the role rewrites this file.
listen_addresses = 'localhost'
port = ${PG_PORT}
password_encryption = 'scram-sha-256'

# Sized for ${MEM_MB} MB of RAM on this host (shared with the app and the proxy).
shared_buffers = ${PG_SHARED_BUFFERS_MB}MB
effective_cache_size = ${PG_CACHE_MB}MB
maintenance_work_mem = ${PG_MAINT_MB}MB
work_mem = ${PG_WORK_MEM_MB}MB
max_connections = ${PG_MAX_CONN}
CONF
chown postgres:postgres "$CONF_DIR/conf.d/10-bandolier.conf"
chmod 640 "$CONF_DIR/conf.d/10-bandolier.conf"

# Debian's stock pg_hba.conf already allows only local (peer) and 127.0.0.1/::1 (scram-sha-256).
# Make sure nobody widened it: there must be no 'host' line for a non-loopback network.
if grep -E '^\s*host(ssl|nossl)?\s' "$CONF_DIR/pg_hba.conf" | grep -vE '127\.0\.0\.1/32|::1/128|\bsamehost\b' | grep -q .; then
  warn "pg_hba.conf has non-loopback 'host' rules. They are unreachable (listen_addresses=localhost) but review them:"
  grep -nE '^\s*host(ssl|nossl)?\s' "$CONF_DIR/pg_hba.conf" >&2 || true
fi

systemctl enable --now "postgresql@${PG_VERSION}-main" >/dev/null
systemctl restart "postgresql@${PG_VERSION}-main"
for _ in $(seq 1 30); do
  pg_isready -q -h 127.0.0.1 -p "$PG_PORT" && break
  sleep 1
done
pg_isready -q -h 127.0.0.1 -p "$PG_PORT" || die "PostgreSQL did not come up on 127.0.0.1:$PG_PORT. Check: journalctl -u postgresql@${PG_VERSION}-main"

# ───────────────────────── 4. Admin role for the desktop client ─────────────────────────
ADMIN_STATUS="none (PG_ADMIN_PASSWORD was blank)"
if [[ -n "$PG_ADMIN_PASSWORD" ]]; then
  ADMIN_STATUS="$PG_ADMIN_USER (superuser, scram-sha-256)"
  log "Creating/updating admin role '$PG_ADMIN_USER' (superuser, password auth over the tunnel)"
  # Password reaches psql through the environment and \getenv — never on a command line or in the log.
  PG_ADMIN_USER="$PG_ADMIN_USER" PG_ADMIN_PASSWORD="$PG_ADMIN_PASSWORD" \
  sudo --preserve-env=PG_ADMIN_USER,PG_ADMIN_PASSWORD -u postgres \
    psql -X -q -v ON_ERROR_STOP=1 -p "$PG_PORT" -d postgres <<'SQL'
\getenv u PG_ADMIN_USER
\getenv pw PG_ADMIN_PASSWORD
SELECT format('CREATE ROLE %I', :'u') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'u') \gexec
ALTER ROLE :"u" WITH LOGIN SUPERUSER PASSWORD :'pw';
SQL
  unset PG_ADMIN_PASSWORD
else
  warn "PG_ADMIN_PASSWORD is blank — no admin role created. On the box: sudo -u postgres psql"
fi

# ───────────────────────── 5. Firewall sanity ─────────────────────────
# Nothing to open: the port must stay closed. Flag it if someone allowed it earlier.
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qE "^${PG_PORT}(/tcp)?\s+ALLOW"; then
  warn "ufw ALLOWs port $PG_PORT. Remove it: sudo ufw delete allow ${PG_PORT}/tcp"
fi

# ───────────────────────── Summary ─────────────────────────
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "Done."
cat <<EOS

  PostgreSQL:  $PG_VERSION (cluster main), listening on 127.0.0.1 / ::1 port $PG_PORT only
  Config:      $CONF_DIR/conf.d/10-bandolier.conf
  Sizing:      ${MEM_MB} MB RAM -> shared_buffers ${PG_SHARED_BUFFERS_MB}MB, cache ${PG_CACHE_MB}MB, work_mem ${PG_WORK_MEM_MB}MB, max_connections ${PG_MAX_CONN}
  Admin role:  $ADMIN_STATUS
  Firewall:    port $PG_PORT NOT opened — reachable only through an SSH tunnel

  >>> Desktop client (pgAdmin, DBeaver, TablePlus, DataGrip ...):
      1. Open a tunnel from your machine (keep it running):
           ssh -p $SSH_PORT -N -L ${PG_PORT}:127.0.0.1:${PG_PORT} ${NEW_USER:-admin}@${HOST_IP:-<host>}
      2. Connect the client to  host=localhost  port=$PG_PORT  user=$PG_ADMIN_USER  db=postgres
      Most clients can do both at once: set the SSH tab to ${NEW_USER:-admin}@${HOST_IP:-<host>}:$SSH_PORT
      with your key, and the database tab to 127.0.0.1:$PG_PORT.
EOS
