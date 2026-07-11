# Network & VLAN Design

Core router: **MikroTik RB951Ui-2HnD**, RouterOS **7.22.3**
Identity: `Home_Lab_Core_Router` · Serial: `6433063E74C3`

The MikroTik provides the gateway, DHCP, and inter-VLAN routing for the entire lab.

---

## VLANs

| VLAN | Name | Subnet | Gateway | Scope |
|------|------|--------|---------|-------|
| 1000 | `shared_mgt` | 172.16.10.0/24 | 172.16.10.1 | All DCs (tagged on trunks) |
| 1101 | `dc01_apps` | 10.110.10.0/24 | 10.110.10.1 | dc01 |
| 1102 | `dc01_plex/media` | 10.110.20.0/24 | 10.110.20.1 | dc01 |
| 1103 | `dc01_truenas/nas` | 10.110.30.0/24 | 10.110.30.1 | dc01 |
| 1201 | `dc02_apps` | 10.120.10.0/24 | 10.120.10.1 | dc02 |
| 1301 | `dc03_pbs` | 10.130.10.0/24 | 10.130.10.1 | dc03 |
| 1 (untagged) | `lab_lan` | 172.16.254.0/24 | 172.16.254.1 | WiFi + ether5, flat L2 |

**Technitium DNS servers** at `172.16.10.53` (dnldns101, live) / `172.16.10.56` (dnldns201, planned) on VLAN 1000.

---

## Bridges

The MikroTik runs **two bridges**:

### `bridge_shared_mgt` — VLAN trunk bridge
- **`vlan-filtering=yes`** (enabled this session — see notes below).
- Carries **only the three tagged trunks** (ether1–3).
- **No IP on the bridge itself** — all L3 lives on `/interface vlan` SVIs on top.
- The **bridge interface is a tagged member of every VLAN** in the bridge-VLAN table
  (required for the SVIs to receive traffic once filtering is on).
- Hosts DHCP server `dhcp1` on `vlan_shared_mgt` plus per-VLAN pools.

### `bridge_lab_lan` — flat/untagged L2
- IP `172.16.254.1/24` directly on the bridge.
- DHCP server `dhcp_lab_lan`, pool `172.16.254.20-172.16.254.254`, lease 10m.
- Holds **`ether5_mgt`** + **`wlan1_WiFi`** (SSID `Home_Lab`).
- Member of interface list `LAN`.

---

## MikroTik port map

| Port | Role | VLANs |
|------|------|-------|
| `ether1_dc01` | Trunk → dc01 | tagged 1000, 1101–1103 |
| `ether2_dc02` | Trunk → dc02 | tagged 1000, 1201 |
| `ether3_dc03` | Trunk → dc03 | tagged 1000, 1301 |
| `ether4_igw`  | WAN, DHCP client | **double-NAT** behind home router, MTU 1598 |
| `ether5_mgt`  | on `bridge_lab_lan` | untagged (was VLAN 1000 access port) |
| `wlan1_WiFi`  | on `bridge_lab_lan`, SSID `Home_Lab` | untagged (was VLAN 1000 access port) |

---

## DHCP / DNS

- Routed VLANs hand out DNS: `192.168.2.254, 8.8.8.8, 1.1.1.1`.
- **VLAN 1000 currently hands out NO DNS** — outstanding fix:
  ```
  /ip dhcp-server network set [find address=172.16.10.0/24] \
      dns-server=192.168.2.254,8.8.8.8,1.1.1.1
  ```
  (or the Technitium servers once they exist).
- Look up current guest leases with:
  `/ip dhcp-server lease print where server=dhcp1`

---

## Routing / firewall

- **No forward-chain firewall rules** → inter-VLAN routing is **fully open**.
- `srcnat masquerade out-interface=ether4_igw` provides internet (covers `lab_lan` too).

---

## Proxmox host networking (dc01)

`eno1` (manual) → `vmbr0` (VLAN-aware trunk, **no IP**, `bridge-vids 2-4094`) →
`vmbr0.1000` (management IP).

```
iface eno1 inet manual

auto vmbr0
iface vmbr0 inet manual
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094

auto vmbr0.1000
iface vmbr0.1000 inet static
    address 172.16.10.10/24      # NOTE: confirm .9 vs .10 (see OPEN-ITEMS)
    gateway 172.16.10.1
```

- Host management IP lives **only** on `vmbr0.1000` (tagged VLAN 1000), never on the
  bare bridge (avoids duplicate route / boot-order roulette).
- dc01 uses Proxmox **SDN VNets** (VLAN zones) on `vmbr0`; VM NICs attach to a VNet.
- Verify: `ip -br addr show` (IP only on `vmbr0.1000`), `ip route show`
  (one /24 via `vmbr0.1000`, one default).

---

## Lessons / gotchas (MikroTik + Proxmox VLANs)

- With `vlan-filtering=no`, untagged access ports **cannot** reach a tagged
  `/interface vlan` SVI — the SVI only catches tagged frames. Either enable
  filtering (with PVID + untagged membership) or use a flat bridge with the IP on
  the bridge. *(This was the root cause of the WiFi/ether5 DHCP failure — filtering
  had never actually been enabled on `bridge_shared_mgt` despite prior belief.)*
- When enabling `vlan-filtering`, the **bridge interface must be a tagged member**
  of every VLAN whose SVI needs traffic, or L3 to those SVIs is lost.
- Do the `vlan-filtering=yes` change **from `lab_lan`** (traffic to the router's own
  IPs terminates locally and never traverses the filtered bridge) + Safe Mode.
  Rollback is always `vlan-filtering=no`.
- Making `vmbr0` VLAN-aware moves the **host** management onto tagged VLANs too — the
  host IP must sit on `vmbrX.<vlan>`, not the bare bridge, or it dies on a
  tagged-only trunk (and `bridge-vids 2-4094` excludes untagged/VLAN 1).
- Never leave the same IP on both a bridge and its VLAN sub-interface.

---

## Config backups

- `my_config_backup_v2.rsc`, `my_config_backup_v3.rsc` — pre-`vlan-filtering` states.
- Recommended: `my_config_backup_v4` (post `lab_lan`), `my_config_backup_v5`
  (post `vlan-filtering`). **Confirm these were exported.**
