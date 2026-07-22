output "vmid" {
  value = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  value = proxmox_virtual_environment_vm.this.name
}

output "ipv4_addresses" {
  description = "IPv4 addresses reported by the guest agent (once booted)."
  value       = try(proxmox_virtual_environment_vm.this.ipv4_addresses, null)
}
