# VM / Guest Naming Convention

Format: **`dnl<role><NNN>`** — lowercase, no separators.

Example: **`dnladm001`** (admin/bastion host, instance 001).

- **`dnl`** — lab prefix (DevNetLabs).
- **`<role>`** — role code: **exactly 3 lowercase letters** (see table below).
- **`<NNN>`** — 3-digit instance, **global per role**: `001` for a singleton,
  `002+` for pairs / HA members.
- **Node-agnostic** — the name is the guest's *identity*; the VMID encodes *placement*.
  Names therefore survive cross-node PBS restore.

> **Scheme change:** this flat `dnl<role><NNN>` form (no hyphens, 3-digit instance)
> **supersedes** the earlier hyphenated `dnl-<role>-<NN>` convention. Existing guests
> should be renamed to the new form as they are (re)built.

---

## Role codes

Every role code is **exactly 3 lowercase letters**.

| Code | Service |
|------|---------|
| `adm` | Admin / bastion (jump) host |
| `nms` | LibreNMS |
| `nbx` | NetBox |
| `log` | rsyslog / logserver |
| `dns` | Technitium DNS Server |
| `plx` | Plex |
| `nas` | TrueNAS |
| `pbs` | Proxmox Backup Server |
| `pnt` | PNETLAB |
| `eve` | EVE-NG |
| `ctl` | Cloudflare tunnel connector (cloudflared) |
| `gry` | Graylog |

**Reserved for future use (3-letter):** `git`, `awx`, `vlt` (Vault), `grf` (Grafana),
`tsd` (time-series DB), `dkr` (Docker), `k8s` (Kubernetes), `prx` (reverse proxy),
`pki` (internal CA), `adc` (Active Directory).

> **Avoid `dc`** — it means *node* in this topology.
> **Templates** use their own `tmpl-<os><ver>` pattern (see below), exempt from the
> 3-letter role rule.
> **Graylog** now uses `gry` — VMID/placement still pending (see OPEN-ITEMS).

---

## Templates

Templates keep their own pattern (they encode OS/version rather than an instance
sequence): **`tmpl-<os><ver>[-variant]`**.

Examples: `tmpl-deb12-base`, `tmpl-ubn2404-docker`.

---

## DNS

- Internal zone: **`lab.devnetlabs.com`**, served by **Technitium DNS Server** as an
  authoritative primary zone. A records follow the hostname,
  e.g. `dnladm001.lab.devnetlabs.com`.
- Per-zone subdomains (e.g. `mgmt.lab.devnetlabs.com`) are supported **natively** by
  Technitium zones — no custom dnsmasq needed (unlike Pi-hole's flat records).
- Technitium also provides recursive resolution / conditional forwarding, block
  lists (ad/tracker filtering, replacing Pi-hole), DNSSEC, DoH/DoT, and a full HTTP
  API + config export suitable for IaC (Ansible/Terraform).
- Keep the **public apex `devnetlabs.com` separate** from the internal zone.
- **Let's Encrypt wildcard `*.lab.devnetlabs.com` via DNS-01** gives publicly-trusted
  TLS on internal services (leverages Cloudflare-managed DNS).

---

## Proxmox integration

- Set Proxmox VM `Name` = guest `/etc/hostname` = DNS A record (avoid 3-way drift).
- Regenerate `machine-id` and SSH host keys on template clones.
- Give infra guests **DHCP reservations** so their A records stay valid.

---

## Master mapping (hostname ↔ VMID)

| Hostname | VMID |
|----------|------|
| `dnlnms001` | 1001 |
| `dnladm001` | 1002 |
| `dnlnbx001` | 1003 |
| `dnllog001` | 1004 |
| `dnldns001` | 1005 |
| `dnlctl001` | 1006 |
| `dnlplx001` | 1201 |
| `dnlnas001` | 1301 |
| `dnlpbs001` | 1302 |
| `dnldns002` | 2001 |
| `dnllog002` | 2002 |
| `dnlpnt001` | 2101 |
| `dnleve001` | 2102 |
| `dnlpbs002` | 3401 |
