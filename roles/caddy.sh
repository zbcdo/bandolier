# roles/caddy.sh — Caddy web server from the official repo, automatic HTTPS.
# Writes one site file per domain under /etc/caddy/sites/; re-run with another CADDY_DOMAIN to add a site.
#
#   CADDY_DOMAIN    "example.com www.example.com"   (blank = serve plain HTTP on :80, no TLS)
#   CADDY_EMAIL     ACME account email for Let's Encrypt expiry notices (optional)
#   CADDY_UPSTREAM  reverse-proxy target, e.g. 127.0.0.1:3000 or unix//run/app.sock (optional)
#   CADDY_ROOT      static root when not proxying (default /var/www/<first domain>)
#   CADDY_PHP       yes = serve PHP via php-fpm socket for PHP_VERSION (needs the php role)

CADDY_DOMAIN="${CADDY_DOMAIN:-}"
CADDY_EMAIL="${CADDY_EMAIL:-}"
CADDY_UPSTREAM="${CADDY_UPSTREAM:-}"
CADDY_PHP="${CADDY_PHP:-no}"
PHP_VERSION="${PHP_VERSION:-8.5}"

read -r FIRST_DOMAIN _ <<< "$CADDY_DOMAIN"
if [[ -z "$FIRST_DOMAIN" ]]; then
  warn "CADDY_DOMAIN is blank — serving plain HTTP on :80 without TLS. Set a domain for automatic HTTPS."
  SITE_ADDR=":80"; SITE_NAME="default"
else
  for d in $CADDY_DOMAIN; do
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
      || die "CADDY_DOMAIN entry doesn't look like a hostname: '$d'"
  done
  SITE_ADDR="$CADDY_DOMAIN"; SITE_NAME="$FIRST_DOMAIN"
