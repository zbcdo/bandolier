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