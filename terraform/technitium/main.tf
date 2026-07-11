# Two Technitium servers managed from one config, mirroring the Ansible role.
# DNS records live once as BIND zone files in ../../ansible/zones/ (shared with the
# Ansible scaffold); they're imported to the PRIMARY, and the SECONDARY transfers them.

locals {
  # Read the shared zone files (single source of truth for records).
  zone_records = { for z in var.zones : z => file("${path.module}/../../ansible/zones/${z}.zone") }
}

module "primary" {
  source = "./modules/technitium"

  api_url        = var.primary_url
  api_token      = var.api_token
  role           = "primary"
  zones          = var.zones
  zone_records   = local.zone_records
  forwarders     = var.forwarders
  blocklist_urls = var.blocklist_urls
  dhcp_scopes    = var.dhcp_scopes
  dhcp_ranges    = var.primary_dhcp_ranges
}

module "secondary" {
  source = "./modules/technitium"

  api_url        = var.secondary_url
  api_token      = var.api_token
  role           = "secondary"
  primary_ns     = var.primary_ns
  zones          = var.zones
  forwarders     = var.forwarders
  blocklist_urls = var.blocklist_urls
  dhcp_scopes    = var.dhcp_scopes
  dhcp_ranges    = var.secondary_dhcp_ranges
}
