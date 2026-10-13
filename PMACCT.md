# pmacct experimental backend

This is an **opt-in development prototype**. The current ntopng collector, timer, and historical database are **not changed**. Do not disable ntopng yet.

## Why a separate importer?

pmacct records directional packet counts, unlike ntopng's client/server active-flow counters. To attribute server-to-client packets to the original client and service port, collect **both IPs and both ports**, not only `src_host,dst_port`.

For packets where source is in the configured client CIDRs and destination is outside, use source IP + destination port. For return packets where destination is in client CIDRs, use destination IP + source port. Traffic with both/neither endpoints in those CIDRs is intentionally skipped and reported, rather than misattributed.

This is an approximation, not a stateful TCP/UDP flow tracker. NAT, tunneling, local-to-local traffic, asymmetric routing, fragmented packets, and multiple internal address realms require validation. L7 and new-flow counts are unavailable and remain blank/zero.

## Test on local-57

```bash
sudo install -d -m 0700 /var/lib/ntop-tools/pmacct
sudo install -m 0644 pmacctd.example.conf /etc/pmacct/ntop-summary.conf
# The CLI -i is mandatory with the tested Debian package:
sudo pmacctd -i tun2socks -f /etc/pmacct/ntop-summary.conf
```

The print plugin creates timestamped JSONL files every 60 seconds. Use a second terminal for importing, after checking actual client CIDRs (examples below are **not** defaults):

```bash
sudo python3 pmacct-collector \
  --input-dir /var/lib/ntop-tools/pmacct \
  --local-networks 192.168.0.0/23,192.168.204.0/22,192.168.252.0/22
```

Default output database is `/var/lib/ntop-tools/pmacct-staging.db`, separate from the existing `traffic.db`. Each filename and SHA-256 is recorded in `pmacct_imports`, so rerunning the importer does not double-count. Changed already-imported files are rejected.

For historical reporting, the staging database can be passed to existing CLI tools via `NTOP_DB=/var/lib/ntop-tools/pmacct-staging.db`, after running the existing rollup generator against the staging DB. Live/interface modes still require ntopng and are **not** yet replaced.

## Pending before production switch

- Verify client CIDR ownership, including IPv6 and the Qingdao public-facing topology.
- Measure complete minute-aligned periods against RX/TX counters; inspect skipped rows.
- Add robust file finalization / atomic rename or a completed-file marker: never import a file still being written.
- Implement a supervised pmacct service with TUN recreation recovery, storage retention, and health monitoring.
- Provide a migration and rollback plan; keep old data intact.


## Parallel systemd deployment (Debian 12 / local-57)

The following units are available:

- `pmacct-summary.service`: packet capture, `tun2socks` (configured in ExecStart)
- `pmacct-interface-watch.service`: checks Linux ifindex every 5 seconds, restarts capture on recreation; also checks output freshness when traffic is rising
- `pmacct-import.timer` and `pmacct-import.service`: import JSONL once per minute

Install:

```bash
sudo install -m 0755 pmacct-collector pmacct-interface-watch /usr/local/bin/
sudo install -m 0644 pmacctd.example.conf /etc/pmacct/ntop-summary.conf
sudo install -m 0644 systemd/pmacct-*.service systemd/pmacct-import.timer /etc/systemd/system/
sudo install -d -m 0700 /var/lib/ntop-tools/pmacct
sudo systemctl daemon-reload
sudo systemctl enable --now pmacct-summary.service pmacct-interface-watch.service pmacct-import.timer
```

Add to `/etc/ntop-tools.conf` (illustrative local-57 values; confirm network ownership):

```ini
PMACCT_LOCAL_NETWORKS=192.168.0.0/16,10.8.24.0/24
PMACCT_EXCLUDE_NETWORKS=10.0.0.0/30
```

`pmacct-collector` now categorizes `attributed`, `ambiguous`, `unclassified`, `excluded`, and `invalid` traffic, and tracks both records and bytes in `pmacct_accounting`. RFC1918/ULA endpoints are *candidates*, not proof of client ownership. When both endpoints are private, attribution is ambiguous and remains unassigned.

By default, JSON files modified in the last 120 seconds are ignored to avoid reading an in-progress file. Use:

```bash
sudo pmacct-collector --input-dir /var/lib/ntop-tools/pmacct --accounting
sudo systemctl status pmacct-summary pmacct-interface-watch pmacct-import.timer
sudo journalctl -u pmacct-import.service -n 30 --no-pager
```

The old ntopng timer remains enabled during this phase. Never write pmacct data into `traffic.db` until migration and reporting compatibility have been verified. Do not delete JSON files unless their import has been confirmed.

**Important limitations:** The watcher uses periodic sysfs checks rather than an event-driven netlink socket. It catches recreated ifindex changes and disappearance/reappearance, but very fast changes between checks can be missed. The health check also depends on regular output and traffic movement. The current importer assigns a 60-second output interval to the minute preceding the file timestamp; it does not yet split non-aligned intervals across minute boundaries. Historical totals are usable for validation, but exact per-minute boundaries need improvement before production cutover.


## Production migration on local-57 (2026-10-13)

After approximately 40 minutes of parallel collection, a common 20-minute interval differed by only ~0.18% between the two backends. Migration proceeded as follows:

1. Stop `ntop-collector.timer` and `pmacct-import.timer`, leaving pmacct capture running.
2. Run `python3 pmacct-migrate`. It creates a SQLite online backup `traffic.db.pre-pmacct-*.bak`, then transactionally replaces only traffic buckets at/after the chosen cutover minute with the staging backend's rows. It also transfers imported-file markers and attribution metadata to prevent duplicate imports.
3. Install the updated `pmacct-collector` and `pmacct-import.service` (with `--db /var/lib/ntop-tools/traffic.db --allow-production`), enable the import timer, and verify a successful new import.
4. Disable and stop `ntop-collector.timer` and `ntopng.service`.

The historical SQLite path remains `/var/lib/ntop-tools/traffic.db`, so `ntop-summary today/month/30d` continue to work. The backup is retained for rollback. JSON files are retained for 48 hours by default and only pruned if their SHA-256 matches a successfully imported file.

**Known compatibility differences:** pmacct packet aggregation does not provide ntopng L7 application classification or new-flow counts. For pmacct-era records, `l7` is empty and `new_flows` is zero. `ntop-summary interface` and `ntop-summary live` still depend on the ntopng REST API and are unavailable when ntopng is stopped; historical queries continue to work. These commands need backend-specific implementations if required. The current time-bucket assignment uses print output end timestamps and is not a packet-level timestamp.

**Rollback:** disable `pmacct-import.timer`, re-enable `ntopng.service` and `ntop-collector.timer`, and restore the backup only after stopping writers and explicitly deciding whether to discard pmacct-era writes. Do not copy a SQLite backup over an actively open WAL database.
