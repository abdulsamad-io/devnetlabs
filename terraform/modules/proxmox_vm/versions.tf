terraform {
  required_version = ">= 1.5"
  required_providers {
    # Version is pinned by the root module (e.g. dc01_infra); the module only
    # declares the source so it composes with whatever the caller pins.
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}
