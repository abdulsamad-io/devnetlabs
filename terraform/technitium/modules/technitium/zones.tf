# DNS zones.
#  primary:   create Primary zones + import records from the shared .zone files
#  secondary: create Secondary zones that transfer from the primary
# Records are maintained once (the .zone files → primary); the secondary receives them
# via AXFR/IXFR. Bump the SOA serial in the .zone file on every change.
# NOTE: verify endpoint/param names against your Technitium version.

# ---------- PRIMARY ----------
resource "terracurl_request" "primary_zone" {
  for_each = var.role == "primary" ? toset(var.zones) : toset([])

  name                   = "zone-${each.value}"
  url                    = "${var.api_url}/api/zones/create?token=${var.api_token}&zone=${each.value}&type=Primary"
  method                 = "POST"
  response_codes         = ["200"]
  destroy_url            = "${var.api_url}/api/zones/delete?token=${var.api_token}&zone=${each.value}"
  destroy_method         = "POST"
  destroy_response_codes = ["200"]
}

resource "terracurl_request" "primary_records" {
  for_each = var.role == "primary" ? toset(var.zones) : toset([])

  name           = "records-${each.value}"
  url            = "${var.api_url}/api/zones/import?token=${var.api_token}&zone=${each.value}&overwrite=true"
  method         = "POST"
  headers        = { "Content-Type" = "application/x-www-form-urlencoded" }
  request_body   = "importRecords=${urlencode(var.zone_records[each.value])}"
  response_codes = ["200"]

  depends_on = [terracurl_request.primary_zone]
}

# ---------- SECONDARY ----------
resource "terracurl_request" "secondary_zone" {
  for_each = var.role == "secondary" ? toset(var.zones) : toset([])

  name                   = "seczone-${each.value}"
  url                    = "${var.api_url}/api/zones/create?token=${var.api_token}&zone=${each.value}&type=Secondary&primaryNameServerAddresses=${var.primary_ns}"
  method                 = "POST"
  response_codes         = ["200"]
  destroy_url            = "${var.api_url}/api/zones/delete?token=${var.api_token}&zone=${each.value}"
  destroy_method         = "POST"
  destroy_response_codes = ["200"]
}