fi
CADDY_ROOT="${CADDY_ROOT:-/var/www/$SITE_NAME}"
[[ -z "$CADDY_EMAIL" || "$CADDY_EMAIL" == *@*.* ]] || die "CADDY_EMAIL doesn't look like an email: '$CADDY_EMAIL'"
[[ "$CADDY_UPSTREAM" != *[[:space:]\"\{\}]* ]] || die "CADDY_UPSTREAM contains odd characters: '$CADDY_UPSTREAM'"

# ───────────────────────── 1. Official apt repository ─────────────────────────
log "Adding the Caddy apt repository"
apt-get update -q
apt-get "${APT_OPTS[@]}" install debian-keyring debian-archive-keyring apt-transport-https curl gnupg
KEYRING=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
if [[ ! -s "$KEYRING" ]]; then
  curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --batch --yes -o "$KEYRING"
fi
LIST=/etc/apt/sources.list.d/caddy-stable.list
if [[ ! -s "$LIST" ]]; then
  curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > "$LIST"
  apt-get update -q
fi

# ───────────────────────── 2. Install ─────────────────────────
log "Installing caddy"
apt-get "${APT_OPTS[@]}" install caddy

# ───────────────────────── 3. Global Caddyfile + site file ─────────────────────────
log "Writing /etc/caddy/Caddyfile and site '$SITE_NAME'"
install -d -m 755 /etc/caddy/sites /var/log/caddy
chown caddy:caddy /var/log/caddy
cat > /etc/caddy/Caddyfile <<CF
# Managed by bandolier (roles/caddy.sh). Per-site config lives in /etc/caddy/sites/*.caddy
{
$( [[ -n "$CADDY_EMAIL" ]] && printf '\temail %s\n' "$CADDY_EMAIL" )
	admin localhost:2019
}

import /etc/caddy/sites/*.caddy
CF

SITE_FILE="/etc/caddy/sites/${SITE_NAME}.caddy"
{
  printf '%s {\n' "$SITE_ADDR"
  printf '\tencode zstd gzip\n'
  printf '\tlog {\n\t\toutput file /var/log/caddy/%s.log {\n\t\t\troll_size 10MiB\n\t\t\troll_keep 5\n\t\t}\n\t}\n' "$SITE_NAME"
  printf '\theader {\n\t\tX-Content-Type-Options nosniff\n\t\tX-Frame-Options SAMEORIGIN\n\t\tReferrer-Policy strict-origin-when-cross-origin\n\t\t-Server\n\t}\n'
  if [[ -n "$CADDY_UPSTREAM" ]]; then
    printf '\treverse_proxy %s\n' "$CADDY_UPSTREAM"
  else
    printf '\troot * %s\n' "$CADDY_ROOT"
    if [[ "$CADDY_PHP" == yes ]]; then
      printf '\tphp_fastcgi unix//run/php/php%s-fpm.sock\n' "$PHP_VERSION"
    fi
    printf '\tfile_server\n'
  fi
  printf '}\n'
} > "$SITE_FILE"

if [[ -z "$CADDY_UPSTREAM" ]]; then
  install -d -m 755 -o www-data -g www-data "$CADDY_ROOT"
  if [[ -z "$(ls -A "$CADDY_ROOT")" ]]; then
    cat > "$CADDY_ROOT/index.html" <<HTML
<!doctype html><meta charset="utf-8"><title>${SITE_NAME}</title>
<h1>${SITE_NAME}</h1><p>Caddy is up. Replace the contents of ${CADDY_ROOT}.</p>
HTML
    chown www-data:www-data "$CADDY_ROOT/index.html"
  fi
  if [[ "$CADDY_PHP" == yes && ! -S "/run/php/php${PHP_VERSION}-fpm.sock" ]]; then
    warn "CADDY_PHP=yes but /run/php/php${PHP_VERSION}-fpm.sock doesn't exist yet. Run the php role; Caddy will return 502 until then."
  fi
fi

for f in /etc/caddy/Caddyfile "$SITE_FILE"; do caddy fmt --overwrite "$f" >/dev/null 2>&1 || true; done
# Validate AS the service user: validate opens log files, and doing it as root would leave
# root-owned logs that caddy.service then cannot write. Fix ownership first for the same reason.
chown -R caddy:caddy /var/log/caddy
runuser -u caddy -- caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null \
  || die "Caddy config invalid — not reloading. Inspect /etc/caddy/Caddyfile and $SITE_FILE"

# ───────────────────────── 4. Firewall ─────────────────────────
if command -v ufw >/dev/null; then
  log "Allowing 80/tcp, 443/tcp, 443/udp (HTTP/3) in ufw"
  ufw allow 80/tcp  comment 'HTTP (caddy)'  >/dev/null
  ufw allow 443/tcp comment 'HTTPS (caddy)' >/dev/null
  ufw allow 443/udp comment 'HTTP/3 (caddy)' >/dev/null
fi

# ───────────────────────── 5. Start / reload ─────────────────────────
systemctl enable --now caddy >/dev/null
systemctl reload caddy || systemctl restart caddy
sleep 1
systemctl is-active --quiet caddy || die "caddy is not running. Check: journalctl -u caddy -n 50"

# ───────────────────────── Summary ─────────────────────────
log "Done."
cat <<EOS

  Caddy:       $(caddy version 2>/dev/null | awk '{print $1}')
  Site:        $SITE_ADDR  ->  $SITE_FILE
  Serving:     $( [[ -n "$CADDY_UPSTREAM" ]] && echo "reverse_proxy $CADDY_UPSTREAM" || echo "files from $CADDY_ROOT$( [[ "$CADDY_PHP" == yes ]] && echo " + php-fpm $PHP_VERSION" )" )
  TLS:         $( [[ -n "$FIRST_DOMAIN" ]] && echo "automatic (Let's Encrypt/ZeroSSL)${CADDY_EMAIL:+, account $CADDY_EMAIL}" || echo "none (no domain)" )
  Logs:        /var/log/caddy/${SITE_NAME}.log  |  journalctl -u caddy
  Firewall:    80/tcp 443/tcp 443/udp open
$( [[ -n "$FIRST_DOMAIN" ]] && printf '\n  >>> Point DNS A/AAAA records for %s at this server before the first visit;\n      Caddy obtains the certificate on demand.\n' "$CADDY_DOMAIN" )
EOS
