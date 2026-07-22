# One Proxmox VM, full-cloned from a cloud-init template. bpg/proxmox.
# NOTE: clone + explicit disk blocks is provider-version-sensitive — the first disk
# resizes the cloned OS disk, extra interfaces add data disks. Always `terraform plan`
# before apply and confirm no unintended disk recreation.

resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  vm_id       = var.vmid
  node_name   = var.node_name
  description = var.description
  tags        = var.tags
  on_boot     = var.onboot
  started     = var.started

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores   = var.cores
    sockets = var.sockets
    type    = var.cpu_type
  }

  memory {
    dedicated = var.memory_mb
  }

  dynamic "disk" {
    for_each = var.disks
    content {
      datastore_id = disk.value.datastore
      interface    = disk.value.interface
      size         = disk.value.size
      discard      = "on"
      ssd          = true
    }
  }

  dynamic "network_device" {
    for_each = var.networks
    content {
      bridge  = network_device.value.bridge
      vlan_id = network_device.value.vlan
    }
  }

  initialization {
    datastore_id = var.ci_datastore

    # One ip_config per NIC, in the same order as network_device.
    dynamic "ip_config" {
      for_each = var.networks
      content {
        ipv4 {
          address = coalesce(ip_config.value.ip, "dhcp")
          gateway = ip_config.value.gateway
        }
      }
    }

    dns {
      servers = var.dns_servers
      domain  = try(var.networks[0].search, null)
    }

    user_account {
      username = var.ci_user
      keys     = var.ci_ssh_keys
    }
  }

  lifecycle {
    # cloud-init/agent can report a changing disk/network ordering on re-read; ignore
    # cosmetic drift here rather than churn. Tighten once your plans are stable.
    ignore_changes = [initialization[0].user_account]
  }
}
