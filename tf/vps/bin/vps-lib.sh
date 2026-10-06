#!/usr/bin/env bash
# Shared helpers for the vps-* scripts. Sourced, not executed.
set -Eeuo pipefail

# Highest vps_config schema these scripts understand (see tf/main.tf -> vps_config).
VPS_SUPPORTED_SCHEMA=1

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[1]:-$0}")")" && pwd)"
VPS_RELEASE_DIR="$(dirname "$SCRIPT_DIR")"
VPS_ROOT=/opt/vps
VPS_ETC=/etc/vps
export VPS_CONFIG="${VPS_CONFIG:-$VPS_ETC/config.json}"
IMDS_BASE="http://169.254.169.254/opc/v2"

log() {
  local name; name="$(basename "$0")"
  echo "[$name] $*"
  logger -t vps -- "$name: $*" 2>/dev/null || true
}

die() { log "ERROR: $*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }

# cfg '.jq.path' -> prints value from the active config ("null" if missing).
cfg() { jq -r "$1" "$VPS_CONFIG"; }

check_schema() {
  local file="${1:-$VPS_CONFIG}" v
  v="$(jq -r '.schema_version // 0' "$file")"
  [[ "$v" == "$VPS_SUPPORTED_SCHEMA" ]] ||
    die "config schema_version=$v is not supported by this release (supports $VPS_SUPPORTED_SCHEMA). Update scripts or rebuild."
}

# Serialise all vps-* operations. Child processes inherit the held lock.
acquire_lock() {
  [[ "${VPS_LOCK_HELD:-}" == 1 ]] && return 0
  exec 9>/run/vps.lock
  flock -w 900 9 || die "could not acquire /run/vps.lock"
  export VPS_LOCK_HELD=1
}

# write_if_changed DEST MODE < content  -> returns 0 if file changed, 1 if identical.
# Always call inside `if` (or with `|| true`) because of `set -e`.
write_if_changed() {
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  install -D -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  return 0
}

ensure_wg_keys() {
  install -d -m 0700 /etc/wireguard
  if [[ ! -s /etc/wireguard/server.key ]]; then
    (umask 077 && wg genkey >/etc/wireguard/server.key)
    log "generated new WireGuard server key"
  fi
  wg pubkey </etc/wireguard/server.key >/etc/wireguard/server.pub
  chmod 0644 /etc/wireguard/server.pub
}
