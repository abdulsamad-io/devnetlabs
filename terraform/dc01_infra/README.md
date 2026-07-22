# Terraform — dc01 infrastructure (`dc01_infra`)

Provisions **dc01's VMs** from a single [`vms.yaml`](vms.yaml), using the shared
[`../modules/proxmox_vm`](../modules/proxmox_vm) module (bpg/proxmox, clone-from-template
+ cloud-init). dc01 is a **standalone** PDM-managed node, so this root targets dc01's own
API; add sibling `dc02_infra/` / `dc03_infra/` later reusing the same module.

> **Scaffold — validate before relying** (same spirit as [`../technitium`](../technitium)).
> I can't run `terraform plan` against your PVE from here; treat the module as a starting
> point and confirm with `plan` — especially the clone+disk reconciliation, which is
> provider-version-sensitive.

## Add / remove / resize a VM

Edit **`vms.yaml`** — one entry per guest; `defaults:` covers the common values, each VM
overrides what it needs. Tags come from [tagging-plan.md](../../docs/conventions/tagging-plan.md),
VMIDs from [vmid-plan.md](../../docs/conventions/vmid-plan.md).
```yaml
- name: dnlgrf101
  vmid: 1105
  disks: [{ interface: scsi0, size: 32 }]
  networks: [{ vlan: 1101, ip: "10.110.10.71/24", gateway: "10.110.10.1", search: dc01.devnetlabs.com }]
  tags: [dc01, zone-apps, tier-monitoring, av-always-on, bkp-pbs, ha-none]
```

## Prerequisites

- **A cloud-init-ready template** on dc01 (default `template_vmid: 1902` = `tmpl-ubuntu2604`,
  Ubuntu 26.04 LTS): built from the Ubuntu cloud image with `qemu-guest-agent` present.
  Without cloud-init in the image, IP/user/key injection won't apply. Build steps:
  [../../docs/proxmox-cloud-init-template.md](../../docs/proxmox-cloud-init-template.md).
- **A PVE API token** with VM.* perms. Provide via env (never in tfvars):
  ```bash
  export TF_VAR_pve_api_token='terraform@pve!tf=<uuid>'
  ```
- **SSH reach to dc01** for the provider (bpg uploads cloud-init snippets over SSH) — the
  agent/user in `providers.tf`.
- Terraform ≥ 1.5.

## Usage
```bash
cd terraform/dc01_infra
cp terraform.tfvars.example terraform.tfvars      # edit endpoint / ci keys
export TF_VAR_pve_api_token='terraform@pve!tf=<uuid>'
terraform init
terraform plan            # ALWAYS review first
terraform apply
```

## ⚠️ Already-built VMs — import first

Most dc01 guests already exist (built by hand per the runbooks). A bare `apply` would try
to **create a duplicate VMID and fail**. For each existing VM, adopt it into state first:
```bash
# bpg import id format: <node>/<vmid>
terraform import 'module.vm["dnllog101"].proxmox_virtual_environment_vm.this' dc01/1004
terraform import 'module.vm["dnldns101"].proxmox_virtual_environment_vm.this' dc01/1005
# …repeat for dnladm101(1002) dnlnbx101(1003) dnllok101(1104) dnlgrf101(1105) dnlukm101(1107)
```
Then `terraform plan` and reconcile the YAML to match reality (sizes/tags) so the plan is
clean. **New** guests (`dnllbr101`, `dnlctl101`, `dnlprm101`, `dnlnfy101`, `dnlplx101`)
apply directly with no import.

## Not managed here

Appliance / non-Ubuntu / passthrough guests are **out of scope** for the clone module and
stay on their runbooks (noted at the bottom of `vms.yaml`): `dnlpnt101` (PNETLab),
`dnleve101` (EVE-NG), `dnlnas101` (TrueNAS), `dnlpbs101` (PBS), and the `1901/1902`
templates (the clone sources).

## After provisioning

Terraform creates the VM + cloud-init identity; the **[Ansible Linux baseline](../../ansible/linux-baseline)**
then does the in-guest config (DNS/NTP/SSH/ufw/updates/syslog). Add the new host to that
inventory and run it.

See also: [../README.md](../README.md) · [lld.md](../../docs/lld.md) ·
[tagging-plan.md](../../docs/conventions/tagging-plan.md)
