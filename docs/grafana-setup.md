# Grafana Setup Runbook — `dnlgrf101`

Stand up the dc01 **Grafana** frontend — the single pane over **Loki** (logs, LogQL) and
**Prometheus** (metrics/SNMP, PromQL). Native binary + systemd. Context:
[loki-setup.md](loki-setup.md) · [lld.md](lld.md) · [logging-design.md](logging-design.md).

## Facts

| Item | Value |
|------|-------|
| Hostname | `dnlgrf101` |
| Role | Grafana (`grf`) |
| VMID | **1105** (VM, dc01) |
| OS | Ubuntu Server 26.04 LTS |
| VLAN / IP | **dc01_apps (1101)** — **`10.110.10.71/24`**, gw `10.110.10.1` |
| FQDN | `dnlgrf101.dc01.devnetlabs.com` (apps-VLAN host → **dc01** zone) |
| vCPU / RAM | 2 × `x86-64-v2-AES` / 2 GB (Grafana is light) |
| Disk | 16 GB OS (`local-lvm`) — SQLite state is tiny, no data disk needed |
| Listener | HTTP **`:3000`** (web UI) |
| Datasources | **Loki** `dnllok101:3100` (built) + **Prometheus** `dnlprm101:9090` (pending — `dnlprm101` not built yet) |

> **Per-DC, independent:** this is dc01's Grafana; dc02 gets its own `dnlgrf201`. They are
> **separate instances with separate SQLite state** — dashboards are **not** shared between
> them (that was the deliberate "manage independently" choice). All datasources are on the
> **same apps VLAN** (10.110.10.0/24), so no cross-VLAN hops for the queries.

---

## Part A — Create the VM (on dc01)

```bash
qm create 1105 --name dnlgrf101 --machine q35 --bios ovmf \
  --cpu x86-64-v2-AES --cores 2 --sockets 1 --memory 2048 \
  --scsihw virtio-scsi-single --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1101
qm set 1105 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 1105 --scsi0 local-lvm:16,discard=on,ssd=1      # OS disk (single disk — Grafana is light)
qm set 1105 --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom
qm set 1105 --boot order='ide2;scsi0'
qm start 1105
```
> Use the **dc01_apps SDN VNet** name if configured, else `vmbr0,tag=1101`. Check the thin
> pool headroom on dc01 (`lvs pve/data`) before adding the disk.

## Part B — Install Ubuntu + static IP

Single 16 GB disk, so no wrong-disk trap here — just install onto it. Eject the ISO, then
`/etc/netplan/01-net.yaml`:
```yaml
network:
  version: 2
  ethernets:
    ens18:                                   # confirm: ip -br a
      addresses: [10.110.10.71/24]
      routes: [{ to: default, via: 10.110.10.1 }]
      nameservers: { addresses: [172.16.10.53, 172.16.10.54], search: [dc01.devnetlabs.com] }
```
```bash
sudo hostnamectl set-hostname dnlgrf101
sudo netplan apply
sudo timedatectl set-timezone Europe/Amsterdam
```
> **Check:** `ip -br a` shows `.71` on `ens18`; `getent hosts dnllok101.dc01.devnetlabs.com`
> → `10.110.10.70` (datasource resolves).

## Part C — Base config + firewall

Key-only SSH (mirror the bastion), `chrony`, `unattended-upgrades`, `ufw`. Allow SSH from
mgmt/lab_lan and the Grafana UI (`:3000`) from where you browse:
```bash
sudo apt update && sudo apt install -y chrony unattended-upgrades ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 172.16.10.0/24  to any port 22   proto tcp    # SSH (mgmt / bastion)
sudo ufw allow from 172.16.254.0/24 to any port 22   proto tcp    # SSH (lab_lan)
sudo ufw allow from 172.16.10.0/24  to any port 3000 proto tcp    # UI (mgmt)
sudo ufw allow from 172.16.254.0/24 to any port 3000 proto tcp    # UI (lab_lan workstation)
sudo ufw enable
```
> **Check:** `sudo ufw status` shows 22 + 3000 allowed from both mgmt and lab_lan.

## Part D — Install Grafana (Grafana apt repo)

```bash
sudo apt install -y gpg
sudo mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update && sudo apt install -y grafana
sudo systemctl enable --now grafana-server
```
> The package creates the `grafana` user + `grafana-server.service`, config at
> `/etc/grafana/grafana.ini`, SQLite state in `/var/lib/grafana`.
> **Check:** `sudo systemctl status grafana-server`; `curl -s localhost:3000/api/health | jq .`
> → `"database": "ok"`.

## Part E — Provision datasources (Loki + Prometheus)

