# rsyslog Central Collector Setup — `dnllog101` / `dnllog201`

Central syslog collection for the lab, classifying every source into a vendor/category
tree, then cross-feeding **Loki** (dc01) + **Graylog** (dc02). See the architecture in
[logging-design.md](logging-design.md) (HA collector + keepalived VIP + disk-queue
fan-out).

## Facts

| Item | Value |
|------|-------|
| Collectors | `dnllog101` (dc01, HA active) + `dnllog201` (dc02, HA standby) — identical config |
| Ingress VIP | `172.16.10.70` (keepalived) — sources point here |
| Log root | **`/var/log/devnetlabs_logs/`** |
| Backends | Loki (`dnllok101`, dc01) + Graylog (`dnlgry201`, dc02, on-demand) |

**Model:** the file tree is the **archive/buffer tier** (coarse, by vendor); **Loki/Graylog
are the query tier** (fine, by host/field). Only the **active** (VIP-holding) collector
receives and forwards — so no double-ingest.

## Folder taxonomy

```
/var/log/devnetlabs_logs/<category>/<vendor|os>/<vendor|os>-YYYY-MM-DD.log
```
One combined dated file per vendor (no per-host files — ephemeral-friendly; the hostname
+ source IP are inside every line). Categories/vendors:

```
network/{cisco,juniper,arista,mikrotik}     security/{asa,ftd,checkpoint,fortigate,panos}
compute/{linux,windows}                     storage/{truenas}          others/
```

---

## Part 1 — Package + log root

```bash
sudo apt update && sudo apt install -y rsyslog
sudo install -d -m 0750 -o syslog -g adm /var/log/devnetlabs_logs
```

## Part 2 — Listeners (`/etc/rsyslog.d/10-inputs.conf`)

```rsyslog
module(load="imudp") input(type="imudp" port="514" ruleset="devnetlabs_collect")   # legacy devices
module(load="imtcp") input(type="imtcp" port="514" ruleset="devnetlabs_collect")   # reliable
# Optional TLS for security gear (RFC5425):
#   module(load="imtcp" StreamDriver.Name="gtls" StreamDriver.Mode="1" StreamDriver.AuthMode="anon")
#   input(type="imtcp" port="6514" ruleset="devnetlabs_collect")
```

## Part 3 — Classification (source-IP → `category/vendor`)

Map each source by its **fixed IP**. Hot-reloadable JSON lookup table — no wall of if/else.

`/etc/rsyslog.d/devnetlabs-sources.json`:
```json
{ "version": 1, "nomatch": "others", "type": "string",
  "table": [
    { "index": "172.16.20.1",  "value": "network/mikrotik" },
    { "index": "10.20.0.1",    "value": "network/cisco" },
    { "index": "10.20.0.10",   "value": "security/asa" },
    { "index": "10.20.0.11",   "value": "security/panos" },
    { "index": "10.20.0.12",   "value": "security/fortigate" },
    { "index": "172.16.10.30", "value": "compute/linux" },
    { "index": "172.16.10.40", "value": "compute/windows" },
    { "index": "10.110.30.50", "value": "storage/truenas" }
  ]}
```
Unmatched IPs fall to **`others`** (a TODO signal to add a mapping).

## Part 4 — Templates + ruleset (`/etc/rsyslog.d/20-devnetlabs.conf`)

```rsyslog
# hot-reloadable lookup table (reload with SIGHUP)
lookup_table(name="srcmap" file="/etc/rsyslog.d/devnetlabs-sources.json" reloadOnHUP="on")

# dynamic path: /var/log/devnetlabs_logs/<category>/<vendor>/<vendor>-YYYY-MM-DD.log
template(name="devnetlabs_dynafile" type="string"
  string="/var/log/devnetlabs_logs/%$.path%/%$.leaf%-%$now%.log")

# line format — includes SOURCE IP so same-named PNETLab clones stay distinguishable
template(name="line_ip" type="string"
  string="%timestamp:::date-rfc3339% %fromhost-ip% %hostname% %syslogtag%%msg:::sp-if-no-1st-sp%%msg:::drop-last-lf%\n")

ruleset(name="devnetlabs_collect") {
    set $.path = lookup("srcmap", $fromhost-ip);              # "security/asa" | "others"
    set $.leaf = re_extract($.path, "([^/]+)$", 0, 1, "others");   # "asa" | "others"

    # (1) ARCHIVE — write to the vendor tree
    action(type="omfile" dynaFile="devnetlabs_dynafile" template="line_ip"
           dirCreateMode="0750" fileCreateMode="0640" dynaFileCacheSize="200")

    # (2) FAN-OUT → Graylog (dc02, on-demand): disk-assisted queue buffers + replays
    action(type="omfwd" target="dnlgry201" port="1514" protocol="tcp"
           template="RSYSLOG_SyslogProtocol23Format"
           action.resumeRetryCount="-1"
           queue.type="linkedList" queue.filename="q_graylog"
           queue.maxDiskSpace="2g" queue.saveOnShutdown="on")

    # (3) FAN-OUT → Loki: simplest via Alloy tailing the tree (Part 6). If you prefer
    #     rsyslog-direct, add an omhttp action here to the Loki push API.
}
```
Apply: `sudo rsyslogd -N1 && sudo systemctl restart rsyslog` (validate config first).

