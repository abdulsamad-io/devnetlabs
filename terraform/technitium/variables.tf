variable "primary_url" {
  description = "dnldns101 (primary) API base URL"
  type        = string
  default     = "http://172.16.10.53:5380"
}

variable "secondary_url" {
  description = "dnldns201 (secondary) API base URL"
  type        = string
  default     = "http://172.16.10.56:5380"
}

variable "api_token" {
  description = "Technitium API token (same admin token on both). Pass via TF_VAR_api_token; never commit."
  type        = string
  sensitive   = true
}

variable "primary_ns" {
  description = "Primary name-server address the secondary transfers from"
  type        = string
  default     = "172.16.10.53"
}

variable "forwarders" {
  type    = list(string)
  default = ["192.168.2.254", "1.1.1.1"]
}

variable "blocklist_urls" {
  type    = list(string)
  default = []
}

variable "zones" {
  description = "Zone names; records read from ../../ansible/zones/<name>.zone (shared source of truth)"
  type        = list(string)
}

variable "dhcp_scopes" {
  description = "Shared scope definitions (ranges supplied per host)"
  type = list(object({
    name        = string
    mask        = string
    router      = string
    dns         = string
    domain      = string
    lease_hours = number
  }))
  default = []
}

variable "primary_dhcp_ranges" {
  description = "Per-scope range for the primary (map scope_name => {start,end})"
  type        = map(object({ start = string, end = string }))
  default     = {}
}

variable "secondary_dhcp_ranges" {
  description = "Per-scope range for the secondary (non-overlapping with primary)"
  type        = map(object({ start = string, end = string }))
  default     = {}
}
