# DHCP Migration Runbook — MikroTik → Technitium

Move DHCP from the MikroTik core to **Technitium** (`dnldns101`, `172.16.10.53`, VLAN
1000), gaining automatic DNS registration, while keeping the MikroTik DHCP servers as
**disabled break-glass**.

> **Hard rule:** never run two DHCP servers *hot* on the same subnet — they race to
> answer `DISCOVER`s and hand out conflicting leases. Break-glass = **standby (disabled)**,
> not parallel.

---

## Key concept — DHCP doesn't cross L3

DHCP is broadcast-based, so Technitium (on VLAN 1000) can **directly** serve only VLAN
1000. Every **other** subnet reaches it via a **DHCP relay** on the MikroTik (the
gateway), which unicasts requests to `172.16.10.53` and stamps `giaddr` so Technitium
picks the right scope.

| Subnet | Serve method | Status |
|--------|--------------|--------|
| VLAN 1000 (172.16.10.0/24) | **Direct** (Technitium is attached here) | ✅ done |
| dc01_apps 1101 / media 1102 / nas 1103 | Relay | ✅ done |
| dc02_apps 1201, dc03_pbs 1301 | Relay | ✅ done |
| lab_lan (172.16.254.0/24) | Relay | ⬜ pending |

---

## Cautions before you start

- **Blast radius:** consolidating DHCP onto Technitium means one box now serves **DNS
  *and* DHCP** — an outage takes down both. Mitigate by standing up **`dnldns201`**
  (redundant Technitium) and/or keeping the break-glass ready (below).
- **Do it incrementally** — migrate **VLAN 1000 + lab_lan** first (where the hosts are),
  leave the rest on MikroTik until you're happy.
- Capture the current MikroTik state first: `/ip dhcp-server export` and
  `/ip dhcp-server lease print` (record any static leases to recreate as reservations).

---

## Step 1 — Build the scopes in Technitium

Technitium UI → **DHCP → Scopes → Add**, one per subnet you're migrating. For each:

| Field | Value (example: VLAN 1000) |
|-------|----------------------------|
| Network / mask | `172.16.10.0` / `255.255.255.0` |
| Range | mirror the current MikroTik pool |
| Router (gateway) | `172.16.10.1` |
| DNS server | `172.16.10.53` |
| Domain | `dc01.devnetlabs.com` (per-pool; use the matching node zone for per-node VLANs) |
| Lease time | match current (e.g. 10m on lab_lan) |

- **Enable DNS auto-registration:** set the scope **Domain Name** to a zone Technitium
  is authoritative for, so leases auto-create **A + PTR** records. (This is the payoff
  vs MikroTik.)
- **Recreate static leases** as **reservations** (MAC → IP).

Repeat for `lab_lan` and each per-node VLAN as you migrate them.

---

## Step 2 — DHCP relay on the MikroTik (all non-1000 subnets)

VLAN 1000 needs **no** relay (Technitium is directly attached). For every other subnet,
add a relay pointing at Technitium, with `local-address` = that subnet's SVI:

```
/ip dhcp-relay add name=relay_lab_lan interface=bridge_lab_lan    dhcp-server=172.16.10.53 local-address=172.16.254.1 disabled=no
/ip dhcp-relay add name=relay_1101    interface=vlan_dc01_apps    dhcp-server=172.16.10.53 local-address=10.110.10.1 disabled=no
/ip dhcp-relay add name=relay_1102    interface=vlan_dc01_plex    dhcp-server=172.16.10.53 local-address=10.110.20.1 disabled=no
/ip dhcp-relay add name=relay_1103    interface=vlan_dc01_truenas dhcp-server=172.16.10.53 local-address=10.110.30.1 disabled=no
/ip dhcp-relay add name=relay_1201    interface=vlan_dc02_apps    dhcp-server=172.16.10.53 local-address=10.120.10.1 disabled=no
/ip dhcp-relay add name=relay_1301    interface=vlan_dc03_pbs     dhcp-server=172.16.10.53 local-address=10.130.10.1 disabled=no
```

