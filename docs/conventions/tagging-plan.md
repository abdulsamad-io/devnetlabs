# Proxmox VM Tagging Plan

Standard **Proxmox VE tags** for every guest, so the PVE UI (and later NetBox/automation)
can filter and group by **function, location, placement, availability, and backup policy**
— without decoding the hostname/VMID. Complements [naming-convention.md](naming-convention.md)
and [vmid-plan.md](vmid-plan.md) (which encode node/role/zone in the *name*; tags make them
*filterable*).

## Rules

- **lowercase**, words separated by `-`; dimension prefix then value (`tier-logging`).
  Proxmox tags allow `A–Za–z0–9_+.-` only — **no `:`**, so use `-`, not `key:value`.
- **Multi-valued**, semicolon-separated in `qm`: `--tags "dc01;zone-mgt;tier-dns;..."`.
- Every VM carries **one tag per dimension** below (6 core incl. `ha-`; `state-`/`template` optional).
- Tags are for **grouping/filtering**, not authority — the VMID/hostname remain the source
  of truth for identity; NetBox (#23) will be the SoT that these mirror.
- **Register the tags + colors** at the datacenter level so they're consistent and
  color-coded (below).

## Dimensions

| Dimension | Prefix | Allowed values |
|-----------|--------|----------------|
| **Location** (node) | *(none)* | `dc01` · `dc02` · `dc03` |
| **Placement** (VLAN/zone) | `zone-` | `zone-mgt` · `zone-apps` · `zone-media` · `zone-nas` · `zone-pbs` · `zone-oob` (lab OOB NIC) |
| **Functionality** (tier) | `tier-` | `tier-mgmt` · `tier-dns` · `tier-ipam` · `tier-logging` · `tier-monitoring` · `tier-virt` · `tier-storage` · `tier-backup` · `tier-media` · `tier-edge` |
| **Availability** | `av-` | `av-always-on` · `av-on-demand` · `av-dr` |
| **Backup policy** | `bkp-` | `bkp-pbs` (vzdump→PBS) · `bkp-repl` (ZFS replication) · `bkp-none` |
| **HA role** | `ha-` | `ha-none` (standalone) · `ha-active` · `ha-standby` (syslog VIP pair) · `ha-primary` · `ha-secondary` (DNS pair) |

**Optional add-ons**
| Dimension | Prefix | Values | Use |
|-----------|--------|--------|-----|
| **Rollout state** | `state-` | `state-planned` · `state-built` | flip to `state-built` once verified; a live build tracker |
| **Template** | *(none)* | `template` | on `tmpl-*` guests |

> Why both `tier-` *and* the hostname role: the hostname gives the *specific* service
> (`dnlgrf101` = Grafana); `tier-` gives the *group* (`tier-monitoring`) so one UI filter
> pulls Grafana + Prometheus + LibreNMS together.

## Per-VM assignment

### dc01 — GEEKOM IT13 (always-on)

| VMID | Hostname | Tags |
|------|----------|------|
| 1001 | `dnllbr101` | `dc01;zone-mgt;tier-monitoring;av-always-on;bkp-pbs;ha-none` |
| 1002 | `dnladm101` | `dc01;zone-mgt;tier-mgmt;av-always-on;bkp-pbs;ha-none` |
| 1003 | `dnlnbx101` | `dc01;zone-mgt;tier-ipam;av-always-on;bkp-pbs;ha-none` |
| 1004 | `dnllog101` | `dc01;zone-mgt;tier-logging;av-always-on;bkp-pbs;ha-active` |
| 1005 | `dnldns101` | `dc01;zone-mgt;tier-dns;av-always-on;bkp-pbs;ha-primary` |
| 1006 | `dnlctl101` | `dc01;zone-mgt;tier-edge;av-always-on;bkp-pbs;ha-none` |
| 1104 | `dnllok101` | `dc01;zone-apps;tier-logging;av-always-on;bkp-pbs;ha-none` |
| 1105 | `dnlgrf101` | `dc01;zone-apps;tier-monitoring;av-always-on;bkp-pbs;ha-none` |
| 1106 | `dnlprm101` | `dc01;zone-apps;tier-monitoring;av-always-on;bkp-pbs;ha-none` |
| 1107 | `dnlukm101` | `dc01;zone-apps;tier-monitoring;av-always-on;bkp-pbs;ha-none` |
| 1108 | `dnlnfy101` | `dc01;zone-apps;tier-monitoring;av-always-on;bkp-pbs;ha-none` |
| 1109 | `dnlpnt101` | `dc01;zone-apps;zone-oob;tier-virt;av-always-on;bkp-pbs;ha-none` |
| 1110 | `dnleve101` | `dc01;zone-apps;zone-oob;tier-virt;av-always-on;bkp-pbs;ha-none` |
| 1201 | `dnlplx101` | `dc01;zone-media;tier-media;av-always-on;bkp-pbs;ha-none` |
| 1301 | `dnlnas101` | `dc01;zone-nas;tier-storage;av-always-on;bkp-repl;ha-none` |
| 1302 | `dnlpbs101` | `dc01;zone-nas;tier-backup;av-always-on;bkp-none;ha-none` |
| 1901/1902 | *(templates)* | `dc01;template` |

### dc02 — HPE ML150 G9 (on-demand)

| VMID | Hostname | Tags |
|------|----------|------|
| 2001 | `dnldns201` | `dc02;zone-mgt;tier-dns;av-on-demand;bkp-pbs;ha-secondary` |
| 2003 | `dnlgry201` | `dc02;zone-mgt;tier-logging;av-on-demand;bkp-pbs;ha-none` |
| 2004 | `dnllog201` | `dc02;zone-mgt;tier-logging;av-on-demand;bkp-pbs;ha-standby` |
| 2101 | `dnlpnt201` | `dc02;zone-apps;zone-oob;tier-virt;av-on-demand;bkp-pbs;ha-none` |
| 2102 | `dnleve201` | `dc02;zone-apps;zone-oob;tier-virt;av-on-demand;bkp-pbs;ha-none` |
| 2105 | `dnlgrf201` | `dc02;zone-apps;tier-monitoring;av-on-demand;bkp-pbs;ha-none` |
| 2106 | `dnlprm201` | `dc02;zone-apps;tier-monitoring;av-on-demand;bkp-pbs;ha-none` |

### dc03 — Dell E6430 (DR target)

| VMID | Hostname | Tags |
|------|----------|------|
| 3401 | `dnlpbs301` | `dc03;zone-pbs;tier-backup;av-dr;bkp-none;ha-none` |

> **Notes:** the lab emulators (`dnlpnt101`/`dnleve101` on dc01, `dnlpnt201`/`dnleve201`
> on dc02) are **dual-homed** — host mgmt/UI on `dcNN_apps` (`zone-apps`) **and** a NIC on
> the lab OOB VLAN (`zone-oob`, VLAN 4001/4002) that carries the emulated devices' mgmt
> plane. `bkp-none` on the PBS guests is deliberate: PBS servers back up *others* (protect
> their datastore separately). TrueNAS's data is on a passthrough disk → `bkp-repl` (ZFS
> replication), not vzdump.

