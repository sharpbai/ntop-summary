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
