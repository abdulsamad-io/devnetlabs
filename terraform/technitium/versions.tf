terraform {
  required_version = ">= 1.5"

  required_providers {
    # No official Technitium provider exists. terracurl wraps the Technitium
    # HTTP API (imperative, query-param calls) as create/destroy requests.
    terracurl = {
      source  = "devops-rob/terracurl"
      version = "~> 1.2"
    }
  }
}
