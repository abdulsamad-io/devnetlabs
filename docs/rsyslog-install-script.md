# rsyslog Collector — copy-paste install script

Executable companion to [rsyslog-setup.md](rsyslog-setup.md). Run **on each collector**
(`dnllog101`, then `dnllog201`) after the VM base build
([log-collector-setup.md](log-collector-setup.md)). Each step is copy-paste; the bullets
explain what every line does.

> **Preconditions:** Ubuntu, run as a sudo user; the **50 GB log disk is mounted at
> `/var/log/devnetlabs_logs`** (Part D of the VM runbook). Config is identical on both
> collectors.

---

## Step 1 — Install & prep
```bash
sudo apt update && sudo apt install -y rsyslog jq
sudo install -d -m 0750 -o syslog -g adm /var/log/devnetlabs_logs
```
- `apt install rsyslog jq` — the daemon (usually preinstalled) + `jq` for the source-map helper later.
- `install -d -m 0750 -o syslog -g adm …` — create the log root owned by rsyslog's user
  (`syslog:adm`) with `0750` perms (rsyslog writes; group `adm` reads; others none).

## Step 2 — Listeners
```bash
sudo tee /etc/rsyslog.d/10-inputs.conf >/dev/null <<'EOF'
module(load="imudp")
input(type="imudp" port="514" ruleset="devnetlabs_collect")
module(load="imtcp")
input(type="imtcp" port="514" ruleset="devnetlabs_collect")
EOF
```
- `module(load="imudp")` / `imtcp` — load the UDP and TCP syslog input modules.
- `input(type=… port="514" ruleset="devnetlabs_collect")` — listen on 514 (all
  addresses, so it answers on the VIP) and hand every received message to our ruleset
  (defined in Step 4). UDP for legacy gear, TCP for reliable sources.

