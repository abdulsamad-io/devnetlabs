# Reusable Proxmox VM module (bpg/proxmox). Clones a cloud-init template and
# applies CPU/RAM/disks/NICs/cloud-init/tags. One instance per guest.

variable "name" {
  type        = string
  description = "Guest hostname, e.g. dnllok101 (dnl<role><dc><nn>)."
}

variable "vmid" {
  type        = number
  description = "Global VMID (NZSS scheme, see conventions/vmid-plan.md)."
}

variable "node_name" {
  type        = string
  description = "Proxmox node to create the VM on (standalone node, e.g. dc01)."
}

variable "template_vmid" {
  type        = number
  description = "VMID of the cloud-init-ready template to full-clone (e.g. 1902 = tmpl-ubuntu2404)."
}

variable "description" {
  type    = string
  default = "Managed by Terraform"
}

variable "tags" {
  type        = list(string)
  default     = []
  description = "Proxmox tags, per conventions/tagging-plan.md (e.g. [dc01, zone-apps, tier-logging, ...])."
}

variable "onboot" {
  type    = bool
  default = true
}

variable "started" {
  type    = bool
  default = true
}

# --- sizing ---
variable "cores" {
  type    = number
  default = 2
}

variable "sockets" {
  type    = number
  default = 1
}

variable "cpu_type" {
  type        = string
  default     = "x86-64-v2-AES" # portable across dc01/dc02; use "host" only for nested-virt (PNETLab)
  description = "Proxmox CPU type."
}

variable "memory_mb" {
  type    = number
  default = 4096
}

# --- storage: first entry is the (resized) OS disk cloned from the template; extras are new data disks ---
variable "disks" {
  type = list(object({
    interface = string           # scsi0, scsi1, ...
    size      = number           # GiB
    datastore = optional(string, "local-lvm")
  }))
}

# --- networking: one entry per NIC. cloud-init IP is set per NIC in order ---
variable "networks" {
  type = list(object({
    bridge  = optional(string, "vmbr0")
    vlan    = optional(number)   # VLAN tag (omit for untagged)
    ip      = optional(string)   # "10.110.10.70/24" or "dhcp"; omit an OOB/L2-only NIC
    gateway = optional(string)
    search  = optional(string)   # DNS search domain for this host (first NIC used for cloud-init DNS)
  }))
}

# --- cloud-init ---
variable "dns_servers" {
  type    = list(string)
  default = []
}

variable "ci_user" {
  type    = string
  default = "abdoolsamad"
}

variable "ci_ssh_keys" {
  type        = list(string)
  description = "Public keys injected via cloud-init (safe to commit)."
  default     = []
}

variable "ci_datastore" {
  type    = string
  default = "local-lvm"
}