> The `%$now%` date is the collector's processing date — a fresh file per vendor per day,
> so no HUP-rotate dance. The folder already encodes the vendor; the filename repeats it
> so archived/gzipped files stay self-describing.

## Part 5 — Rotation & retention (`/etc/cron.daily/devnetlabs-logs`)

Date-stamped files rotate themselves. Goal: **today and yesterday stay uncompressed
(`<vendor>-YYYY-MM-DD.log`); every day older than yesterday is gzipped; compressed logs
are deleted after 90 days.** Compress by **filename date** (not `mtime`, which truncates
and is write-time-fuzzy):
```sh
#!/bin/sh
today=$(date +%F)                 # e.g. 2026-07-16   (keep uncompressed)
yday=$(date -d yesterday +%F)     # e.g. 2026-07-15   (keep uncompressed)
# compress every .log EXCEPT today's and yesterday's
find /var/log/devnetlabs_logs -type f -name '*.log' \
     ! -name "*-$today.log" ! -name "*-$yday.log" -exec gzip {} \;
# delete compressed logs older than 90 days (gzip preserves the log's original mtime)
find /var/log/devnetlabs_logs -type f -name '*.log.gz' -mtime +90 -delete
find /var/log/devnetlabs_logs -type d -empty -delete
```
`chmod +x`. Depth-agnostic; `date -d yesterday` needs GNU date (Ubuntu ✓). Run daily
(systemd timer or `cron.daily`); each collector rotates its own tree. Tune `+90` to taste.

## Part 6 — Forwarding to Loki (Grafana Alloy tails the tree)

Let the **path become the labels** — low-cardinality `category` + `vendor` only. Host/IP
stay *in the line* (filter with LogQL `|=`), not as labels (avoids cardinality blowups
from churny PNETLab devices).

```alloy
local.file_match "devnetlabs" {
  path_targets = [{ __path__ = "/var/log/devnetlabs_logs/**/*.log" }]
}
loki.process "label_from_path" {
  forward_to = [loki.write.default.receiver]
  stage.regex {
    source     = "filename"
    expression = "/var/log/devnetlabs_logs/(?P<category>[^/]+)/(?:(?P<vendor>[^/]+)/)?"
  }
  stage.labels { values = { category = "", vendor = "" } }
}
loki.source.file "devnetlabs" {
  targets    = local.file_match.devnetlabs.targets
  forward_to = [loki.process.label_from_path.receiver]
}
loki.write "default" { endpoint { url = "http://dnllok101:3100/loki/api/v1/push" } }
```

**Graylog** (Part 4 action #2) ingests via a **Syslog TCP** input on `dnlgry201:1514`;
route to streams by source and apply vendor content packs/extractors (ASA, PAN-OS,
Fortinet, Checkpoint).

## Part 7 — Onboarding a source

> **Per-device syslog config** (Cisco IOS/XE/XR/NXOS, Juniper, Arista, MikroTik, ASA,
> FTD, PAN-OS, FortiGate, Check Point, Windows, Linux, TrueNAS): see
> [log-source-onboarding.md](log-source-onboarding.md).

1. **Point the device's syslog** at the VIP `172.16.10.70` (UDP/TCP 514).
2. **Add its IP** to `devnetlabs-sources.json` (`"value":"network/cisco"` etc.).
3. **Reload** (no restart): `sudo pkill -HUP rsyslogd` (or `systemctl kill -s HUP rsyslog`).
4. Verify a file appears under the expected vendor folder.

**Windows hosts:** Windows has no native syslog — install **nxlog (Community)** to convert
Windows Event Log → syslog and send to the VIP (classified as `compute/windows`).

## Part 8 — HA behaviour & verify

- Config is **identical on both collectors**; only the **VIP holder** receives, writes,
  and forwards → each event lands once. (keepalived setup: see
  [keepalived-setup.md](keepalived-setup.md).)
- The Graylog disk-queue lives on the active collector; a failover starts a fresh buffer
  on the standby.

**Verify:**
```bash
logger -n 172.16.10.70 -P 514 -d "test from $(hostname)"     # send a test event
ls -R /var/log/devnetlabs_logs/                              # file appears in the right branch
sudo tail -f /var/log/devnetlabs_logs/others/others-*.log    # unmatched sources land here
```

---

See also: [logging-design.md](logging-design.md) · [naming-convention.md](naming-convention.md) ·
[lld.md](lld.md)
