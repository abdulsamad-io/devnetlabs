# VM / Guest Naming Convention

Format: **`dnl<role><dc><nn>`** — lowercase, no separators.

Example: **`dnladm101`** (admin/bastion host on **dc01**, instance **01**).

- **`dnl`** — lab prefix (DevNetLabs).
- **`<role>`** — role code: **exactly 3 lowercase letters** (see table below).
- **`<dc>`** — node digit: `1`=dc01, `2`=dc02, `3`=dc03. **Must equal the VMID's `N`
  digit and the DNS subdomain** — node identity is encoded in all three.
- **`<nn>`** — 2-digit instance, **per node, per role**: `01` for a singleton on that
  node, `02+` for additional / HA instances on the same node.
- **Placement is encoded in the name** (and in the VMID and DNS zone). This is
  deliberate — the hostname/FQDN tells you the node at a glance. **Trade-off:** a guest
  moved to another node must be **renamed + renumbered + its DNS record re-homed** to
  the new zone (see [cross-dc-migration.md](cross-dc-migration.md)).

> **Scheme change:** this node-embedded `dnl<role><dc><nn>` form **supersedes** the
> earlier node-agnostic flat `dnl<role><NNN>` convention (which itself replaced the
> hyphenated `dnl-<role>-<NN>` form). Existing guests should be renamed as they are
> (re)built.

---

## Role codes

Every role code is **exactly 3 lowercase letters**.

| Code | Service |
|------|---------|
| `adm` | Admin / bastion (jump) host |
| `nms` | LibreNMS |
| `nbx` | NetBox |
| `log` | rsyslog collector |
| `lok` | Loki (log store) |
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

- **Per-node internal zones**, served by **Technitium DNS Server** (authoritative):
  **`dc01.devnetlabs.com`**, **`dc02.devnetlabs.com`**, **`dc03.devnetlabs.com`** —
  replacing the retired flat `lab.devnetlabs.com`.
- A host's FQDN = **`<hostname>.dc0<n>.devnetlabs.com`**, where the zone matches the
  node encoded in the hostname. Examples: `dnladm101` → `dnladm101.dc01.devnetlabs.com`;
  `dnldns201` → `dnldns201.dc02.devnetlabs.com`; `dnlpbs301` →
  `dnlpbs301.dc03.devnetlabs.com`.
- Technitium hosts the three zones natively and also provides recursive resolution /
  conditional forwarding, block lists (ad/tracker filtering, replacing Pi-hole),
  DNSSEC, DoH/DoT, and a full HTTP API + config export suitable for IaC.
- Keep the **public apex `devnetlabs.com` separate** from these internal zones.
- **Let's Encrypt via DNS-01:** one wildcard **per zone** — `*.dc01.devnetlabs.com`,
  `*.dc02.devnetlabs.com`, `*.dc03.devnetlabs.com` (publicly-trusted TLS on internal
  services, via Cloudflare-managed DNS).

### Split-horizon (public vs internal)

`devnetlabs.com` and the internal `dcNN.devnetlabs.com` zones share one namespace but
are **separate zones, served by different authorities to different audiences** — classic
split-horizon (split-brain) DNS:

| | `devnetlabs.com` (apex) | `dcNN.devnetlabs.com` (internal) |
|---|---|---|
| Level | 2nd-level (registered domain) | 3rd-level subdomain (own zone/SOA) |
| Authoritative server | **Cloudflare** (public NS) | **Technitium** (on the LAN) |
| Audience | Anyone on the internet | Only clients using Technitium |
| Resolves to | Public IPs / Cloudflare proxy / the tunnel | Private IPs (172.16.x / 10.x) |
| Published publicly? | Yes | **No** — public queries return NXDOMAIN |
| Managed via | Cloudflare dashboard / API | Technitium API (IaC) |

- The internal zones exist **only in the internal view**. Cloudflare holds **no
  delegation or records** for `dcNN.devnetlabs.com`, so internal hostnames, IPs, and
  topology never leave the lab.
- Publish only deliberately-public names on the apex (currently just the Cloudflare
  tunnel hostname, e.g. `pve.devnetlabs.com`).
- **Independent failure domains:** internal resolution keeps working even if the WAN or
  Cloudflare is down, because Technitium is local. Internal edits are instant and
  LAN-only; apex edits are outward-facing (TTL / caching / exposure).
- **Apex constraint:** `devnetlabs.com` can't be a CNAME (RFC — Cloudflare uses CNAME
  flattening) and must carry SOA/NS/MX; a subdomain like `dcNN.devnetlabs.com` has no
  such limit.

---

## Proxmox integration

- Set Proxmox VM `Name` = guest `/etc/hostname` = DNS A record (avoid 3-way drift).
- Regenerate `machine-id` and SSH host keys on template clones.
- Give infra guests **DHCP reservations** so their A records stay valid.

---

## Master mapping (hostname ↔ VMID)

| Hostname | VMID |
|----------|------|
| `dnlnms101` | 1001 |
| `dnladm101` | 1002 |
| `dnlnbx101` | 1003 |
| `dnllog101` | 1004 |
| `dnldns101` | 1005 |
| `dnlctl101` | 1006 |
| `dnlplx101` | 1201 |
| `dnlnas101` | 1301 |
| `dnlpbs101` | 1302 |
| `dnldns201` | 2001 |
| `dnllog201` | 2004 |
| `dnlpnt201` | 2101 |
| `dnleve201` | 2102 |
| `dnlpbs301` | 3401 |
