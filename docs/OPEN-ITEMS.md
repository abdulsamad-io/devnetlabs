# Open Items & Next Steps

Tracked as GitHub issues **#17–#31** (assigned to @abdulsamad-io). This file is the
human-readable index; the issues hold the working detail.

## Unresolved decisions

| # | Decision | Issue |
|---|----------|-------|
| 1 | **M.2 2242 role on dc01** — local PBS (`dnlpbs101`) vs vzdump + TrueNAS ZFS replication target | [#18] |
| 2 | **PNETLab placement** — dc02 (`dnlpnt201`) vs a light on-demand dc01 (`dnlpnt101`) | [#19] |

> **Resolved:**
> - dc01/dc02 PVE mgmt IPs — **dc01 = `172.16.10.9`, dc02 = `172.16.10.10`** (node `.10`
>   still named `abdulsamad`, rename pending). Confirmed via `:8006` — #17.
> - Shared mgmt-VLAN DNS zone — **`mgt.devnetlabs.com`** (node-neutral) for VLAN 1000;
>   per-node zones stay for the per-node VLANs — #28.

## Pending work

- [ ] **OSPF** — fix the duplicate `ospf-instance-1` on the MikroTik — [#20]
- [ ] **VM 202 migration** — eject ISOs, verify target/direction, common CPU baseline (`x86-64-v2-AES`) or offline — [#21]
- [ ] **lab_lan DHCP → Technitium** — scope + relay + disable local server — [#26]
- [ ] **`dnldns201`** — second Technitium (de-SPOF DNS + DHCP; secondary zones + split DHCP) — [#27]
- [ ] **Build the logging tier** — keepalived VIP + rsyslog collector + Loki (dc01) + Graylog (dc02) — [#30]
- [ ] **nxlog on Windows hosts** — Event Log → syslog to the VIP (`compute/windows`); depends on [#30] — [#38]
- [ ] **Rename deployed guests** to `dnl<role><dc><nn>` (e.g. `netbox`→`dnlnbx101`) + align live hostnames/configs — [#29]
- [ ] **Cloudflare tunnel** — `dnlctl101`, publish `pve.devnetlabs.com` (dc01 first) — [#22]
- [ ] **NetBox** — stand up `dnlnbx101` (native + full DCIM/IPAM; see [netbox-setup.md](netbox-setup.md)), load VMID/naming/IP data as source of truth — [#23]
- [ ] **NetBox integration outputs** — decide + build which artifacts the SoT generates (rsyslog `sources.json`, Prometheus SNMP `file_sd`, Technitium DNS, Ansible inventory); depends on [#23] — [#62]
- [ ] **rsyslog `sources.json` from NetBox** — generate the IP→category/vendor classification from NetBox (SoT) + `SIGHUP` reload; Ansible-templating deferred; depends on [#23] — [#33]
- [ ] **Internal-CA TLS** — replace the public Let's Encrypt wildcard with an internal CA (`pki` role) — [#31]
- [ ] **MikroTik backups** — confirm `my_config_backup_v4`/`v5` were exported — [#24]
- [ ] **IaC** — Terraform (Cloudflare) + Ansible (Proxmox/MikroTik), beyond the existing Technitium `ansible/`+`terraform/` — [#25]

## Recently resolved

- ✅ **Graylog placement** — Loki (dc01) + Graylog (dc02, on-demand), fed by an rsyslog HA
  pair — see [logging-design.md](logging-design.md).
- ✅ **VLAN 1000 DHCP had no DNS** — resolved by the DNS cutover to Technitium
  (`172.16.10.53` / `.54`).
- ✅ **DHCP migration** — VLAN 1000 (direct) + `1101/1102/1103/1201/1301` (relay) moved to
  Technitium; MikroTik servers disabled as break-glass — see [dhcp-migration.md](dhcp-migration.md).
- ✅ **dnldns101 IP** — corrected to `172.16.10.53` (was documented `.55`).

## dc01 hardware — current state

- CPU: i9-13900HK · **RAM: 64GB DDR4-3200** (2× Crucial CT32G4SFD832A, installed)
- **DC S4500 1.92TB SATA installed** (2.5" bay) → TrueNAS single-drive ZFS pool
- NVMe 1TB Gen4 (PVE OS + VM/LXC disks + OpenSearch indices + transcode temp)
- M.2 2242 SATA slot **open** (role pending — see [#18])
- Stock 2× 16GB SK Hynix SO-DIMMs now **spare** (keep/resell)

<!-- issue links -->
[#17]: https://github.com/abdulsamad-io/devnetlabs/issues/17
[#18]: https://github.com/abdulsamad-io/devnetlabs/issues/18
[#19]: https://github.com/abdulsamad-io/devnetlabs/issues/19
[#20]: https://github.com/abdulsamad-io/devnetlabs/issues/20
[#21]: https://github.com/abdulsamad-io/devnetlabs/issues/21
[#22]: https://github.com/abdulsamad-io/devnetlabs/issues/22
[#23]: https://github.com/abdulsamad-io/devnetlabs/issues/23
[#24]: https://github.com/abdulsamad-io/devnetlabs/issues/24
[#25]: https://github.com/abdulsamad-io/devnetlabs/issues/25
[#26]: https://github.com/abdulsamad-io/devnetlabs/issues/26
[#27]: https://github.com/abdulsamad-io/devnetlabs/issues/27
[#28]: https://github.com/abdulsamad-io/devnetlabs/issues/28
[#29]: https://github.com/abdulsamad-io/devnetlabs/issues/29
[#30]: https://github.com/abdulsamad-io/devnetlabs/issues/30
[#31]: https://github.com/abdulsamad-io/devnetlabs/issues/31
[#33]: https://github.com/abdulsamad-io/devnetlabs/issues/33
[#38]: https://github.com/abdulsamad-io/devnetlabs/issues/38
[#62]: https://github.com/abdulsamad-io/devnetlabs/issues/62
