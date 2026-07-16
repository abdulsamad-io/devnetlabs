# DevNetLabs — Low-Level Design (LLD)

Consolidated low-level view of the lab: physical topology, VLAN/L3 addressing, the
MikroTik data plane, Proxmox SDN VNets, and the full guest inventory (hostname ↔ VMID ↔
IP ↔ VLAN). This is the single detailed reference; it reconciles
[network-vlan-design.md](network-vlan-design.md), [vmid-plan.md](vmid-plan.md), and
[naming-convention.md](naming-convention.md), and supersedes the older hand-drawn
topology diagram (see [§9 Consistency review](#9-consistency-review--deltas-from-the-diagram)).

Address legend: **`STAT`** = static, **`RSV`** = DHCP reservation (to be created),
**`TBD`** = not yet assigned.

---

## 1. Purpose & scope

- 3 standalone Proxmox nodes (dc01/dc02/dc03) under PDM — **no Corosync cluster**.
- One MikroTik core doing gateway, DHCP, and inter-VLAN routing.
- Routed per-node service VLANs + a flat `lab_lan` for WiFi/wired admin access.

---

## 2. Physical topology

```
                                   ┌──────────────┐
                                   │   ISP / WAN  │
                                   └──────┬───────┘
                                          │ 0.0.0.0/0  (DHCP client, double-NAT, MTU 1598)
                                   ether4_igw  [srcnat masquerade]
                                          │
   lab_lan (VLAN 1, untagged)      ┌──────┴───────────────────────────┐
   172.16.254.0/24                 │       MikroTik RB951Ui-2HnD        │
   wlan1_WiFi  (SSID Home_Lab) ────┤     Home_Lab_Core_Router (7.22.3)  │
   ether5_mgt  (direct cable)  ────┤                                    │
   bridge_lab_lan, IP .1           │  bridge_shared_mgt  vlan-filtering  │
                                   │  /interface vlan SVIs + DHCP (all)  │
                                   └───┬───────────┬───────────┬────────┘
                              ether1_dc01     ether2_dc02   ether3_dc03
                              trunk tagged     trunk tagged  trunk tagged
                              1000,1101-1103   1000,1201     1000,1301
                                   │               │             │
                             ┌─────┴─────┐   ┌─────┴─────┐  ┌─────┴─────┐
                             │   dc01    │   │   dc02    │  │   dc03    │
                             │ GEEKOM    │   │ HPE ML150 │  │ Dell      │
                             │ IT13      │   │ G9        │  │ E6430     │
                             │ always-on │   │ on-demand │  │ DR target │
                             └───────────┘   └───────────┘  └───────────┘
```

---

## 3. Core router (MikroTik) — data plane

### 3.1 Bridges

| Bridge | Mode | Members | L3 |
|--------|------|---------|-----|
| `bridge_shared_mgt` | **`vlan-filtering=yes`** trunk bridge | `ether1_dc01`, `ether2_dc02`, `ether3_dc03` (tagged) | **No IP on bridge**; L3 on per-VLAN `/interface vlan` SVIs. Bridge is a **tagged member of every VLAN**. |
| `bridge_lab_lan` | flat / untagged (VLAN 1) | `ether5_mgt`, `wlan1_WiFi` | IP `172.16.254.1/24` on the bridge |

### 3.2 Port map

| Port | Role | Tagged / Untagged |
|------|------|-------------------|
| `ether1_dc01` | Trunk → dc01 | tagged 1000, 1101, 1102, 1103 |
| `ether2_dc02` | Trunk → dc02 | tagged 1000, 1201 |
| `ether3_dc03` | Trunk → dc03 | tagged 1000, 1301 |
| `ether4_igw` | WAN uplink | DHCP client, double-NAT behind home router, MTU 1598 |
| `ether5_mgt` | Admin (direct cable) | untagged, `bridge_lab_lan` (PVID 1) |
| `wlan1_WiFi` | Admin WiFi, SSID `Home_Lab` | untagged, `bridge_lab_lan` (PVID 1) |

---

## 4. VLAN / L3 addressing

| VLAN | Name | Subnet | Gateway (SVI) | Scope |
|------|------|--------|---------------|-------|
| 1000 | `shared_mgt` | 172.16.10.0/24 | 172.16.10.1 | All nodes (mgmt) |
| 1101 | `dc01_apps` | 10.110.10.0/24 | 10.110.10.1 | dc01 |
| 1102 | `dc01_media` | 10.110.20.0/24 | 10.110.20.1 | dc01 |
| 1103 | `dc01_nas` | 10.110.30.0/24 | 10.110.30.1 | dc01 |
| 1201 | `dc02_apps` | 10.120.10.0/24 | 10.120.10.1 | dc02 |
| 1301 | `dc03_pbs` | 10.130.10.0/24 | 10.130.10.1 | dc03 |
| 1 (untagged) | `lab_lan` | 172.16.254.0/24 | 172.16.254.1 | WiFi + ether5, flat L2 |

---

## 5. DHCP & reserved addresses (VLAN 1000)

- **DHCP:** `dhcp1` on `vlan_shared_mgt` + per-VLAN pools; `dhcp_lab_lan` pool
  `172.16.254.20–.254` (lease 10m).
- Routed VLANs hand out DNS `192.168.2.254, 8.8.8.8, 1.1.1.1`.
  ⚠️ **VLAN 1000 currently hands out no DNS** (open item).

| Address | Assignment | Host / use |
|---------|-----------|------------|
| 172.16.10.1 | STAT | Gateway (SVI `vlan_shared_mgt`) |
| 172.16.10.2 | STAT | `dnladm101` — bastion / jump host |
| 172.16.10.9 / .10 | STAT | **dc01 PVE mgmt** (⚠️ `.9` vs `.10` unresolved — open item) |
| 172.16.10.50 | STAT | **syslog VIP** (keepalived; `dnllog101`/`dnllog201`) |
| 172.16.10.51 | STAT | `dnllog101` — rsyslog collector (dc01, HA active) |
| 172.16.10.52 | STAT | `dnllog201` — rsyslog collector (dc02, HA standby) |
| 172.16.10.53 | STAT | `dnldns101` — Technitium DNS #1 (live) |
| 172.16.10.56 | RSV | `dnldns201` — Technitium DNS #2 |

---

## 6. Proxmox nodes & SDN VNets

Each node presents its VLANs as Proxmox **SDN VNets** on the VLAN-aware `vmbr0`; guest
NICs attach to a VNet. Host management for every node is on VLAN 1000 via `vmbrX.1000`.

### 6.1 dc01 — GEEKOM IT13 (always-on)

| VNet (VLAN) | Subnet | Guests |
|-------------|--------|--------|
| shared_mgt (1000) | 172.16.10.0/24 | `dnladm101` (bastion), `dnlnms101` (LibreNMS), `dnlnbx101` (NetBox), `dnllog101` (rsyslog, HA active), `dnllok101` (Loki), `dnldns101` (Technitium DNS #1), `dnlctl101` (Cloudflare tunnel) |
| dc01_apps (1101) | 10.110.10.0/24 | *(reserved — no services yet)* |
| dc01_media (1102) | 10.110.20.0/24 | `dnlplx101` (Plex / media transcode) |
| dc01_nas (1103) | 10.110.30.0/24 | `dnlnas101` (TrueNAS — DC S4500 passthrough), `dnlpbs101` (local PBS, M.2) |

### 6.2 dc02 — HPE ML150 G9 (on-demand, heavy/nested-virt)

| VNet (VLAN) | Subnet | Guests |
|-------------|--------|--------|
| shared_mgt (1000) | 172.16.10.0/24 | `dnldns201` (Technitium DNS #2), `dnllog201` (rsyslog, HA standby), `dnlgry201` (Graylog, on-demand) |
| dc02_apps (1201) | 10.120.10.0/24 | `dnlpnt201` (PNETLAB — mgmt NIC also on 1000), `dnleve201` (EVE-NG) |

### 6.3 dc03 — Dell E6430 (PBS DR target)

| VNet (VLAN) | Subnet | Guests |
|-------------|--------|--------|
| shared_mgt (1000) | 172.16.10.0/24 | *(reserved: VMIDs 3001–3049)* |
| dc03_pbs (1301) | 10.130.10.0/24 | `dnlpbs301` (PBS cross-node DR target) |

---

## 7. Guest inventory (master table)

| VMID | Hostname | Service | Type | Node | VLAN | IP |
|------|----------|---------|------|------|------|-----|
| 1002 | `dnladm101` | Admin / bastion (jump) | VM | dc01 | 1000 | 172.16.10.2 (STAT) |
| 1001 | `dnlnms101` | LibreNMS | VM | dc01 | 1000 | RSV/TBD |
| 1003 | `dnlnbx101` | NetBox (IPAM source of truth) | VM | dc01 | 1000 | RSV/TBD |
| 1004 | `dnllog101` | rsyslog collector (HA active) | VM | dc01 | 1000 | 172.16.10.51 (STAT) |
| 1005 | `dnldns101` | Technitium DNS #1 | VM | dc01 | 1000 | 172.16.10.53 (STAT) |
| 1006 | `dnlctl101` | Cloudflare tunnel | VM | dc01 | 1000 | RSV/TBD |
| 1201 | `dnlplx101` | Plex / media | VM | dc01 | 1102 | RSV/TBD |
| 1301 | `dnlnas101` | TrueNAS | VM | dc01 | 1103 | RSV/TBD |
| 1302 | `dnlpbs101` | PBS (local, M.2) | VM | dc01 | 1103 | RSV/TBD |
| 1901/1902 | — | Debian12 / Ubuntu24.04 templates | tmpl | dc01 | — | — |
| 1007 | `dnllok101` | Loki (log store) | VM | dc01 | 1000 | RSV/TBD |
| 2001 | `dnldns201` | Technitium DNS #2 | VM | dc02 | 1000 | 172.16.10.56 (RSV) |
| 2002 | `dnllog201` | rsyslog collector (HA standby) | VM | dc02 | 1000 | 172.16.10.52 (STAT) |
| 2003 | `dnlgry201` | Graylog (OpenSearch, on-demand) | VM | dc02 | 1000 | RSV/TBD |
| 2101 | `dnlpnt201` | PNETLAB | VM | dc02 | 1201 (+1000 mgmt) | RSV/TBD |
| 2102 | `dnleve201` | EVE-NG | VM | dc02 | 1201 | RSV/TBD |
| 3401 | `dnlpbs301` | PBS (cross-node DR) | VM | dc03 | 1301 | RSV/TBD |

---

## 8. Routing, NAT & security posture

- **Inter-VLAN routing is fully open** — no forward-chain firewall rules on the
  MikroTik. Any VLAN can currently reach any other.
- **NAT:** `srcnat masquerade out-interface=ether4_igw` (covers `lab_lan` too).
- **Bastion intent:** `dnladm101` (172.16.10.2) is the single SSH ingress. It only
  becomes a real control once devices are restricted to accept SSH **only from the
  bastion** — that firewall tightening is still pending (see open items).
- **OSPF:** a duplicate `ospf-instance-1` still needs cleanup (open item).

---

## 9. Consistency review — deltas from the diagram

The hand-drawn diagram is **structurally correct** — VLAN IDs, subnets, gateways, trunk
tagging (ether1–3), the WAN/ether4 path, and the `lab_lan` (VLAN 1) segment on
`wlan1`/`ether5` all match the design. The differences are in **service placement and
currency**, corrected in §6–§7 above:

| # | In the diagram | Issue | Corrected to |
|---|----------------|-------|--------------|
| 1 | (absent) | **Bastion `dnladm101` (172.16.10.2) missing** — built this session | Added to dc01 shared_mgt (1000) |
| 2 | `dns server` + `logserver` repeated in **every** VNET (App/Media/NAS/shared) | DNS and log services are **centralized in mgmt (1000)**, not per-zone | Only in shared_mgt VNets |
| 3 | Media VNET (1102): `logserver, dns server` | Wrong services for the media zone | `dnlplx101` (Plex) |
| 4 | NAS VNET (1103): `Proxmox backup server` only | **TrueNAS missing** — it's the primary NAS | `dnlnas101` (TrueNAS) **+** `dnlpbs101` (local PBS) |
| 5 | shared VNET: `logserver … Rsyslog` | Redundant — rsyslog **is** the logserver | Single `dnllog101` |
| 6 | `dns server` (generic) | DNS engine changed | **Technitium** (`dnldns101` / `dnldns201`) |
| 7 | `LiberNMS` | Typo | **LibreNMS** (`dnlnms101`) |
| 8 | (absent) | Cloudflare tunnel connector not shown | `dnlctl101` in shared_mgt (1000) |
| 9 | (absent) | Graylog (planned always-on) not shown | Listed as **pending** (unmapped VMID) |
| 10 | dc02 shared VNET: `logserver, dns server` | Not labelled as the secondary instances | `dnldns201` / `dnllog201` |
| 11 | Router `951UI` | Cosmetic | `RB951Ui-2HnD` |

**Still-open dependencies referenced above:** dc01 mgmt IP `.9` vs `.10`, M.2 2242 role
(local PBS vs vzdump), Graylog mapping, PNETLab placement — all tracked in
[OPEN-ITEMS.md](OPEN-ITEMS.md).
