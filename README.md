# bandolier

Bash scripts to harden a fresh Debian/Ubuntu server and layer services on top.
Run everything **from your own machine**; nothing is copied to the server and no git is needed there.

## Layout

```
bandolier.sh    # local runner: streams scripts over SSH
bootstrap.sh    # baseline hardening, runs once as root
lib.sh          # shared helpers, prepended to every role
roles/          # one script per service: postgres.sh, php.sh, caddy.sh ...
.env.example    # copy to .env (gitignored) and fill in
```

## First run on a new box

```bash
cp .env.example .env && chmod 600 .env   # set NEW_USER, keys, ports...
./bandolier.sh bootstrap 203.0.113.10    # connects as root on port 22
```

Managing several servers? Keep one config per box and pick it with `--env`
(`.env.*` is gitignored, `.env.example` is not):

```bash
cp .env.example .env.webserver
./bandolier.sh --env .env.webserver bootstrap 203.0.113.10
./bandolier.sh --env .env.webserver role 203.0.113.10 caddy
```

You'll be prompted (hidden input) for a sudo password if `NEW_USER_PASSWORD` is blank in `.env`.
When it finishes, **open a second terminal and confirm** `ssh -p <SSH_PORT> <NEW_USER>@host` works
before closing the first — root login and password auth are now off.

What bootstrap does: full upgrade (maintainer configs on conflict), unattended upgrades with
auto-reboot, admin user + sudo + your SSH key, key-only SSH on your chosen port with root disabled,
ufw (deny in, allow out, SSH rate-limited, 80/443 open), fail2ban on sshd, sysctl hardening,
base tools (`htop`/`btop` by RAM, `nano`, `screen`, `tmux`, `git`, ...).

## Adding services

```bash
./bandolier.sh role 203.0.113.10 postgres
./bandolier.sh role 203.0.113.10 php caddy
```

Roles connect as `NEW_USER` on `SSH_PORT` and run under `sudo`. Each role is idempotent.

### postgres

Installs PostgreSQL from the official PGDG repo. Pick the major with `PG_VERSION` (`16`, `17` or `18`)
and the port with `PG_PORT` (default `5432`). The server listens on `127.0.0.1`/`::1` only and the
port is **never opened in ufw**: the only way in from outside is an SSH tunnel.

A superuser role `PG_ADMIN_USER` (default: `NEW_USER`) is created with `PG_ADMIN_PASSWORD`
(prompted, hidden, if blank in `.env`; leave the prompt empty to skip the role). Re-running the role
updates the password and rewrites `/etc/postgresql/<ver>/main/conf.d/10-bandolier.conf`.

Connect a desktop client (pgAdmin, DBeaver, TablePlus, DataGrip, ...) through a tunnel:

```bash
ssh -p <SSH_PORT> -N -L 5432:127.0.0.1:<PG_PORT> <NEW_USER>@host   # keep running
# client: host=localhost port=5432 user=<PG_ADMIN_USER> db=postgres
```

Most clients have a built-in SSH tab: point it at `<NEW_USER>@host:<SSH_PORT>` with your key and set
the database host to `127.0.0.1:<PG_PORT>`.

### caddy

Installs Caddy from its official repo with automatic HTTPS. `CADDY_DOMAIN` takes one or more
hostnames (`"example.com www.example.com"`); point their A/AAAA records at the server first.
Leave it blank to serve plain HTTP on `:80` without TLS. Set `CADDY_EMAIL` for ACME notices.

What the site serves:

- `CADDY_UPSTREAM=127.0.0.1:3000` (or `unix//run/app.sock`) → reverse proxy.
- Otherwise static files from `CADDY_ROOT` (default `/var/www/<domain>`, seeded with a placeholder
  `index.html` if empty). Add `CADDY_PHP=yes` to route `.php` through php-fpm for `PHP_VERSION`.

Each run writes `/etc/caddy/sites/<domain>.caddy`, so running again with a different `CADDY_DOMAIN`
adds a second site instead of replacing the first. The config is validated before Caddy is
reloaded, and 80/tcp, 443/tcp and 443/udp are opened in ufw.

## How secrets are handled

- `.env` is gitignored; the repo contains only logic and can be public.
- The password and keys are sent as the first lines of the SSH session's **stdin** — never as
  command-line arguments — so they don't appear in `ps`, shell history, or logs on either side.
- On the server the password is applied with `chpasswd` reading stdin, then unset.
- Leave `NEW_USER_PASSWORD` blank to be prompted every time instead of storing it.

## Provider handling

`PROVIDER=auto` (default) detects DigitalOcean from DMI and reuses the SSH key DO injected into
root's `authorized_keys`. Anywhere else, the key comes from `SSH_PUBKEY_FILE_LOCAL`
(default `~/.ssh/id_ed25519.pub`) or `SSH_PUBKEY`. An explicit key always wins.