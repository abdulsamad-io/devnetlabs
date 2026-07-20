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
| **4001** | **`dc01_lab_oob`** | **10.251.0.0/16** | **10.251.0.1** | **dc01 — lab-node OOB mgmt** |
| **4002** | **`dc02_lab_oob`** | **10.252.0.0/16** | **10.252.0.1** | **dc02 — lab-node OOB mgmt** |
| 1 (untagged) | `lab_lan` | 172.16.254.0/24 | 172.16.254.1 | WiFi + ether5, flat L2 |

> **Lab OOB (4001/4002)** — out-of-band management plane for devices *inside* the lab
> emulators (PNETLab/EVE-NG). The emulator host bridges each lab device's mgmt port onto
> this VLAN (via a PNETLab "cloud"), so lab devices get a DHCP address here and use it as
> their **syslog + SNMP source**. Per-node like the apps VLANs: **4001 exists only on the
> dc01 trunk, 4002 only on dc02**. See [Lab OOB management networks](#lab-oob-management-networks-4001--4002) below.

**Technitium DNS servers** at `172.16.10.53` (dnldns101, live) / `172.16.10.54` (dnldns201, planned) on VLAN 1000.

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
| `ether1_dc01` | Trunk → dc01 | tagged 1000, 1101–1103, **4001** |
| `ether2_dc02` | Trunk → dc02 | tagged 1000, 1201, **4002** |
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

- **Baseline: no forward-chain firewall rules** → inter-VLAN routing between the *infra*
  VLANs (1000/110x/120x/130x/lab_lan) is **fully open**.
- **Exception — the lab OOB VLANs (4001/4002) are scoped-isolated** (the router's first
  forward rules): OOB may reach DNS/NTP + the syslog VIP + the internet and be SNMP-polled
  by Prometheus, but is **blocked from every other internal segment**. Rules are in
  [Lab OOB management networks](#lab-oob-management-networks-4001--4002) below.
- `srcnat masquerade out-interface=ether4_igw` provides internet (covers `lab_lan` and,
  because it's un-scoped by source, the OOB VLANs too — no extra NAT rule needed).

---

## Lab OOB management networks (4001 / 4002)

Out-of-band management plane for the network devices emulated inside PNETLab/EVE-NG. The
emulator host (`dnlpnt101`/`dnleve101` on dc01, `dnlpnt201`/`dnleve201` on dc02) carries a
**second NIC** on this VLAN and exposes it to labs as a PNETLab **cloud** (`pnet1`); a lab
device's mgmt port attached to that cloud lands directly on the OOB L2 segment, gets a
DHCP lease (relayed to Technitium), and uses that OOB address as its **syslog + SNMP
source**. Per-node, mirroring the apps VLANs:

| VLAN | Name | Subnet | GW (SVI) | Trunk | Emulator hosts |
|------|------|--------|----------|-------|----------------|
| 4001 | `dc01_lab_oob` | 10.251.0.0/16 | 10.251.0.1 | `ether1_dc01` | `dnlpnt101`, `dnleve101` (planned) |
| 4002 | `dc02_lab_oob` | 10.252.0.0/16 | 10.252.0.1 | `ether2_dc02` | `dnlpnt201`, `dnleve201` |

> Apply everything below **from `lab_lan` in Safe Mode** (traffic to the router's own IPs
> terminates locally and never traverses the filtered bridge — same rule as the
> `vlan-filtering` change). Rollback is `/interface vlan remove` + `/ip firewall filter remove`.

### 1 — VLAN SVIs + bridge-VLAN membership

```
/interface vlan
add name=vlan_dc01_lab_oob interface=bridge_shared_mgt vlan-id=4001 comment="dc01 lab OOB"
add name=vlan_dc02_lab_oob interface=bridge_shared_mgt vlan-id=4002 comment="dc02 lab OOB"

/ip address
add address=10.251.0.1/16 interface=vlan_dc01_lab_oob comment="dc01_lab_oob GW"
add address=10.252.0.1/16 interface=vlan_dc02_lab_oob comment="dc02_lab_oob GW"

# tag each VLAN toward its node's trunk AND the bridge itself (SVIs need the bridge tagged)
/interface bridge vlan
add bridge=bridge_shared_mgt vlan-ids=4001 tagged=bridge_shared_mgt,ether1_dc01
add bridge=bridge_shared_mgt vlan-ids=4002 tagged=bridge_shared_mgt,ether2_dc02
```

### 2 — DHCP relay → Technitium (DHCP stays on Technitium)

Same pattern as [dhcp-migration.md](dhcp-migration.md): the relay unicasts to Technitium
and stamps `giaddr` (= the SVI IP) so it picks the right scope. Build the scopes
`vlan4001-dc01_lab_oob` (10.251.0.0/16) and `vlan4002-dc02_lab_oob` (10.252.0.0/16) in
Technitium first, then:
```
/ip dhcp-relay
add name=relay_4001 interface=vlan_dc01_lab_oob dhcp-server=172.16.10.53 local-address=10.251.0.1 disabled=no
add name=relay_4002 interface=vlan_dc02_lab_oob dhcp-server=172.16.10.53 local-address=10.252.0.1 disabled=no
```
> **Include `disabled=no`** or the relay comes up disabled and the VLAN gets no DHCP.

### 3 — Scoped isolation firewall (the router's first forward rules)

The OOB plane is **isolated**: it may reach DNS + NTP + the syslog VIP + the internet, and
be SNMP-polled by Prometheus — nothing else internal. An `interface list` keeps the rules
compact and covers both OOB VLANs:
```
/interface list add name=OOB comment="lab OOB mgmt VLANs (4001/4002)"
/interface list member add list=OOB interface=vlan_dc01_lab_oob
/interface list member add list=OOB interface=vlan_dc02_lab_oob

/ip firewall filter
# --- general hygiene (safe to add even though the chain was empty) ---
add chain=forward action=accept connection-state=established,related comment="est/rel"
add chain=forward action=drop   connection-state=invalid            comment="drop invalid"
# --- OOB permitted egress ---
add chain=forward action=accept in-interface-list=OOB out-interface=ether4_igw comment="OOB -> internet"
add chain=forward action=accept in-interface-list=OOB protocol=udp dst-address=172.16.10.53 dst-port=53  comment="OOB -> DNS #1"
add chain=forward action=accept in-interface-list=OOB protocol=tcp dst-address=172.16.10.53 dst-port=53
add chain=forward action=accept in-interface-list=OOB protocol=udp dst-address=172.16.10.54 dst-port=53  comment="OOB -> DNS #2"
add chain=forward action=accept in-interface-list=OOB protocol=tcp dst-address=172.16.10.54 dst-port=53
add chain=forward action=accept in-interface-list=OOB protocol=udp dst-address=172.16.10.70 dst-port=514 comment="OOB -> syslog VIP"
add chain=forward action=accept in-interface-list=OOB protocol=tcp dst-address=172.16.10.70 dst-port=514
# --- Prometheus SNMP poll INTO the OOB devices (apps -> OOB, UDP/161) ---
add chain=forward action=accept out-interface-list=OOB protocol=udp dst-port=161 src-address=10.110.10.72 comment="dnlprm101 -> OOB SNMP"
add chain=forward action=accept out-interface-list=OOB protocol=udp dst-port=161 src-address=10.120.10.72 comment="dnlprm201 -> OOB SNMP"
# --- isolate: drop everything else to/from OOB (est/rel above already lets replies through) ---
add chain=forward action=drop in-interface-list=OOB  comment="OOB -> other internal: drop"
add chain=forward action=drop out-interface-list=OOB comment="other -> OOB: drop"

# --- mgmt plane: what OOB may send TO the router itself (input chain) ---
add chain=input action=accept in-interface-list=OOB protocol=udp dst-port=67  comment="OOB DHCP relay (bootps)"
add chain=input action=accept in-interface-list=OOB protocol=udp dst-port=123 comment="OOB NTP to router (if enabled)"
add chain=input action=accept in-interface-list=OOB protocol=icmp            comment="OOB ping gateway"
add chain=input action=drop   in-interface-list=OOB                          comment="OOB -> router: nothing else"
```
- The forward `drop in/out-interface-list=OOB` rules are the **only** rules that touch the
  otherwise-open posture, and they're **scoped to OOB** — the infra VLANs stay fully open.
- **Internet still works** via the existing `srcnat masquerade out-interface=ether4_igw`
  (un-scoped by source) — no NAT change. Place the `input` rules **before** any broad
  LAN-accept so the OOB drop actually takes effect.
- Prometheus polling is **apps → OOB** (initiated by `dnlprm101`/`dnlprm201`); replies ride
  `established,related`. Syslog is **OOB → VIP** (initiated by the lab device).

### 4 — Verify

```
/interface vlan print where name~"lab_oob"                 # both SVIs up
/ip address print where interface~"lab_oob"                # 10.251.0.1 / 10.252.0.1
/interface bridge vlan print where vlan-ids~"400"          # 4001->ether1, 4002->ether2, bridge tagged
/ip dhcp-relay print                                       # relay_4001/4002 disabled=no
/ip firewall filter print stats where comment~"OOB"        # rules matching, counters climbing
```
- From a lab device: gets a 10.251/10.252 lease, resolves via Technitium, reaches the
  internet, **cannot** ping an infra host (e.g. `10.110.10.71`), and a syslog line reaches
  the VIP. From `dnlprm101`: `snmpwalk` to the device's OOB IP succeeds.

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
    address 172.16.10.9/24       # dc01 PVE mgmt (dc02 = .10; confirmed via :8006, #17)
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
