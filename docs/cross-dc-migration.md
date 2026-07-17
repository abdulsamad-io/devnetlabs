# Cross-DC Migration Runbook — moving a VM between nodes

Because node identity is **encoded in three places** — the VMID's `N` digit, the
hostname's `<dc>` digit, and the DNS zone (`dcNN.devnetlabs.com`) — relocating a guest
to another node is **not transparent**. All three must be updated together (plus IP,
cert, and references) so they stay in agreement. This runbook is that procedure.

> **Invariant to preserve:** `VMID N` = hostname `<dc>` digit = DNS subdomain. After any
> move, all three must point at the guest's *current* node.

---

## When this applies (and when it doesn't)

- **Applies:** DR restore onto another node, maintenance evacuation, consolidation, or
  powering down the on-demand dc02 while keeping a service up elsewhere.
- **Doesn't really apply — rebuild instead:** storage-anchored guests can't move
  without their hardware — `dnlnas101` (passthrough SSD) and `dnlpbs101` (local M.2) are
  tied to dc01; `dnlpbs301` is the dc03 DR target by definition. These are node-locked.
- **Easiest to move:** the stateless mgmt tier on VLAN 1000 (DNS, log, NetBox,
  LibreNMS, Graylog, cloudflared, bastion) — VLAN 1000 spans all nodes, so the IP can
  often stay the same.

---

## Pre-flight

1. **Target VLAN exists on the new node?**
   - **mgmt VLAN 1000** spans all nodes → same subnet, **IP can stay**.
   - **Per-node VLANs** (apps 1101/1201, media 1102, nas 1103, pbs 1301) differ per node
     → the guest lands in a **different subnet** and **must be re-IP'd**.
2. **Pick the new identifiers:**
   - New **VMID** = target node's `N` + next free `SS` (e.g. dc03 mgmt → `30xx`).
   - New **hostname** = same role, `<dc>` digit = target node (e.g. `dnlnbx101` →
     `dnlnbx301`).
3. **Live vs offline:** live migration needs a compatible CPU model (`x86-64-v2-AES`,
   not `host`) across dissimilar hosts; otherwise migrate **offline** or restore from PBS.
4. **Back up / snapshot first**, and note the downtime window.

---

## Procedure

**1. Move the guest.**
Offline migrate via PDM, or restore from PBS — **set the target VMID** with the new
node's `N` digit (`qm` / restore dialog lets you choose the VMID).

**2. Rename the hostname.** Change the `<dc>` digit everywhere:
- Inside the guest: `/etc/hostname`, `/etc/hosts` (then `hostnamectl set-hostname …`).
- Proxmox VM **Name** = new hostname (avoid the name↔hostname drift).

**3. Re-IP (if the VLAN/subnet changed).** Set the guest's static IP for the target
node's subnet. On VLAN 1000 the IP can remain; on a per-node VLAN it must change.

**4. Update DNS (Technitium).**
- **Remove** the old `A` (and `PTR`) record from the **old** node's zone.
- **Add** `A` (+ `PTR`) for the **new** hostname/IP in the **new** node's zone.
- Repoint any **CNAMEs** that referenced the old FQDN.

**5. Update TLS.** Reissue/adjust the cert for the new FQDN — the new zone's wildcard
(`*.dcNN.devnetlabs.com`) covers it.

**6. Update everything that referenced the old name/IP:**
- SMB/NFS mounts (client `fstab`, mapped drives), Plex libraries
- Monitoring (LibreNMS/Graylog), backup jobs (PBS/vzdump targets)
- Ansible inventory / `host_vars`, client `/etc/hosts`
- MikroTik firewall address-lists (e.g. the bastion allow-list)

**7. Verify.** New FQDN resolves in the new zone; old records gone; connectivity and
services healthy; VMID/hostname/zone all agree.

**8. Update the docs.** Move the row in [vmid-plan.md](vmid-plan.md) to the target
node's table (new VMID + hostname), and update [lld.md](lld.md) (guest inventory, SDN
VNet table, reserved-address table) and the master mapping in
[naming-convention.md](naming-convention.md).

---

## Worked example — move `dnlnbx101` (NetBox) from dc01 → dc03

| | Before | After |
|---|--------|-------|
| VMID | `1003` | `3001` (first free dc03 mgmt) |
| Hostname | `dnlnbx101` | `dnlnbx301` |
| FQDN | `dnlnbx101.dc01.devnetlabs.com` | `dnlnbx301.dc03.devnetlabs.com` |
| VLAN / IP | 1000 / `172.16.10.x` | 1000 / **`172.16.10.x` (unchanged)** |

Steps: restore/migrate with target VMID `3001` → rename host `dnlnbx101`→`dnlnbx301`
(guest + Proxmox Name) → IP stays (VLAN 1000 spans nodes) → in Technitium, delete
`dnlnbx101` A/PTR from `dc01.devnetlabs.com`, add `dnlnbx301` in `dc03.devnetlabs.com`
→ reissue cert under `*.dc03.devnetlabs.com` → update NetBox references / monitoring /
Ansible → verify → update docs.

> Had this been a **per-node-VLAN** guest (e.g. something on apps 1101), step 3 would
> also require a **new IP** in the target node's subnet, and every consumer of the old
> IP would need updating too.

## Verification & success criteria

**✅ Success criteria — the move is complete when:**
- [ ] **VMID `N` = hostname `<dc>` = DNS zone** all agree on the *new* node (the invariant).
- [ ] The new FQDN resolves in the **new** zone; the **old** A/PTR are gone.
- [ ] The guest is reachable and its services are healthy on the new node.
- [ ] Every consumer (mounts, monitoring, backups, Ansible, firewall lists) points at the new name/IP.
- [ ] Docs updated: [vmid-plan.md](vmid-plan.md), [lld.md](lld.md), and the master mapping in [naming-convention.md](naming-convention.md).

**🧪 Test:**
```
getent hosts <new-fqdn>            # -> new IP, in the new zone
getent hosts <old-fqdn>            # -> NXDOMAIN (old record removed)
qm config <new-vmid> | grep name   # Proxmox Name = new hostname
```

**⚠️ Watch out for:**
- **Split identity** — updating only 2 of the 3 (VMID / hostname / zone) leaves a mismatch that bites later.
- **Stale references** — a missed consumer (mount, monitor, firewall list) silently breaks after the move.
- **Node-locked guests** — storage-anchored guests (`dnlnas101`, `dnlpbs101`, `dnlpbs301`) **rebuild**, not move.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| New FQDN won't resolve | A record not added to the new zone (or TTL cache) | add it in Technitium; flush the client's resolver cache |
| Old FQDN still resolves | old A/PTR not removed | delete them from the old node's zone |
| Live migration fails / VM won't boot on target | CPU model mismatch (`host` vs `x86-64-v2-AES`) | migrate **offline**, or restore from PBS with a common CPU baseline |
| VMID collision on target | target VMID already in use | pick the next free `SS` under the target node's `N` |
| Guest up but a consumer broke | a reference still points at the old name/IP | walk the step-6 list (mounts, monitoring, backups, Ansible, firewall) |
| Per-node-VLAN guest unreachable after move | still using the old subnet's IP | re-IP into the target node's subnet (step 3) |
| Cert warnings on the new FQDN | cert not reissued for the new zone | reissue under `*.dcNN.devnetlabs.com` (step 5) |

---

See also: [naming-convention.md](naming-convention.md) · [vmid-plan.md](vmid-plan.md) ·
[lld.md](lld.md)
