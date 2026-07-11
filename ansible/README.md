# Ansible — Technitium DNS + DHCP

Manage **both** Technitium servers (`dnldns101` primary, `dnldns201` secondary) from a
single source of truth. See [../docs/naming-convention.md](../docs/naming-convention.md)
(DNS/split-horizon) and [../docs/dhcp-migration.md](../docs/dhcp-migration.md).

> **Status: scaffold.** The structure and patterns are ready; the Technitium API
> endpoint/parameter names should be **validated against your running version** (browse
> `http://<host>:5380/api` on the server) before relying on it. Treat as a starting point.

## How it works

- Tasks call the **Technitium HTTP API** from the control node (`connection: local`) —
  **no SSH** into the DNS servers.
- **DNS records** live once, as BIND zone files in [`zones/`](zones/). They're imported
  to the **primary**; the **secondary** receives them via **zone transfer** (AXFR/IXFR).
  You edit records in one place and **bump the SOA serial**.
- **DHCP scopes** and **server settings** don't replicate, so they're pushed to **both**.
  DHCP ranges are **split** per host (`host_vars/`) so the two servers never hand out the
  same address.

## Layout

```
ansible/
  ansible.cfg
  inventory.yml                 # dnldns101 (primary) + dnldns201 (secondary)
  group_vars/technitium.yml     # shared: forwarders, blocklists, zone list, DHCP scope defs
  host_vars/dnldns101.yml       # role: primary  ; DHCP low range
  host_vars/dnldns201.yml       # role: secondary; DHCP high range
  zones/*.zone                  # BIND zone files = single source for DNS records
  site.yml
  roles/technitium/tasks/{settings,zones,dhcp}.yml
```

## Prerequisites

- Ansible on the control node; network reach to `:5380` on both servers.
- A **Technitium API token** (Administration → create a non-expiring token).
  **Never commit it in plaintext.** Provide it one of these ways:
  - vault: `ansible-vault create secrets.yml` → put `technitium_api_token: "..."`
  - or `-e technitium_api_token=...` at runtime.

## Usage

```bash
cd ansible
ansible-playbook site.yml -e @secrets.yml            # or --ask-vault-pass

# scope it:
ansible-playbook site.yml -e @secrets.yml --tags dns
ansible-playbook site.yml -e @secrets.yml --tags dhcp --limit dnldns101
```

## Workflow for changes

- **Add/change a DNS record:** edit the relevant `zones/<zone>.zone`, **bump the SOA
  serial**, run with `--tags dns`. The primary imports it; the secondary transfers it.
- **Change DHCP:** edit `group_vars` (scope defn) or `host_vars` (range split), run
  `--tags dhcp`.
- **Later:** NetBox becomes the upstream source of truth that *generates* the zone files
  and scope data.
