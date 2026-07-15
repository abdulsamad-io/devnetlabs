# Open Items & Next Steps

Unresolved questions and pending work, carried over from the working sessions.

## Unresolved decisions

1. **dc01 management IP: `172.16.10.9` vs `172.16.10.10`**
   PDM reported `.9`; the host `/etc/network/interfaces` shows `.10`. Confirm which
   is live (the one browsed on `:8006`) and reconcile everywhere.
2. **M.2 2242 SATA role on dc01** — two conflicting plans:
   - *Original:* **local PBS** (VMID 1302, `dnl-pbs-01`).
   - *Later:* **Proxmox vzdump backups + TrueNAS snapshot replication target.**
   Decide whether local PBS stays or is replaced by vzdump + ZFS replication.
3. ~~**Graylog** placement~~ — **RESOLVED.** Logging design set: rsyslog HA pair
   (`dnllog101`/`dnllog201`) cross-feeds **Loki** (`dnllok101`, dc01) + **Graylog**
   (`dnlgry201`, dc02, on-demand). See [logging-design.md](logging-design.md).
4. **PNETLab placement** — VMID plan puts PNETLAB on **dc02 (2101)**, but dc01's
   always-on stack lists an on-demand **"light PNETLab VM"**. Confirm intended split.

## Pending work

- [ ] **VLAN 1000 DHCP has no DNS** — add DNS servers (see network doc).
- [ ] **Duplicate OSPF instance name** `ospf-instance-1` on the MikroTik — fix.
- [ ] **Retry VM 202 migration** after ejecting both ISOs
      (`local:iso/windows-11-23h2.iso`, `local:iso/virtio-win-0.1.248.iso`);
      verify correct target node/direction and CPU baseline (offline, or set a
      common CPU type like `x86-64-v2-AES` instead of `host` — Raptor Lake vs
      Haswell/Broadwell cannot live-migrate with `host`).
- [ ] **Build the Cloudflare tunnel** (dc01 first, prove console, then extend).
- [ ] **Stand up NetBox** and load VMID/naming/IP data as the source of truth.
- [ ] **Confirm MikroTik config backups** `v4` (post `lab_lan`) and `v5`
      (post `vlan-filtering`) were exported.
- [ ] Implement via **Terraform (Cloudflare)** and **Ansible (Proxmox/MikroTik)**.

## dc01 hardware — current state

- CPU: i9-13900HK · **RAM: 64GB DDR4-3200** (2× Crucial CT32G4SFD832A, installed)
- **DC S4500 1.92TB SATA installed** (2.5" bay) → TrueNAS single-drive ZFS pool
- NVMe 1TB Gen4 (PVE OS + VM/LXC disks + OpenSearch indices + transcode temp)
- M.2 2242 SATA slot **open** (role pending — see decision #2)
- Stock 2× 16GB SK Hynix SO-DIMMs now **spare** (keep/resell)
