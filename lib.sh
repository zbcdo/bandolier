#!/usr/bin/env bash
# lib.sh — shared helpers, prepended to every roles/*.sh by bandolier.sh.
# Roles run as root (via sudo) on the target; the environment arrives on stdin before this file.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew)

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Roles must run as root (bandolier.sh wraps them in sudo)."
command -v apt-get >/dev/null || die "This role targets Debian/Ubuntu (apt)."

# Debian/Ubuntu release codename (bookworm, trixie, jammy, noble, ...)
os_codename() {
  # shellcheck disable=SC1091
  ( . /etc/os-release && printf '%s' "${VERSION_CODENAME:-}" )
}

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
