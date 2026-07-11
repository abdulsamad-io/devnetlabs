# Server settings — applied to BOTH servers (settings don't replicate).
# NOTE: verify endpoint/param names against your Technitium version (http://<host>:5380/api).

resource "terracurl_request" "forwarders" {
  name           = "forwarders"
  url            = "${var.api_url}/api/settings/set?token=${var.api_token}&forwarders=${join(",", var.forwarders)}&forwarderProtocol=Udp"
  method         = "POST"
  response_codes = ["200"]
}

resource "terracurl_request" "blocklists" {
  count          = length(var.blocklist_urls) > 0 ? 1 : 0
  name           = "blocklists"
  url            = "${var.api_url}/api/settings/set?token=${var.api_token}&blockListUrls=${join(",", var.blocklist_urls)}"
  method         = "POST"
  response_codes = ["200"]
}