File-provision so the datasources survive rebuilds (no click-ops).
`/etc/grafana/provisioning/datasources/devnetlabs.yaml`:
```yaml
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://dnllok101.dc01.devnetlabs.com:3100
    isDefault: true
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://dnlprm101.dc01.devnetlabs.com:9090      # dnlprm101 not built yet — errors until then
    isDefault: false
```
```bash
sudo systemctl restart grafana-server
```
> Use the **FQDNs** (both datasources are in the `dc01.devnetlabs.com` zone). The Prometheus
> datasource will show "down" until `dnlprm101` is built — expected, harmless.

## Part F — First login & hardening

1. Browse `http://10.110.10.71:3000/` (or `http://dnlgrf101.dc01.devnetlabs.com:3000/`).
2. Log in `admin` / `admin`, set a strong password when prompted.
3. In `/etc/grafana/grafana.ini` set the public URL so links/alerts are correct:
   ```
   [server]
   domain = dnlgrf101.dc01.devnetlabs.com
   root_url = http://dnlgrf101.dc01.devnetlabs.com:3000/
   ```
   then `sudo systemctl restart grafana-server`.
> Keep `[auth.anonymous] enabled = false` (default). Public exposure later goes via the
> Cloudflare tunnel, not by opening `:3000` to the world.

## Part G — Open the datasource firewalls (on the *backends*)

Grafana connects **out** to the datasources, so its own ufw needs nothing extra — but the
backends must accept Grafana. Grafana is `10.110.10.71`:
```bash
# on dnllok101 (Loki):
sudo ufw allow from 10.110.10.71 to any port 3100 proto tcp     # Grafana -> Loki queries
# on dnlprm101 (Prometheus), once built:
sudo ufw allow from 10.110.10.71 to any port 9090 proto tcp     # Grafana -> Prometheus queries
```
> Loki's earlier ufw only allowed the collectors (`172.16.10.71/.72`); Grafana is a new
> source, so this rule is required or the Loki datasource test fails with a timeout.

---

## Verification & success criteria

**✅ Success criteria — Grafana is serving when:**
- [ ] `curl -s localhost:3000/api/health` → `"database": "ok"`.
- [ ] The web UI loads from your workstation at `http://10.110.10.71:3000/`.
- [ ] The **Loki** datasource **Save & test** → "Data source is working".
- [ ] Loki **Explore** returns log lines (e.g. `{category=~".+"}`).
- [ ] The Prometheus datasource is provisioned (will pass once `dnlprm101` exists).

**🧪 End-to-end test:**
```bash
curl -s http://localhost:3000/api/health | jq .                      # database: ok, version shown
# from the collector-fed Loki, confirm Grafana can reach + query it:
curl -s http://dnllok101.dc01.devnetlabs.com:3100/ready               # ready
# in the UI: Connections -> Data sources -> Loki -> Save & test -> "working";
#            Explore -> Loki -> {category=~".+"} -> log lines appear
```

**⚠️ Watch out for:**
- **Loki datasource test times out** — the Loki host ufw doesn't allow Grafana (`10.110.10.71`) on `:3100` (Part G).
- **Datasource URL uses the short name** — must be the FQDN; Grafana's resolver uses `dc01.devnetlabs.com` search but be explicit.
- **Prometheus shows "down"** — expected until `dnlprm101` is built; not a Grafana fault.
- **Anonymous access / weak admin** — change the default password; leave anon auth off.
- **This Grafana ≠ dc02's** — dashboards don't sync between `dnlgrf101` and `dnlgrf201`; export/import or a shared DB if you want parity.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| UI won't load from workstation | ufw missing `:3000` for lab_lan, or wrong IP | `sudo ufw status`; add `allow from 172.16.254.0/24 to any port 3000`; browse `10.110.10.71:3000` |
| `grafana-server` won't start | bad `grafana.ini` / provisioning YAML | `journalctl -u grafana-server -n50`; `sudo grafana-server -config /etc/grafana/grafana.ini -homepath /usr/share/grafana` to see the parse error |
| Loki datasource "Save & test" fails (timeout) | Loki ufw doesn't allow Grafana on `:3100` | on dnllok101: `sudo ufw allow from 10.110.10.71 to any port 3100 proto tcp` |
| Loki test fails (no such host) | datasource URL wrong / DNS | `getent hosts dnllok101.dc01.devnetlabs.com`; use the FQDN in the datasource |
| Loki Explore returns nothing | Loki empty or wrong time range | confirm ingest (`curl …:3100/api/v1/labels`); widen the time picker |
| Prometheus datasource down | `dnlprm101` not built / `:9090` blocked | expected pre-build; after building, open `:9090` from `.71` |
| Forgot admin password | — | `sudo grafana-cli admin reset-admin-password '<new>'` |
| Datasources vanish after restart | edited via UI, not provisioning | UI edits to *provisioned* sources don't persist — change the YAML in `provisioning/datasources/` |

---

See also: [loki-setup.md](loki-setup.md) · [lld.md](lld.md) ·
[logging-design.md](logging-design.md) · [rsyslog-setup.md](rsyslog-setup.md)