## Register the tags + colors (datacenter)

`/etc/pve/datacenter.cfg` — registered tags keep the list closed (no typos) and give each a
colour in the UI:
```
tag-style: ordering=config;shape=full;color-map=dc01:2ecc71,dc02:e67e22,dc03:95a5a6,zone-mgt:34495e,zone-apps:2980b9,zone-oob:8e44ad,zone-nas:16a085,tier-logging:3498db,tier-monitoring:9b59b6,tier-dns:1abc9c,tier-backup:7f8c8d,tier-virt:e74c3c,av-on-demand:f39c12,av-dr:c0392b,bkp-none:bdc3c7
registered-tags: dc01;dc02;dc03;zone-mgt;zone-apps;zone-oob;zone-media;zone-nas;zone-pbs;tier-mgmt;tier-dns;tier-ipam;tier-logging;tier-monitoring;tier-virt;tier-storage;tier-backup;tier-media;tier-edge;av-always-on;av-on-demand;av-dr;bkp-pbs;bkp-repl;bkp-none;ha-none;ha-active;ha-standby;ha-primary;ha-secondary;template
```
*(Colour map trimmed for brevity — extend to taste. `ordering=config` shows tags in the
order set, not alphabetical.)*

## Apply & verify

Set tags on the node that hosts the VM (standalone/PDM — per node):
```bash
qm set 1005 --tags "dc01;zone-mgt;tier-dns;av-always-on;bkp-pbs;ha-primary"   # replaces the tag set
qm config 1005 | grep '^tags:'                                                # verify
```
Apply the whole plan on a node in one pass (edit to that node's VMIDs):
```bash
qm set 1001 --tags "dc01;zone-mgt;tier-monitoring;av-always-on;bkp-pbs"
qm set 1002 --tags "dc01;zone-mgt;tier-mgmt;av-always-on;bkp-pbs"
# …one line per VMID from the tables above…
```
- **Verify in the UI:** Datacenter → search/filter by a tag (e.g. `tier-monitoring`) shows
  the group; the colour chips render per the `color-map`.
- **Bulk audit:** `pvesh get /cluster/resources --type vm --output-format json | \`
  `jq -r '.[] | "\(.vmid)\t\(.name)\t\(.tags)"'` lists every VM's tags (run per node if not
  clustered).

> `qm set --tags` **replaces** the full set (it's not additive) — always pass the complete
> list from the table, or you'll drop the others.

---

See also: [naming-convention.md](naming-convention.md) · [vmid-plan.md](vmid-plan.md) ·
[lld.md](../lld.md)
