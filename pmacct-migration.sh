#!/usr/bin/env bash
# Guided ntopng -> pmacct migration. Does not change production without --execute.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DB="${DB:-/var/lib/ntop-tools/traffic.db}"
STAGING="${STAGING:-/var/lib/ntop-tools/pmacct-staging.db}"
usage() {
  echo "Usage: sudo ./pmacct-migration.sh check|execute|report|rollup"
  echo "  check   read-only DB audit and service status (default)"
  echo "  execute requires PMACCT_MIGRATION_CONFIRM=YES; backs up and merges"
  echo "  report  read-only daily traffic summary"
  echo "  rollup  rebuilds daily aggregate tables (may take time)"
}
action="${1:-check}"
case "$action" in
  check)
    python3 "$ROOT/pmacct-audit" --production "$DB" --staging "$STAGING"
    systemctl is-active pmacct-summary.service pmacct-interface-watch.service pmacct-import.timer ntop-collector.timer || true
    ;;
  report)
    python3 "$ROOT/pmacct-traffic-report" --db "$DB" --days "${DAYS:-30}" --by "${BY:-day}"
    ;;
  rollup)
    echo "Rebuilding daily rollups in $DB"
    NTOP_DB="$DB" ntop-collector --rollup
    ;;
  execute)
    [[ "$EUID" -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }
    [[ "${PMACCT_MIGRATION_CONFIRM:-}" == YES ]] || { echo "Set PMACCT_MIGRATION_CONFIRM=YES after reviewing check output" >&2; exit 1; }
    [[ -f "$DB" && -f "$STAGING" ]] || { echo "Missing database" >&2; exit 1; }
    if python3 - "$DB" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
try:
    present=c.execute("SELECT 1 FROM metadata WHERE key='pmacct_cutover_bucket'").fetchone()
except sqlite3.Error:
    present=None
sys.exit(0 if present else 1)
PY
    then
      echo "Already migrated; refusing a second migration." >&2
      exit 1
    fi
    systemctl is-active --quiet pmacct-summary.service || { echo "pmacct capture is not active" >&2; exit 1; }
    echo "Stopping both writers; capture remains running."
    systemctl stop ntop-collector.timer pmacct-import.timer
    systemctl stop ntop-collector.service pmacct-import.service || true
    cutoff_args=()
    if [[ -n "${CUTOFF:-}" ]]; then cutoff_args=(--cutoff "$CUTOFF"); fi
    if ! python3 "$ROOT/pmacct-migrate" --production "$DB" --staging "$STAGING" "${cutoff_args[@]}"; then
      echo "Migration failed; restore the old timer after investigating. No automatic rollback of committed data." >&2
      exit 1
    fi
    echo "Database merged. Run ntop-collector --rollup, deploy the production pmacct-import.service, and verify before disabling ntopng."
    echo "The script intentionally does not enable new writers or stop ntopng automatically."
    ;;
  -h|--help) usage ;;
  *) usage; exit 2 ;;
esac
