# DevNetLabs — Infrastructure as Code

Design documentation and (future) IaC for the **DevNetLabs** home lab.

- **Lab code:** `dnl`
- **Public domain:** `devnetlabs.com` (Cloudflare nameservers, Full setup)
- **Internal DNS zones (per-node):** `dc01.devnetlabs.com` / `dc02.devnetlabs.com` / `dc03.devnetlabs.com`
- **Topology:** MikroTik core router + 3 standalone Proxmox VE nodes managed under
  Proxmox Datacenter Manager (PDM) — **not** a Corosync cluster.

## Design docs

Grouped to match the `docs/` folder layout.

### Reference & platform (`docs/`)
| Doc | Purpose |
|-----|---------|
| [Low-Level Design (LLD)](docs/lld.md) | Consolidated topology, addressing, SDN VNets, guest inventory — **start here** |
| [Bastion setup](docs/bastion-setup.md) | Jump host build + hardening runbook (incl. Windows key gen) |
| [TrueNAS setup](docs/truenas-setup.md) | TrueNAS VM build, disk passthrough, ZFS pool, shares |
| [NetBox setup](docs/netbox-setup.md) | NetBox DCIM/IPAM source of truth — native install + data model |
| [Cloudflare tunnel](docs/cloudflare-tunnel.md) | Zero Trust tunnel publishing PVE UIs |
| [Cross-DC migration](docs/cross-dc-migration.md) | Moving a VM between nodes (VMID + hostname + DNS) |

### Conventions (`docs/conventions/`)
| Doc | Purpose |
|-----|---------|
| [Naming convention](docs/conventions/naming-convention.md) | `dnl<role><dc><nn>` guest naming, role codes, per-node DNS |
| [VMID plan](docs/conventions/vmid-plan.md) | `NZSS` global VMID numbering scheme + allocations |
| [Tagging plan](docs/conventions/tagging-plan.md) | Proxmox VM tags — function/location/placement/availability/backup/HA |

### Network (`docs/network/`)
| Doc | Purpose |
|-----|---------|
| [Network & VLAN design](docs/network/network-vlan-design.md) | MikroTik core, VLANs, bridges, DHCP, port map |
| [DHCP migration](docs/network/dhcp-migration.md) | Move DHCP MikroTik→Technitium (relay, scopes, break-glass) |

### Logging (`docs/logging/`)
| Doc | Purpose |
|-----|---------|
| [Logging design](docs/logging/logging-design.md) | rsyslog HA → cross-feed Loki (dc01) + Graylog (dc02) |
| [rsyslog setup](docs/logging/rsyslog-setup.md) | Central collector: vendor/category tree, classification, rotation, forwarding |
| [rsyslog install script](docs/logging/rsyslog-install-script.md) | Copy-paste collector config, line-by-line explained |
| [keepalived VIP](docs/logging/keepalived-setup.md) | Floating VIP 172.16.10.70 across the log collectors (HA) |
| [Log collector VMs](docs/logging/log-collector-setup.md) | Build the dnllog101/dnllog201 Ubuntu collector VMs |
| [Log source onboarding](docs/logging/log-source-onboarding.md) | Per-device syslog client config (Cisco/Juniper/ASA/PAN-OS/FortiGate/Windows/…) |
| [Loki setup](docs/logging/loki-setup.md) | Loki log store (`dnllok101`) — filesystem/TSDB, 60-day retention |

### Monitoring (`docs/monitoring/`)
| Doc | Purpose |
|-----|---------|
| [Grafana setup](docs/monitoring/grafana-setup.md) | Grafana frontend over Loki + Prometheus (`dnlgrf101`) |
| [Prometheus setup](docs/monitoring/prometheus-setup.md) | Prometheus + `snmp_exporter` (`dnlprm101`), file_sd targets |
| [SNMP source onboarding](docs/monitoring/snmp-source-onboarding.md) | Per-device SNMPv2c/v3 config for Prometheus |

## Nodes

| Node | Hardware | Role |
|------|----------|------|
| Core router | MikroTik RB951Ui-2HnD (RouterOS 7.22.3) | Gateway, DHCP, inter-VLAN routing |
| **dc01** | GEEKOM IT13 (i9-13900HK, 64GB DDR4-3200) | Primary **always-on** node |
| **dc02** | HPE ML150 G9 (Xeon E5 v3/v4) | Heavy / nested-virt, **powered on on demand** |
| **dc03** | Dell E6430 | PBS cross-node DR target |

## Infrastructure as Code

| Path | Purpose |
|------|---------|
| [`ansible/`](ansible/README.md) | Technitium DNS + DHCP across `dnldns101`/`dnldns201` from one source (**preferred**) |
| [`terraform/technitium/`](terraform/technitium/README.md) | Terraform equivalent of the Technitium setup (via `terracurl`) |

More to come (e.g. Terraform for the Cloudflare tunnel).

## Open items

See [`docs/OPEN-ITEMS.md`](docs/OPEN-ITEMS.md) for unresolved questions and next steps.

> These docs capture **current state as of the working sessions**.