## Step 3 — Classification table (source IP → category/vendor)
```bash
sudo tee /etc/rsyslog.d/devnetlabs-sources.json >/dev/null <<'EOF'
{ "version": 1, "nomatch": "others", "type": "string",
  "table": [
    { "index": "172.16.20.1",  "value": "network/mikrotik" },
    { "index": "10.20.0.10",   "value": "security/asa" }
  ]}
EOF
```
- `"type":"string"` — a string lookup table keyed by the value we pass (the source IP).
- `"nomatch":"others"` — any IP not listed classifies as `others` (→ `others/` folder).
- `"table":[…]` — the IP→`category/vendor` map; add one object per device (or generate
  from NetBox, issue #33). Reloadable without restart (Step 4 sets `reloadOnHUP`).

## Step 4 — Templates + ruleset (archive + fan-out)
```bash
sudo tee /etc/rsyslog.d/20-devnetlabs.conf >/dev/null <<'EOF'
lookup_table(name="srcmap" file="/etc/rsyslog.d/devnetlabs-sources.json" reloadOnHUP="on")

template(name="devnetlabs_dynafile" type="string"
  string="/var/log/devnetlabs_logs/%$.path%/%$.leaf%-%$now%.log")

template(name="line_ip" type="string"
  string="%timestamp:::date-rfc3339% %fromhost-ip% %hostname% %syslogtag%%msg:::sp-if-no-1st-sp%%msg:::drop-last-lf%\n")

ruleset(name="devnetlabs_collect") {
    set $.path = lookup("srcmap", $fromhost-ip);
    set $.leaf = re_extract($.path, "([^/]+)\$", 0, 1, "others");

    action(type="omfile" dynaFile="devnetlabs_dynafile" template="line_ip"
           dirCreateMode="0750" fileCreateMode="0640" dynaFileCacheSize="200")

    action(type="omfwd" target="dnlgry201" port="1514" protocol="tcp"
           template="RSYSLOG_SyslogProtocol23Format"
           action.resumeRetryCount="-1"
           queue.type="linkedList" queue.filename="q_graylog"
           queue.maxDiskSpace="2g" queue.saveOnShutdown="on")
}
EOF
```
- `lookup_table(name="srcmap" file=… reloadOnHUP="on")` — load the Step-3 map as `srcmap`;
  a `SIGHUP` reloads it live (no restart, keeps old table if the new JSON is invalid).
- `template devnetlabs_dynafile` — builds the output **path** per message:
  `/var/log/devnetlabs_logs/<category>/<vendor>/<vendor>-<date>.log`. `%$now%` is the
  collector's date → a fresh file per vendor per day.
- `template line_ip` — the **line format**: RFC3339 timestamp, **source IP**, hostname,
  tag, message (source IP keeps same-named PNETLab clones distinguishable).
- `set $.path = lookup("srcmap", $fromhost-ip)` — classify by sender IP → e.g.
  `security/asa` (or `others`).
- `set $.leaf = re_extract(…"([^/]+)\$"…)` — pull the **last path segment** (the vendor,
  e.g. `asa`) for the filename; falls back to `others`. The `$` end-anchor **must be
  escaped as `\$`** — in RainerScript a bare `$` inside a double-quoted string is read as
  a variable sigil and fails config validation. (Safe inside the `<<'EOF'` quoted
  heredoc: the shell won't touch the backslash.)
- **action 1 (`omfile`)** — write to the vendor tree via the dynafile template;
  auto-create dirs `0750`, files `0640`; `dynaFileCacheSize=200` keeps ~200 open file
  handles (plenty for the vendor×day set).
- **action 2 (`omfwd` → Graylog)** — forward to `dnlgry201:1514` over TCP with a
  **disk-assisted queue**: `resumeRetryCount=-1` (retry forever), `queue.filename` makes
  it spill to disk, `maxDiskSpace=2g` caps the backlog, `saveOnShutdown` survives
  restarts → buffers while dc02/Graylog is off, replays on return.
- **Loki** isn't here — Grafana **Alloy** tails `/var/log/devnetlabs_logs/**` and derives
  labels from the path (see rsyslog-setup.md Part 6).

## Step 5 — Rotation (today+yesterday uncompressed, gzip older, delete >90d)
```bash
sudo tee /etc/cron.daily/devnetlabs-logs >/dev/null <<'EOF'
#!/bin/sh
today=$(date +%F)
yday=$(date -d yesterday +%F)
find /var/log/devnetlabs_logs -type f -name '*.log' \
     ! -name "*-$today.log" ! -name "*-$yday.log" -exec gzip {} \;
find /var/log/devnetlabs_logs -type f -name '*.log.gz' -mtime +60 -delete
find /var/log/devnetlabs_logs -type d -empty -delete
EOF
sudo chmod +x /etc/cron.daily/devnetlabs-logs
```
- `today` / `yday` — the two dates to **keep uncompressed**.
- `find … ! -name "*-$today.log" ! -name "*-$yday.log" -exec gzip` — compress every
  `.log` except today's and yesterday's (matched by the date in the filename — precise,
  unlike `-mtime`).
- `find … '*.log.gz' -mtime +60 -delete` — delete compressed logs older than 60 days
  (gzip preserves the log's original mtime, so the count is honest).
- `find … -type d -empty -delete` — tidy empty vendor folders.
- `chmod +x` — make it run as a daily job.

## Step 6 — Validate & start
```bash
sudo rsyslogd -N1                 # config syntax check — must be clean
sudo systemctl enable --now rsyslog
sudo systemctl restart rsyslog
```
- `rsyslogd -N1` — dry-run validation; fix any error **before** restarting.
- `enable --now` + `restart` — start rsyslog and load the new config.

## Step 7 — Test
```bash
logger -n 127.0.0.1 -P 514 -T -d "collector self-test"      # -T = TCP
ls -R /var/log/devnetlabs_logs/                              # a file should appear
sudo tail -f /var/log/devnetlabs_logs/others/others-*.log    # unmatched sources land here
```

## Adding a source later (dynamic, no restart)
```bash
f=/etc/rsyslog.d/devnetlabs-sources.json
sudo jq --arg ip "10.20.0.11" --arg val "security/panos" \
   '.table |= (map(select(.index != $ip)) + [{"index":$ip,"value":$val}])' "$f" \
   | sudo tee "$f.new" >/dev/null && sudo jq empty "$f.new" && sudo mv "$f.new" "$f"
sudo pkill -HUP rsyslogd
```
- `jq … .table |= (map(select(.index != $ip)) + [{…}])` — upsert the IP→value (replace if
  present), so re-runs are safe.
- `jq empty` — validate the new JSON before swapping it in (`mv`).
- `pkill -HUP rsyslogd` — hot-reload the lookup table; no restart, no dropped messages.

Then configure the device itself per [log-source-onboarding.md](log-source-onboarding.md).

---

## Verification & success criteria

**✅ Success criteria — the collector is working when:**
- [ ] `sudo rsyslogd -N1` returns **clean** (no parse errors).
- [ ] `ss -lntu | grep :514` shows rsyslog on **both udp and tcp 514**.
- [ ] A `logger` test writes a dated file under `/var/log/devnetlabs_logs/…`, owned **`syslog:adm`**.
- [ ] Mapped sources land in `category/vendor`; unmapped fall to `others/`.
- [ ] `/etc/cron.daily/devnetlabs-logs` is **executable** and rotates correctly (rsyslog-setup Part 5 test).

**🧪 End-to-end test:**
```bash
sudo rsyslogd -N1                                           # clean
ss -lntu | grep ':514'                                      # udp + tcp listeners present
logger -n 172.16.10.70 -P 514 -T -d "collector self-test"   # -T = TCP, via the VIP
ls -lR /var/log/devnetlabs_logs/                            # dated file appears (syslog:adm 0640)
```
Expected: `-N1` clean, both listeners present, a fresh `*-YYYY-MM-DD.log` written as `syslog:adm`.

**⚠️ Watch out for:**
- **`$` in the `re_extract` regex** — must be escaped `"([^/]+)\$"`; a bare `$` fails validation (safe inside the `<<'EOF'` heredoc).
- **Files owned by `root`** — the log root must be `syslog:adm 0750` (Step 1), or rsyslog can't write / Alloy can't read.
- **Only `/var/log/syslog`, nothing in the tree** — a *local* `logger` uses the default ruleset; test over the **network** (`logger -n …`) to hit `devnetlabs_collect`.
- **Graylog push errors** — expected while `dnlgry201` (dc02) is off; the disk-queue buffers and replays. Not a failure.
- **Timezone** — filenames follow local time; confirm `timedatectl` is `Europe/Amsterdam` or dates bucket in UTC.

---

See also: [rsyslog-setup.md](rsyslog-setup.md) · [log-source-onboarding.md](log-source-onboarding.md) ·
[keepalived-setup.md](keepalived-setup.md)
