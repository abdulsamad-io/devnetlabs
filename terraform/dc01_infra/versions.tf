terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111" # latest 0.111.1 (Jul 2026); allows 0.111.x. Check the registry for newer.
    }
  }
}
