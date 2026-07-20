# Ansible

Two independent Ansible projects, one per subfolder:

| Project | Purpose | Connection |
|---------|---------|------------|
| [`technitium/`](technitium/) | Technitium **DNS + DHCP** for `dnldns101`/`dnldns201` from one source of truth (zones + scopes + settings) | HTTP API (`connection: local`) — no SSH |
| [`linux-baseline/`](linux-baseline/) | Reusable **Linux baseline** across all Ubuntu guests (DNS, chrony, SSH, ufw, unattended-upgrades… + opt-in hardening) | SSH + sudo |

Each subfolder is self-contained (its own `ansible.cfg`, `inventory.yml`, `site.yml`,
`roles/`) — `cd` into it and run `ansible-playbook site.yml`. See each project's README.

Secrets (`secrets.yml`, vault password, `*.plain.yml`) are git-ignored at this level
([.gitignore](.gitignore)) and must never be committed in plaintext.

> More to come (e.g. Proxmox/MikroTik automation — [#25](../docs/OPEN-ITEMS.md)).
