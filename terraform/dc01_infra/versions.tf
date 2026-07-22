terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66" # check registry.terraform.io/providers/bpg/proxmox for the current release
    }
  }
}