*(Only add relays for the subnets you're cutting over in this pass.)*

---

## Step 3 — Cut over each subnet (disable, don't delete)

For each migrated subnet, **disable** the corresponding MikroTik server — keep the
config for break-glass:
```
/ip dhcp-server disable [find name=dhcp1]          # VLAN 1000
/ip dhcp-server disable [find name=dhcp_lab_lan]   # lab_lan
# …etc per pool
```
(For a directly-attached subnet like VLAN 1000 there's no relay to enable — just disable
the MikroTik server and Technitium takes over. For relayed subnets, ensure the relay
from Step 2 is enabled at the same time.)

---

## Step 4 — Verify

On a client in each migrated subnet:
```
# Windows:  ipconfig /release  &&  ipconfig /renew
# Linux:    sudo dhclient -r && sudo dhclient
```
Confirm:
- Lease now appears in **Technitium → DHCP → Leases** (not on the MikroTik).
- Client got the right gateway + DNS (`172.16.10.53`).
- An **A/PTR record auto-appeared** in the matching zone.

---

## Cutover as executed (VLAN 1000 + 1101/1102/1103/1201/1301)

**Technitium scopes** on `dnldns101`: `vlan1000-shared_mgt` (`172.16.10.100–.199`,
direct), and `vlan1101-dc01_apps` / `vlan1102-dc01_media` / `vlan1103-dc01_nas` /
`vlan1201-dc02_apps` / `vlan1301-dc03_pbs` (each `.50–.150`, **relay-only** — they show
Interface `0.0.0.0` in Technitium; matched by `giaddr`).

**On the MikroTik (Safe Mode):**

VLAN 1000 — direct, just disable the local server:
```
/ip dhcp-server disable [find interface=vlan_shared_mgt]
```

VLANs 1101/1102/1103/1201/1301 — disable local server **and** add a relay each:
```
/ip dhcp-server disable [find interface=vlan_dc01_apps]
/ip dhcp-server disable [find interface=vlan_dc01_plex]
/ip dhcp-server disable [find interface=vlan_dc01_truenas]
/ip dhcp-server disable [find interface=vlan_dc02_apps]
/ip dhcp-server disable [find interface=vlan_dc03_pbs]

/ip dhcp-relay add name=relay_1101 interface=vlan_dc01_apps    dhcp-server=172.16.10.53 local-address=10.110.10.1 disabled=no
/ip dhcp-relay add name=relay_1102 interface=vlan_dc01_plex    dhcp-server=172.16.10.53 local-address=10.110.20.1 disabled=no
/ip dhcp-relay add name=relay_1103 interface=vlan_dc01_truenas dhcp-server=172.16.10.53 local-address=10.110.30.1 disabled=no
/ip dhcp-relay add name=relay_1201 interface=vlan_dc02_apps    dhcp-server=172.16.10.53 local-address=10.120.10.1 disabled=no
/ip dhcp-relay add name=relay_1301 interface=vlan_dc03_pbs     dhcp-server=172.16.10.53 local-address=10.130.10.1 disabled=no
```
`local-address` = the SVI IP = the `giaddr` Technitium matches to the scope's subnet.
An interface can't run a DHCP server and relay at once — disable the server first.
**Include `disabled=no`** — a relay added without it can come up disabled, leaving the
VLAN with no DHCP (server off *and* relay off).

---

## Break-glass — MikroTik standby

If Technitium fails, fail back to the MikroTik in seconds:
```
/ip dhcp-relay disable [find dhcp-server=172.16.10.53]   # stop relaying
/ip dhcp-server enable [find name=dhcp1]                 # re-enable local server(s)
# …enable the other pools as needed
```
Clients pick up MikroTik leases on next renewal (keep lease times short-ish so failback
is quick).

**Per-VLAN failback (as-built):**
```
# Relayed VLANs (1101/1102/1103/1201/1301) — drop the relay, re-enable the local server:
/ip dhcp-relay  disable [find interface=vlan_dc01_apps]
/ip dhcp-server enable  [find interface=vlan_dc01_apps]      # repeat per interface

# VLAN 1000 (direct) — just re-enable the local server:
/ip dhcp-server enable  [find interface=vlan_shared_mgt]
```
> The MikroTik standby scopes for VLAN 1000 hand out `192.168.2.254, 1.1.1.1` and the
> routed VLANs already did — so name resolution survives a Technitium outage on failback.

> ⚠️ **Make the standby DNS resilient.** Because Technitium is currently your *only* DNS,
> an outage kills name resolution too. The MikroTik break-glass scopes must hand out a
> DNS that works *without* Technitium — e.g. `192.168.2.254, 1.1.1.1` (or `dnldns201`
> once it exists) — or clients get an IP but can't resolve anything.

---

## Rollback

Identical to break-glass: disable the Technitium scope (or the relay), re-enable the
MikroTik server. Because the MikroTik config was only *disabled*, never deleted, rollback
is instant and lossless.

---

## Status & remaining

- ✅ **Done:** VLAN 1000 (direct) + `1101` / `1102` / `1103` / `1201` / `1301` (relay).
  MikroTik servers for these are **disabled/standby**; relays point at `172.16.10.53`.
- ⬜ **Pending — lab_lan** (needs a Technitium scope, then relay + disable):
  ```
  /ip dhcp-relay add name=relay_lablan interface=bridge_lab_lan dhcp-server=172.16.10.53 local-address=172.16.254.1 disabled=no
  /ip dhcp-server disable [find interface=bridge_lab_lan]
  ```
- ⬜ **Prereq still recommended:** stand up **`dnldns201`** so DNS+DHCP isn't
  single-homed on `dnldns101` now that both run there.

---

See also: [network-vlan-design.md](network-vlan-design.md) · [lld.md](lld.md) ·
[OPEN-ITEMS.md](OPEN-ITEMS.md)
