variable "pve_endpoint" {
  type        = string
  description = "dc01 PVE API endpoint, e.g. https://172.16.10.9:8006/"
}

variable "pve_api_token" {
  type        = string
  sensitive   = true
  description = "PVE API token 'user@realm!tokenid=<uuid>'. Provide via TF_VAR_pve_api_token, never in tfvars."
}

variable "pve_insecure" {
  type    = bool
  default = true
}

variable "pve_ssh_user" {
  type    = string
  default = "root"
}

variable "node_name" {
  type    = string
  default = "dc01"
}

# --- cloud-init identity applied to every VM (override per-VM in the module if needed) ---
variable "ci_user" {
  type    = string
  default = "abdoolsamad"
}

variable "ci_ssh_keys" {
  type        = list(string)
  description = "Public keys injected into every VM via cloud-init (e.g. the bastion control key + your laptop key)."
  default     = []
}
