# VMID Numbering Plan

Scheme: **`NZSS`** (4 digits).

| Field | Meaning | Values |
|-------|---------|--------|
| `N` | Node | `1`=dc01, `2`=dc02, `3`=dc03 |
| `Z` | Zone (VLAN) | `0`=mgmt/1000, `1`=apps/1101&1201, `2`=media/1102, `3`=nas/1103, `4`=backup·pbs/1301, `9`=templates |
| `SS` | Sequence | `01–49`=VM, `50–98`=CT, `99`=spare |

**Design principles**
- **Globally unique across all nodes** (even though standalone/PDM only needs
  per-node uniqueness) so **PBS backups restore onto any node without collision**.
- Apply the VMID **at create time** (override the GUI auto-suggestion) and **at
  restore time** (set the target VMID).
- Put placement/role metadata in **Proxmox tags**, not encoded beyond the VMID.

---

## Allocations

| VMID | Guest | Type | Node | Zone (VLAN) |
|------|-------|------|------|-------------|
| 1050 | LibreNMS | CT | dc01 | mgmt (1000) |
| 1051 | NetBox | CT | dc01 | mgmt (1000) |
| 1052 | rsyslog / logserver | CT | dc01 | mgmt (1000) |
| 1053 | Pi-hole #1 (.55) | CT | dc01 | mgmt (1000) |
| 1054 | Cloudflare tunnel (`dnl-cftun-01`) | CT | dc01 | mgmt (1000) |
| 1250 | Plex | CT | dc01 | media (1102) |
| 1301 | TrueNAS | VM | dc01 | nas (1103) |
| 1302 | PBS (local, M.2) | VM | dc01 | nas (1103) |
| 1950 / 1951 | Debian12 / Ubuntu 24.04 templates | tmpl | dc01 | — |
| 2050 | Pi-hole #2 (.56) | CT | dc02 | mgmt (1000) |
| 2051 | logserver (secondary) | CT | dc02 | mgmt (1000) |
| 2101 | PNETLAB | VM | dc02 | apps (1201) + mgmt NIC on 1000 |
| 2102 | EVE-NG | VM | dc02 | apps (1201) |
| 3401 | PBS (cross-node DR target) | VM | dc03 | backup (1301) |
| 3001–3049 | reserved mgmt | — | dc03 | mgmt (1000) |

> **Notes / assumptions**
> - Guest-vs-CT type is a sensible default, **not confirmed** for every entry.
> - **Two PBS instances**: dc01 local (M.2) + dc03 DR. If PBS on dc03 is bare-metal,
>   it has no VMID.
> - **Unmapped (pending decisions — see OPEN-ITEMS):**
>   - **Graylog VM** (OpenSearch, dc01, ~6–8GB) — no VMID/zone assigned yet.
>   - **M.2 2242 role** — local PBS (1302) vs vzdump + TrueNAS replication target.
