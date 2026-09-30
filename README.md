# ntop-summary

A lightweight CLI toolkit for long-term traffic accounting on top of **ntopng Community**.

It polls ntopng active-flow counters once per minute, stores byte deltas in SQLite, and provides historical summaries by source IP, destination port, destination IP, L7 protocol, and time range.

## Architecture

```text
ntopng REST API
      |
      v
ntop-collector
      |
      | byte deltas / 1-minute buckets
      v
    SQLite
      |
      v
ntop-summary
```

## Requirements

- Linux
- Python 3
- ntopng with HTTPS/API enabled
- ntopng REST API v2
- No third-party Python packages

Developed against ntopng 7.0 Community using:

```text
/lua/rest/v2/get/interface/data.lua
/lua/rest/v2/get/flow/active.lua
```

## Quick install / upgrade

The installer works for both new installations and upgrades:

```bash
git clone https://github.com/sharpbai/ntop-summary.git
cd ntop-summary
sudo ./install.sh
```

For an existing clone:

```bash
git pull
sudo ./install.sh
```

The installer first checks whether `ntopng` is installed. If it is missing, it detects the operating system and installs the ntop official stable repository/package automatically on supported Debian/Ubuntu releases.

On multi-interface hosts the installer deliberately does **not** guess which NIC should be monitored. If ntopng has no capture interface configured yet, set it after installation, for example:

```ini
# /etc/ntopng/ntopng.conf
-i=eth1
```

Then start/restart ntopng:

```bash
sudo systemctl enable --now ntopng
sudo systemctl restart ntopng
```

The installer:


- installs `ntop-summary` and `ntop-collector` into `/usr/local/bin`
- preserves an existing `/etc/ntop-tools.conf`
- creates the configuration from the example on a new installation
- detects databases created by the earlier manual/non-repository deployment
- validates that a candidate SQLite database has the expected `traffic` schema
- preserves a database already located at the configured `NTOP_DB` path
- safely imports a legacy database from another location using SQLite's backup API
- backs up an existing destination database before replacing it
- creates/upgrades the daily-rollup schema
- builds historical daily rollups automatically
- installs and enables the systemd collector timer

The original manual deployment path `/var/lib/ntop-tools/traffic.db` is detected automatically. The installer also checks several common locations and performs a bounded search under `/var/lib`, `/root`, and `/home` when necessary.

After installation, verify:

```bash
ntop-collector --status
systemctl status ntop-collector.timer --no-pager
time ntop-summary 30d
```

## Install

```bash
git clone https://github.com/sharpbai/ntop-summary.git
cd ntop-summary

sudo install -m 0755 ntop-summary /usr/local/bin/ntop-summary
sudo install -m 0755 ntop-collector /usr/local/bin/ntop-collector

sudo cp ntop-tools.conf.example /etc/ntop-tools.conf
sudo chmod 600 /etc/ntop-tools.conf
sudo editor /etc/ntop-tools.conf

sudo mkdir -p /var/lib/ntop-tools
sudo chmod 700 /var/lib/ntop-tools
```

Example configuration:

```ini
NTOP_HOST=127.0.0.1
NTOP_PORT=3001
NTOP_USER=admin
NTOP_PASS=change-me
NTOP_IFID=1
NTOP_PER_PAGE=5000
NTOP_DB=/var/lib/ntop-tools/traffic.db
```

Run the first collection:

```bash
sudo ntop-collector
ntop-summary db
```

## systemd timer

```bash
sudo cp systemd/ntop-collector.service /etc/systemd/system/
sudo cp systemd/ntop-collector.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ntop-collector.timer
```

Verify:

```bash
systemctl status ntop-collector.timer --no-pager
systemctl list-timers ntop-collector.timer
journalctl -u ntop-collector.service -n 20 --no-pager
```

## Usage

```bash
ntop-summary --help

# Current ntopng interface statistics
ntop-summary interface

# Current active flows
ntop-summary live
ntop-summary live --by ip
ntop-summary live --by port
ntop-summary live --by dst

# Historical ranges
ntop-summary today
ntop-summary month
ntop-summary 7d
ntop-summary 30d

# Calendar day / inclusive date range
ntop-summary 2026-09-09
ntop-summary 2026-09-01 2026-09-09

# Grouping
ntop-summary month --by ip-port
ntop-summary month --by ip
ntop-summary month --by port
ntop-summary month --by dst

# Filters
ntop-summary month --port 9009
ntop-summary today --ip 123.119.146.106
ntop-summary 7d --l7 BitTorrent

# Output size
ntop-summary month --limit 100
ntop-summary month --limit 0

# Database status
ntop-summary db
```

`month` means the current calendar month from day 1 at 00:00 through now. `30d` is a rolling 30-day window.

## How accounting works

ntopng reports cumulative bytes for active flows. Summing those counters every minute would repeatedly count long-lived connections.

`ntop-collector` stores the previous counter for each flow and records only the increment:

```text
current flow bytes - previous flow bytes = bytes added this minute
```

Deltas are aggregated into one-minute SQLite buckets, which can later be queried over arbitrary time ranges.

## Performance and daily rollups

Long historical queries do not scan all minute-level rows.

The collector maintains a `traffic_daily` rollup table for completed calendar days. Historical queries combine:

- `traffic_daily` for complete days
- `traffic` for the current/partial day

This keeps `today` precise while making `month`, `7d`, and `30d` much faster as the database grows.

When upgrading an existing installation, install the new scripts and build the rollup table once:

```bash
sudo ntop-collector --rollup
```

Check the result:

```bash
ntop-collector --status
```

You should see both `Minute rows` and `Daily rows`. Normal once-per-minute collector runs automatically roll up newly completed days.

SQLite uses WAL mode, in-memory temporary storage, and a 64 MiB page cache for these queries.

## Database


The `traffic` table stores:

- bucket
- src_ip
- dst_ip
- dst_port
- l4
- l7
- bytes
- new_flows

The `traffic_daily` table has the same traffic dimensions but stores one row per completed calendar day and aggregation key. It is used to accelerate long-range reports.

The `flow_state` table stores the last observed counter for active flows. Stale state is removed after two days.

## Accuracy and limitations

This is polling-based accounting. A flow that starts and finishes entirely between two collector runs can be missed. A one-minute interval is generally suitable for long-lived proxy, tunnel, download, BitTorrent, and server traffic, but it is not equivalent to packet-level accounting.

Historical data starts when `ntop-collector` first runs. Traffic from flows that ended before collection began cannot be reconstructed.

When an already-active flow is first observed, its current cumulative byte count is imported into the first bucket.

ntopng determines client/server direction. Verify that `client.ip` and `server.port` represent the source and destination-port semantics you expect for your topology.

## Security

Keep the real ntopng password only in:

```text
/etc/ntop-tools.conf
```

Recommended permissions:

```bash
chmod 600 /etc/ntop-tools.conf
```

Do not commit the real configuration file. Environment variables named `NTOP_*` override configuration-file values.

## License

MIT
