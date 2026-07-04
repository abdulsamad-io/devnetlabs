# VM / Guest Naming Convention

Format: **`dnl-<role>-<NN>`**

- **Node-agnostic** — the name is the guest's *identity*, the VMID encodes *placement*.
  Names therefore survive cross-node PBS restore.
- Instance `NN` is **global per role**: `01` for a singleton, `02+` for pairs/HA.

---

## Role codes

| Code | Service |
|------|---------|
| `nms` | LibreNMS |
| `ipam` | NetBox |
| `log` | rsyslog |
| `dns` | Pi-hole |
| `plex` | Plex |
| `nas` | TrueNAS |
| `pbs` | Proxmox Backup Server |
| `pnet` | PNETLAB |
| `eve` | EVE-NG |
| `cftun` | Cloudflare tunnel connector (cloudflared) |
| `tmpl` | Template |

**Reserved for future use:** `git`, `awx`, `vault`, `graf`, `tsdb`, `dkr`, `k8s`,
`proxy`, `ca`, `ad`.

> **Avoid `dc`** — it means *node* in this topology.
> **Pending:** a code for **Graylog** (candidate `glog`/`graylog`) — see OPEN-ITEMS.

---

## Templates

Format: **`tmpl-<os><ver>[-variant]`**

Examples: `tmpl-deb12-base`, `tmpl-ubn2404-docker`.

---

## DNS

- Internal zone: **`lab.devnetlabs.com`** (served by Pi-hole flat records).
- Optional per-zone subdomains (e.g. `mgmt.lab.devnetlabs.com`) need custom dnsmasq
  or a real authoritative DNS.
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
| `dnl-nms-01` | 1050 |
| `dnl-ipam-01` | 1051 |
| `dnl-log-01` | 1052 |
| `dnl-dns-01` | 1053 |
| `dnl-cftun-01` | 1054 |
| `dnl-plex-01` | 1250 |
| `dnl-nas-01` | 1301 |
| `dnl-pbs-01` | 1302 |
| `dnl-dns-02` | 2050 |
| `dnl-log-02` | 2051 |
| `dnl-pnet-01` | 2101 |
| `dnl-eve-01` | 2102 |
| `dnl-pbs-02` | 3401 |
