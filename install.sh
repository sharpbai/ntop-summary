#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINDIR="${BINDIR:-$PREFIX/bin}"
CONFIG="/etc/ntop-tools.conf"
DATADIR="/var/lib/ntop-tools"
DB="$DATADIR/traffic.db"
UNITDIR="/etc/systemd/system"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log(){ printf '[ntop-summary] %s\n' "$*"; }
die(){ printf '[ntop-summary] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this installer as root."
command -v python3 >/dev/null || die "python3 is required."
command -v systemctl >/dev/null || die "systemd is required."


install_ntopng() {
  if command -v ntopng >/dev/null 2>&1; then
    log "ntopng already installed: $(ntopng --version 2>/dev/null | head -1 || true)"
    return
  fi

  [[ -r /etc/os-release ]] || die "Cannot detect Linux distribution (/etc/os-release missing)."
  . /etc/os-release

  case "${ID:-}" in
    ubuntu)
      case "${VERSION_ID:-}" in
        22.04|24.04)
          repo_url="https://packages.ntop.org/apt-stable/$VERSION_ID/all/apt-ntop-stable.deb"
          ;;
        *)
          die "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Install ntopng manually, then rerun this installer."
          ;;
      esac
      ;;
    debian)
      case "${VERSION_ID:-}" in
        11)
          repo_url="https://packages.ntop.org/apt-stable/bullseye/all/apt-ntop-stable.deb"
          ;;
        12)
          repo_url="https://packages.ntop.org/apt-stable/bookworm/all/apt-ntop-stable.deb"
          ;;
        13)
          repo_url="https://packages.ntop.org/apt-stable/trixie/all/apt-ntop-stable.deb"
          ;;
        *)
          die "Unsupported Debian version: ${VERSION_ID:-unknown}. Install ntopng manually, then rerun this installer."
          ;;
      esac
      ;;
    *)
      die "Automatic ntopng installation currently supports Ubuntu 22.04/24.04 and Debian 11/12/13. Detected: ${PRETTY_NAME:-$ID}"
      ;;
  esac

  command -v apt-get >/dev/null || die "apt-get is required for automatic ntopng installation."

  log "ntopng not found. Installing ntop official stable repository for ${PRETTY_NAME:-$ID}..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates wget gnupg

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  repo_pkg="$tmpdir/apt-ntop-stable.deb"
  wget -qO "$repo_pkg" "$repo_url" || die "Failed to download ntop repository package: $repo_url"
  apt-get install -y "$repo_pkg"
  apt-get update

  # Ubuntu/Debian may already have the old distro ntopng-data package.
  # Remove it first if it conflicts with the current ntop official package.
  if ! apt-get install -y ntopng; then
    log "Initial ntopng install failed; removing legacy ntopng-data package and retrying."
    apt-get remove -y ntopng-data 2>/dev/null || true
    apt-get -f install -y
    apt-get install -y ntopng
  fi

  command -v ntopng >/dev/null || die "ntopng installation did not produce an ntopng executable."
  log "Installed $(ntopng --version 2>/dev/null | head -1 || echo ntopng)."

  systemctl enable ntopng >/dev/null 2>&1 || true

  # Do not invent an interface on multi-NIC hosts. If ntopng already has an
  # interface configured, start it; otherwise leave it installed and tell the
  # operator to select the desired interface in /etc/ntopng/ntopng.conf.
  if grep -RqsE '^[[:space:]]*(-i|--interface)=' /etc/ntopng/ntopng.conf /etc/ntopng/ntopng.conf.d 2>/dev/null; then
    systemctl restart ntopng
    log "ntopng started with its existing interface configuration."
  else
    log "ntopng installed, but no capture interface is configured."
    log "Set -i=<interface> in /etc/ntopng/ntopng.conf, then run: systemctl enable --now ntopng"
  fi
}

install_ntopng

for f in ntop-summary ntop-collector ntop-tools.conf.example systemd/ntop-collector.service systemd/ntop-collector.timer; do
  [[ -f "$SCRIPT_DIR/$f" ]] || die "Missing repository file: $f"
done

