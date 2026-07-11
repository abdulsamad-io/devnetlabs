variable "api_url" { type = string }

variable "api_token" {
  type      = string
  sensitive = true
}

variable "role" {
  type = string # "primary" | "secondary"
}

variable "primary_ns" {
  type    = string
  default = ""
}

variable "zones" {
  type    = list(string)
  default = []
}

variable "zone_records" {
  type    = map(string) # zone name => BIND zone file content
  default = {}
}

variable "forwarders" {
  type    = list(string)
  default = []
}

variable "blocklist_urls" {
  type    = list(string)
  default = []
}

variable "dhcp_scopes" {
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

variable "dhcp_ranges" {
  type    = map(object({ start = string, end = string }))
  default = {}
}
