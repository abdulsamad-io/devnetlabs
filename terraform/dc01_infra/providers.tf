# dc01 is a STANDALONE node (PDM-managed, no cluster) — this points at dc01's own API.
# Add sibling dc02_infra/ dc03_infra/ later, each with its own endpoint, reusing the module.
provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token # via env: export TF_VAR_pve_api_token='user@realm!tokenid=<uuid>'
  insecure  = var.pve_insecure  # true for the self-signed PVE cert

  # bpg uploads cloud-init snippets over SSH to the node, so it needs SSH reach to dc01.
  ssh {
    agent    = true
    username = var.pve_ssh_user
  }
}