install -d -m 0755 "$BINDIR"
install -d -m 0700 "$DATADIR"
install -m 0755 "$SCRIPT_DIR/ntop-summary" "$BINDIR/ntop-summary"
install -m 0755 "$SCRIPT_DIR/ntop-collector" "$BINDIR/ntop-collector"

if [[ ! -f "$CONFIG" ]]; then
  install -m 0600 "$SCRIPT_DIR/ntop-tools.conf.example" "$CONFIG"
  log "Created $CONFIG. Set NTOP_PASS before collection starts."
else
  chmod 0600 "$CONFIG"
  log "Keeping existing $CONFIG."
fi

# Respect an existing custom DB path from the config.
configured_db="$(awk -F= '$1=="NTOP_DB"{sub(/^[^=]*=/,""); print; exit}' "$CONFIG" 2>/dev/null || true)"
[[ -n "$configured_db" ]] && DB="$configured_db"
install -d -m 0700 "$(dirname "$DB")"

# Locate databases made by the pre-repository/manual version. The original
# deployment used /var/lib/ntop-tools/traffic.db, but also inspect common
# nearby locations and the configured path.
candidates=(
  "$DB"
  "/var/lib/ntop-tools/traffic.db"
  "/root/traffic.db"
  "/root/ntop-tools/traffic.db"
  "/usr/local/share/ntop-tools/traffic.db"
)

is_ntop_db(){
  local db="$1"
  [[ -f "$db" ]] || return 1
  python3 - "$db" <<'PY'
import sqlite3, sys
try:
    con=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro", uri=True)
    tables={r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if "traffic" not in tables:
        raise SystemExit(1)
    cols={r[1] for r in con.execute("PRAGMA table_info(traffic)")}
    required={"bucket","src_ip","dst_ip","dst_port","l4","l7","bytes","new_flows"}
    raise SystemExit(0 if required <= cols else 1)
except Exception:
    raise SystemExit(1)
PY
}

legacy=""
for c in "${candidates[@]}"; do
  if is_ntop_db "$c"; then
    legacy="$c"
    break
  fi
done

# Broader bounded search only when no known location matched.
if [[ -z "$legacy" ]]; then
  while IFS= read -r c; do
    if is_ntop_db "$c"; then legacy="$c"; break; fi
  done < <(find /var/lib /root /home -xdev -type f \( -name 'traffic.db' -o -name 'ntop*.db' \) -size -20G 2>/dev/null | head -100)
fi

if [[ -n "$legacy" ]]; then
  log "Detected existing ntop-summary database: $legacy"
  if [[ "$legacy" != "$DB" ]]; then
    if [[ -e "$DB" ]]; then
      stamp="$(date +%Y%m%d-%H%M%S)"
      cp -a "$DB" "$DB.backup-$stamp"
      log "Backed up destination DB to $DB.backup-$stamp"
    fi
    # SQLite online backup handles WAL-backed databases safely.
    python3 - "$legacy" "$DB" <<'PY'
import sqlite3, sys
src=sqlite3.connect(sys.argv[1])
dst=sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
src.close(); dst.close()
PY
    log "Imported legacy database into $DB"
  else
    log "Existing database is already at the configured location; preserving it in place."
  fi
else
  log "No legacy ntop-summary database found; a new database will be created on first collection."
fi

install -m 0644 "$SCRIPT_DIR/systemd/ntop-collector.service" "$UNITDIR/ntop-collector.service"
install -m 0644 "$SCRIPT_DIR/systemd/ntop-collector.timer" "$UNITDIR/ntop-collector.timer"
systemctl daemon-reload

# Build/upgrade schema and daily rollups before enabling periodic collection.
log "Initializing schema and building daily rollups..."
"$BINDIR/ntop-collector" --rollup

systemctl enable --now ntop-collector.timer >/dev/null
log "Enabled ntop-collector.timer."

printf '\n'
"$BINDIR/ntop-collector" --status
printf '\n'
log "Installation complete."
log "Edit $CONFIG if NTOP_PASS or API settings still need configuration."
log "Useful commands: ntop-summary today | ntop-summary month | ntop-summary 30d"
