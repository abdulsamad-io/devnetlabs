# VMID Numbering Plan

Scheme: **`NZSS`** (4 digits).

| Field | Meaning | Values |
|-------|---------|--------|
| `N` | Node | `1`=dc01, `2`=dc02, `3`=dc03 |
| `Z` | Zone (VLAN) | `0`=mgmt/1000, `1`=apps/1101&1201, `2`=media/1102, `3`=nas/1103, `4`=backup·pbs/1301, `9`=templates |
| `SS` | Sequence | `01–49`=VM, `50–98`=CT, `99`=spare |

> **All guests are currently VMs — no containers (CT) for now.** Every live allocation
> therefore uses the VM sequence range `01–49`. The CT range `50–98` stays reserved for
> future container workloads.

**Design principles**
- **Globally unique across all nodes** (even though standalone/PDM only needs
  per-node uniqueness) so **PBS backups restore onto any node without collision**.
- Apply the VMID **at create time** (override the GUI auto-suggestion) and **at
  restore time** (set the target VMID).
- Put placement/role metadata in **Proxmox tags**, not encoded beyond the VMID.
- Hostnames follow the node-embedded **`dnl<role><dc><nn>`** scheme; the hostname's
  `<dc>` digit **must equal this VMID's `N` digit** (see
  [naming-convention.md](naming-convention.md)). Moving a guest across nodes means
  renumbering the VMID **and** renaming the host — see
  [cross-dc-migration.md](cross-dc-migration.md).

---

## Allocations

### dc01 — GEEKOM IT13 (always-on)

| VMID | Hostname | Guest | Type | Zone (VLAN) |
|------|----------|-------|------|-------------|
| 1001 | `dnllbr101` | LibreNMS | VM | mgmt (1000) |
| 1002 | `dnladm101` | Admin / bastion (jump) host | VM | mgmt (1000) |
| 1003 | `dnlnbx101` | NetBox | VM | mgmt (1000) |
| 1004 | `dnllog101` | rsyslog collector (HA active) | VM | mgmt (1000) |
| 1005 | `dnldns101` | Technitium DNS #1 (.53) | VM | mgmt (1000) |
| 1006 | `dnlctl101` | Cloudflare tunnel | VM | mgmt (1000) |
| 1007 | — | *reserved — mgmt* | — | mgmt (1000) |
| 1104 | `dnllok101` | Loki (log store) | VM | apps (1101) |
| 1105 | `dnlgrf101` | Grafana | VM | apps (1101) |
| 1106 | `dnlprm101` | Prometheus (+ snmp_exporter) | VM | apps (1101) |
| 1201 | `dnlplx101` | Plex / media | VM | media (1102) |
| 1301 | `dnlnas101` | TrueNAS | VM | nas (1103) |
| 1302 | `dnlpbs101` | PBS (local, M.2) | VM | nas (1103) |
| 1901 | — | Debian 12 template | tmpl | templates |
| 1902 | — | Ubuntu 24.04 template | tmpl | templates |

### dc02 — HPE ML150 G9 (on-demand, heavy/nested-virt)

| VMID | Hostname | Guest | Type | Zone (VLAN) |
|------|----------|-------|------|-------------|
| 2001 | `dnldns201` | Technitium DNS #2 (.54) | VM | mgmt (1000) |
| 2004 | `dnllog201` | rsyslog collector (HA standby) | VM | mgmt (1000) |
| 2003 | `dnlgry201` | Graylog (OpenSearch, on-demand) | VM | mgmt (1000) |
| 2101 | `dnlpnt201` | PNETLAB (+ mgmt NIC on 1000) | VM | apps (1201) |
| 2102 | `dnleve201` | EVE-NG | VM | apps (1201) |
| 2105 | `dnlgrf201` | Grafana | VM | apps (1201) |
| 2106 | `dnlprm201` | Prometheus (+ snmp_exporter) | VM | apps (1201) |

### dc03 — Dell E6430 (PBS cross-node DR target)

| VMID | Hostname | Guest | Type | Zone (VLAN) |
|------|----------|-------|------|-------------|
| 3001–3049 | — | *reserved mgmt* | — | mgmt (1000) |
| 3401 | `dnlpbs301` | PBS (cross-node DR target) | VM | backup·pbs (1301) |

> **Notes / assumptions**
> - **All guests are VMs for now** (the CT range `50–98` is reserved for later).
> - **Two PBS instances**: dc01 local, M.2 (`1302`) + dc03 DR (`3401`). If PBS on dc03
>   is bare-metal, it has no VMID.
> - **Logging:** rsyslog HA pair (`dnllog101`/`dnllog201`) cross-feeds **Loki**
>   (`dnllok101`, dc01) + **Graylog** (`dnlgry201`, dc02) — see
>   [logging-design.md](logging-design.md).
> - **Unmapped / pending (see OPEN-ITEMS):**
>   - **M.2 2242 role** — local PBS (`1302`) vs vzdump + TrueNAS replication target.
