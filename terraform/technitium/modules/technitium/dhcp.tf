# DHCP scopes — pushed to BOTH servers (DHCP doesn't replicate). Ranges come per host
# (split so the two servers never hand out the same address). A scope is only applied
# on a host that has a range for it.
# NOTE: verify endpoint/param names against your Technitium version.

locals {
  scope_by_name = { for s in var.dhcp_scopes : s.name => s }
}

resource "terracurl_request" "dhcp_scope" {
  for_each = var.dhcp_ranges

  name = "scope-${each.key}"
  url = join("", [
    "${var.api_url}/api/dhcp/scopes/set?token=${var.api_token}",
    "&name=${each.key}",
    "&startingAddress=${each.value.start}",
    "&endingAddress=${each.value.end}",
    "&subnetMask=${local.scope_by_name[each.key].mask}",
    "&routerAddress=${local.scope_by_name[each.key].router}",
    "&dnsServers=${local.scope_by_name[each.key].dns}",
    "&domainName=${local.scope_by_name[each.key].domain}",
    "&leaseTimeDays=0&leaseTimeHours=${local.scope_by_name[each.key].lease_hours}",
  ])
  method                 = "POST"
  response_codes         = ["200"]
  destroy_url            = "${var.api_url}/api/dhcp/scopes/delete?token=${var.api_token}&name=${each.key}"
  destroy_method         = "POST"
  destroy_response_codes = ["200"]
}

resource "terracurl_request" "dhcp_enable" {
  for_each = var.dhcp_ranges

  name           = "scope-enable-${each.key}"
  url            = "${var.api_url}/api/dhcp/scopes/enable?token=${var.api_token}&name=${each.key}"
  method         = "POST"
  response_codes = ["200"]

  depends_on = [terracurl_request.dhcp_scope]
}
