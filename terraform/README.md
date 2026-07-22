# Terraform

Terraform configs for DevNetLabs, one root module per concern:

| Path | Purpose | Provider |
|------|---------|----------|
| [`dc01_infra/`](dc01_infra/) | **dc01 VM provisioning** from a YAML inventory — clone-from-template + cloud-init, tags per the tagging plan | `bpg/proxmox` |
| [`technitium/`](technitium/) | Technitium **DNS + DHCP** (parity with `ansible/technitium/`; Ansible is the better fit — see its README) | `devops-rob/terracurl` |
| [`modules/proxmox_vm/`](modules/proxmox_vm/) | **Reusable module** — one Proxmox VM (clone, CPU/RAM/disks/NICs/cloud-init/tags). Used by `dc01_infra`; reuse for `dc02_infra`/`dc03_infra` | — |

Each root module is self-contained — `cd` into it, `terraform init/plan/apply`. Secrets
(API tokens) go via `TF_VAR_*` env vars, never in `tfvars`; state + `tfvars` are gitignored
at this level ([.gitignore](.gitignore)), but **`.terraform.lock.hcl` is committed** to pin
provider versions.

## Adding another node

dc02/dc03 are standalone nodes with their own APIs. Copy `dc01_infra/` to `dc02_infra/`,
point `providers.tf` at that node's endpoint, and write its `vms.yaml` — the shared
`modules/proxmox_vm` is unchanged.

## Relationship to Ansible

Terraform provisions the **VM shell + cloud-init identity**; the
[Ansible Linux baseline](../ansible/linux-baseline) does the **in-guest config** afterwards.
Two layers, run in that order. (#25)
