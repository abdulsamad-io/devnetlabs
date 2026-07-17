# Logging Design — rsyslog → Loki + Graylog (cross-feed)

DevNetLabs runs **two log backends side-by-side on purpose** — this is a
learn-the-enterprise-stack lab, so we compare a label-indexed store (Loki) against a
full-text SIEM-style store (Graylog) on the *same* log sources.

## Components

| Role | Code | Host | VMID | Node | Notes |
|------|------|------|------|------|-------|
| rsyslog collector (active) | `log` | `dnllog101` | 1004 | dc01 | HA pair with dnllog201 |
| rsyslog collector (standby) | `log` | `dnllog201` | 2004 | dc02 | HA pair with dnllog101 |
| Loki (light, always-on) | `lok` | `dnllok101` | 1104 | dc01 (apps/1101, 10.110.10.70) | label-indexed; UI via Grafana |
| Graylog (heavy, on-demand) | `gry` | `dnlgry201` | 2003 | dc02 | OpenSearch, 6–8 GB; own web UI |

- **Graylog lives on dc02** (the heavy / on-demand node) so its RAM + NVMe I/O don't tax
  always-on dc01, and you power it up when you want to work with it.
- **Loki lives on dc01** (light enough for the always-on node) for continuous logging.
- **Grafana** (`grf`, future) fronts Loki; Graylog brings its own UI.

## Data flow (cross-feed via an HA collector)

```
   devices / hosts ──syslog──▶  VIP 172.16.10.70  (keepalived / VRRP, VLAN 1000)
                                      │  (held by whichever collector is ACTIVE)
                        ┌─────────────┴──────────────┐
                  dnllog101 (MASTER)           dnllog201 (BACKUP)
                        │  fan-out (cross-feed) — from the ACTIVE collector only
                        ├──▶ Loki    (dnllok101, dc01)   ← always up
                        └──▶ Graylog (dnlgry201, dc02)   ← on-demand; disk-buffered
```

**Cross-feed** = every log is sent to **both** backends, so you can run the same query
against the same data in each and compare them. Cost: ~2× ingest/storage (each backend
stores everything) — acceptable and instructive in a lab.

## Why an HA collector (and not "both forward")

Two collectors that both hold the same data would **double-ingest** each backend if both
forwarded — neither Loki nor Graylog de-duplicates identical syslog events. So:

- Sources point at **one VIP** (`172.16.10.70`), held by the **active** collector via
  **keepalived/VRRP**. Only the VIP-holder receives and fans out → **each event reaches
  each backend exactly once.**
- The standby takes the VIP (gratuitous ARP) on failure of the host or the rsyslog
  daemon (`track_script`). Both collectors are configured identically.
- **Split-brain warning:** if VRRP can't pass between them, both become master and
  duplication returns — allow VRRP (multicast `224.0.0.18`/proto 112, or use
  `unicast_peer`) between the two.

## Handling on-demand Graylog (disk-assisted queue)

Because dc02/Graylog is usually **down**, the fan-out action to Graylog uses a
**per-action, disk-assisted rsyslog queue** so it never blocks Loki and never drops logs:

```
# Graylog (dc02) — buffers while offline, replays on return
action(
    type="omfwd" target="dnlgry201" port="1514" protocol="tcp"
    action.resumeRetryCount="-1"       # retry forever; never drop
    action.resumeInterval="30"
    queue.type="linkedList"
    queue.filename="q_graylog"         # filename => disk-assisted (spills to disk)
    queue.maxDiskSpace="2g"            # bound worst-case backlog
    queue.size="200000"
    queue.saveOnShutdown="on"          # survive rsyslog/host restart
)
# Loki (dc01) — its own queue so Graylog being down never stalls it
action(type="omhttp" server="dnllok101.dc01.devnetlabs.com" ... queue.type="linkedList"
       queue.filename="q_loki" queue.saveOnShutdown="on" action.resumeRetryCount="-1")
```

- **Per-action queues decouple destinations** — Graylog offline never back-pressures Loki.
- While dc02 sleeps, Graylog's queue accumulates on the active collector's disk (≤ 2 GB),
  then **drains/replays** when Graylog's input comes up.
- Caveat: bounded buffer — a dc02 outage long enough to hit `maxDiskSpace` drops the
  oldest queued messages; size it for your realistic max outage. The buffer lives on the
  active collector, so a failover starts a fresh buffer on the standby.

## Retention (set it, or storage grows unbounded)

- **Graylog/OpenSearch:** configure index rotation + retention (by size/time); single
  node → **replicas = 0**. On-disk ≈ raw × 1–1.5.
- **Loki:** compressed chunks (~5–10× smaller than OpenSearch); set a retention period.

## Address / naming notes

- Reserve **`172.16.10.70`** (syslog VIP) outside the DHCP pool.
- rsyslog = `log` (two instances, HA pair); Loki = `lok`; Graylog = `gry` — see
  [naming-convention.md](naming-convention.md) and [vmid-plan.md](vmid-plan.md).

---

See also: [network-vlan-design.md](network-vlan-design.md) · [lld.md](lld.md) ·
[OPEN-ITEMS.md](OPEN-ITEMS.md)
