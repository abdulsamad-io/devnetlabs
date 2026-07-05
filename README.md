# DevNetLabs — Infrastructure as Code

Design documentation and (future) IaC for the **DevNetLabs** home lab.

- **Lab code:** `dnl`
- **Public domain:** `devnetlabs.com` (Cloudflare nameservers, Full setup)
- **Internal DNS zone:** `lab.devnetlabs.com`
- **Topology:** MikroTik core router + 3 standalone Proxmox VE nodes managed under
  Proxmox Datacenter Manager (PDM) — **not** a Corosync cluster.

## Design docs

| Doc | Purpose |
|-----|---------|
| [Low-Level Design (LLD)](docs/lld.md) | Consolidated topology, addressing, SDN VNets, guest inventory |
| [Network & VLAN design](docs/network-vlan-design.md) | MikroTik core, VLANs, bridges, DHCP, port map |
| [VMID plan](docs/vmid-plan.md) | `NZSS` global VMID numbering scheme + allocations |
| [Naming convention](docs/naming-convention.md) | `dnl-<role>-<NN>` guest naming, role codes, DNS |
| [Cloudflare tunnel](docs/cloudflare-tunnel.md) | Zero Trust tunnel publishing PVE UIs |
| [Bastion setup](docs/bastion-setup.md) | Jump host build + hardening runbook (incl. Windows key gen) |

## Nodes

| Node | Hardware | Role |
|------|----------|------|
| Core router | MikroTik RB951Ui-2HnD (RouterOS 7.22.3) | Gateway, DHCP, inter-VLAN routing |
| **dc01** | GEEKOM IT13 (i9-13900HK, 64GB DDR4-3200) | Primary **always-on** node |
| **dc02** | HPE ML150 G9 (Xeon E5 v3/v4) | Heavy / nested-virt, **powered on on demand** |
| **dc03** | Dell E6430 | PBS cross-node DR target |

## Open items

See [`docs/OPEN-ITEMS.md`](docs/OPEN-ITEMS.md) for unresolved questions and next steps.

> These docs capture **current state as of the working sessions**. IaC (Terraform for
> Cloudflare, Ansible for Proxmox/MikroTik) will be added under `terraform/` and
> `ansible/` in later tasks.
