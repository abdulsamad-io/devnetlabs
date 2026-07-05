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
- Hostnames follow the flat **`dnl<role><NNN>`** scheme (see
  [naming-convention.md](naming-convention.md)).

---

## Allocations

### dc01 — GEEKOM IT13 (always-on)

| VMID | Hostname | Guest | Type | Zone (VLAN) |
|------|----------|-------|------|-------------|
| 1001 | `dnlnms001` | LibreNMS | VM | mgmt (1000) |
| 1002 | `dnladm001` | Admin / bastion (jump) host | VM | mgmt (1000) |
| 1003 | `dnlipam001` | NetBox | VM | mgmt (1000) |
| 1004 | `dnllog001` | rsyslog / logserver | VM | mgmt (1000) |
| 1005 | `dnldns001` | Technitium DNS #1 (.55) | VM | mgmt (1000) |
| 1006 | `dnlcftun001` | Cloudflare tunnel | VM | mgmt (1000) |
| 1007 | `dnlglog001` *(proposed)* | Graylog (OpenSearch) | VM | mgmt (1000) — *pending, see OPEN-ITEMS* |
| 11xx | — | *reserved — apps zone, no services yet* | — | apps (1101) |
| 1201 | `dnlplex001` | Plex / media | VM | media (1102) |
| 1301 | `dnlnas001` | TrueNAS | VM | nas (1103) |
| 1302 | `dnlpbs001` | PBS (local, M.2) | VM | nas (1103) |
| 1901 | — | Debian 12 template | tmpl | templates |
| 1902 | — | Ubuntu 24.04 template | tmpl | templates |

### dc02 — HPE ML150 G9 (on-demand, heavy/nested-virt)

| VMID | Hostname | Guest | Type | Zone (VLAN) |
|------|----------|-------|------|-------------|
| 2001 | `dnldns002` | Technitium DNS #2 (.56) | VM | mgmt (1000) |
| 2002 | `dnllog002` | logserver (secondary) | VM | mgmt (1000) |
| 2101 | `dnlpnet001` | PNETLAB (+ mgmt NIC on 1000) | VM | apps (1201) |
| 2102 | `dnleve001` | EVE-NG | VM | apps (1201) |

### dc03 — Dell E6430 (PBS cross-node DR target)

| VMID | Hostname | Guest | Type | Zone (VLAN) |
|------|----------|-------|------|-------------|
| 3001–3049 | — | *reserved mgmt* | — | mgmt (1000) |
| 3401 | `dnlpbs002` | PBS (cross-node DR target) | VM | backup·pbs (1301) |

> **Notes / assumptions**
> - **All guests are VMs for now** (the CT range `50–98` is reserved for later).
> - **Two PBS instances**: dc01 local, M.2 (`1302`) + dc03 DR (`3401`). If PBS on dc03
>   is bare-metal, it has no VMID.
> - **Unmapped / pending (see OPEN-ITEMS):**
>   - **Graylog** — VMID `1007` and hostname `dnlglog001` are *proposed*; role code and
>     "alongside rsyslog?" still to confirm.
>   - **M.2 2242 role** — local PBS (`1302`) vs vzdump + TrueNAS replication target.
