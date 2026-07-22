# Provision all dc01 VMs from vms.yaml. Edit the YAML to add/remove/resize guests;
# Terraform loops the shared module once per entry. Tags come from conventions/tagging-plan.md.

locals {
  cfg      = yamldecode(file("${path.module}/vms.yaml"))
  defaults = local.cfg.defaults

  # Shallow-merge defaults <- per-VM (per-VM keys win; disks/networks/tags are per-VM).
  vms = { for vm in local.cfg.vms : vm.name => merge(local.defaults, vm) }
}

module "vm" {
  source   = "../modules/proxmox_vm"
  for_each = local.vms

  name          = each.value.name
  vmid          = each.value.vmid
  node_name     = var.node_name
  template_vmid = each.value.template_vmid
  description   = try(each.value.description, "Managed by Terraform — dc01_infra")
  tags          = each.value.tags
  onboot        = try(each.value.onboot, true)

  cores     = each.value.cores
  sockets   = try(each.value.sockets, 1)
  cpu_type  = each.value.cpu_type
  memory_mb = each.value.memory_mb

  disks    = each.value.disks
  networks = each.value.networks

  dns_servers = try(each.value.dns_servers, [])
  ci_user     = var.ci_user
  ci_ssh_keys = var.ci_ssh_keys
}

output "vms" {
  value = { for k, m in module.vm : k => { vmid = m.vmid, ip = m.ipv4_addresses } }
}
