# NetBox Setup Runbook — `dnlnbx101`

Stand up **NetBox** as the lab **source of truth** (full DCIM + IPAM). Native install
(PostgreSQL + Redis + gunicorn + nginx via systemd), matching the fleet's native pattern.
Later it **generates** the configs currently hand-maintained (rsyslog `sources.json`,
Prometheus `snmp_devices.json`, DNS, Ansible inventory — deferred, see **#62**). Context:
[lld.md](lld.md) · [naming-convention.md](naming-convention.md) · [vmid-plan.md](vmid-plan.md).

## Facts

| Item | Value |
|------|-------|
| Hostname | `dnlnbx101` |
| Role | NetBox — DCIM/IPAM source of truth (`nbx`) |
| VMID | **1003** (VM, dc01) |
| OS | Ubuntu Server 26.04 LTS |
| VLAN / IP | **shared_mgt (1000)** — **`172.16.10.55/24`**, gw `172.16.10.1` |
| FQDN | `dnlnbx101.mgmt.devnetlabs.com` (mgmt-VLAN host → **mgmt** zone, #28) |
| vCPU / RAM | 2 × `x86-64-v2-AES` / 4 GB (8 GB comfortable) |
| Disk | 32 GB OS+data (`local-lvm`) — PostgreSQL lives here |
| Stack | **PostgreSQL 14+** · **Redis** · **NetBox** (gunicorn) · **nginx** (reverse proxy) |
| Web | `https://dnlnbx101.mgmt.devnetlabs.com/` (self-signed now; internal CA later — #31) |

> **mgmt-tier host:** NetBox is on VLAN 1000, so its DNS record lives in
> **`mgmt.devnetlabs.com`** (not `dc01` — the trap from the Grafana record).

---

## Part A — Create the VM (on dc01)

```bash
qm create 1003 --name dnlnbx101 --machine q35 --bios ovmf \
  --cpu x86-64-v2-AES --cores 2 --sockets 1 --memory 4096 \
  --scsihw virtio-scsi-single --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1000
qm set 1003 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 1003 --scsi0 local-lvm:32,discard=on,ssd=1      # OS + PostgreSQL
qm set 1003 --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom
qm set 1003 --boot order='ide2;scsi0'
qm start 1003
```

## Part B — Install Ubuntu + static IP

Single 32 GB disk. Eject the ISO, then `/etc/netplan/01-mgmt.yaml`:
```yaml
network:
  version: 2
  ethernets:
    ens18:
      addresses: [172.16.10.55/24]
      routes: [{ to: default, via: 172.16.10.1 }]
      nameservers: { addresses: [172.16.10.53, 172.16.10.54], search: [mgmt.devnetlabs.com] }
```
```bash
sudo hostnamectl set-hostname dnlnbx101
sudo netplan apply
sudo timedatectl set-timezone Europe/Amsterdam
```

## Part C — Base config + firewall

Key-only SSH (mirror the bastion), `chrony`, `unattended-upgrades`, `ufw`. Allow SSH + web:
```bash
sudo apt update && sudo apt install -y chrony unattended-upgrades ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 172.16.10.0/24  to any port 22  proto tcp     # SSH (mgmt / bastion)
sudo ufw allow from 172.16.254.0/24 to any port 22  proto tcp     # SSH (lab_lan)
sudo ufw allow from 172.16.10.0/24  to any port 443 proto tcp     # web (mgmt)
sudo ufw allow from 172.16.254.0/24 to any port 443 proto tcp     # web (lab_lan)
sudo ufw enable
```

## Part D — PostgreSQL

```bash
sudo apt install -y postgresql
sudo -u postgres psql <<'SQL'
CREATE DATABASE netbox;
CREATE USER netbox WITH PASSWORD '<db-password>';
ALTER DATABASE netbox OWNER TO netbox;
SQL
```
> **Check:** `psql -U netbox -h localhost -W netbox -c '\conninfo'` connects.

## Part E — Redis

```bash
sudo apt install -y redis-server
redis-cli ping        # -> PONG
```

## Part F — Install NetBox

Set `NETBOX_VER` to the latest stable from <https://github.com/netbox-community/netbox/releases>:
```bash
sudo apt install -y python3 python3-pip python3-venv python3-dev build-essential \
    libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev git
NETBOX_VER=4.4.0                        # <-- check the releases page
sudo mkdir -p /opt/netbox && cd /opt
sudo git clone -b v${NETBOX_VER} --depth 1 https://github.com/netbox-community/netbox.git
sudo adduser --system --group netbox
sudo chown -R netbox:netbox /opt/netbox/netbox/media /opt/netbox/netbox/reports /opt/netbox/netbox/scripts

cd /opt/netbox/netbox/netbox
sudo cp configuration_example.py configuration.py
python3 -c 'import secrets; print(secrets.token_urlsafe(64))'   # -> SECRET_KEY
```
Edit `configuration.py`:
```python
ALLOWED_HOSTS = ['dnlnbx101.mgmt.devnetlabs.com', '172.16.10.55']
DATABASE = {'NAME': 'netbox', 'USER': 'netbox', 'PASSWORD': '<db-password>',
            'HOST': 'localhost', 'PORT': '', 'CONN_MAX_AGE': 300}
REDIS = {
  'tasks':   {'HOST': 'localhost', 'PORT': 6379, 'DATABASE': 0, 'SSL': False},
  'caching': {'HOST': 'localhost', 'PORT': 6379, 'DATABASE': 1, 'SSL': False},
}
SECRET_KEY = '<generated-above>'
```
Run the installer (creates the venv, migrates, collects static, prompts for a superuser):
```bash
sudo /opt/netbox/upgrade.sh
sudo /opt/netbox/venv/bin/python3 /opt/netbox/netbox/manage.py createsuperuser
```

## Part G — gunicorn + systemd

```bash
sudo cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py
sudo cp -v /opt/netbox/contrib/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now netbox netbox-rq
```
> `netbox` = the web app (gunicorn on `127.0.0.1:8001`); `netbox-rq` = the background worker.
> **Check:** `systemctl status netbox netbox-rq`; `curl -s localhost:8001/login/ | head`.

## Part H — nginx reverse proxy (TLS)

```bash
sudo apt install -y nginx
sudo openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
  -keyout /etc/ssl/private/netbox.key -out /etc/ssl/certs/netbox.crt \
  -subj "/CN=dnlnbx101.mgmt.devnetlabs.com"          # self-signed until the internal CA (#31)
sudo cp /opt/netbox/contrib/nginx.conf /etc/nginx/sites-available/netbox
# edit server_name -> dnlnbx101.mgmt.devnetlabs.com; ssl_certificate paths above
sudo ln -sf /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/netbox
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl restart nginx
```

## Part I — Data model (DCIM + IPAM + SoT design)

Model the lab so the automation outputs (#62) can be generated from it. Build in this order:

**Organization / DCIM**
- **Site:** `home-lab` (one site; the 3 nodes are here).
- **Manufacturers / Device Types:** GEEKOM IT13, HPE ML150 G9, Dell E6430, MikroTik RB951Ui-2HnD.
- **Device Roles:** `hypervisor`, `router` (add `firewall`/`switch` as the lab grows).
- **Platforms:** `Proxmox VE`, `RouterOS`, `Ubuntu`, `TrueNAS`.
- **Devices:** `dc01`/`dc02`/`dc03` (hypervisors), `Home_Lab_Core_Router` (MikroTik).

**Virtualization**
- **Cluster Type:** `Proxmox VE`. **Clusters:** `dc01`, `dc02`, `dc03` (bound to the matching Device).
- **Virtual Machines:** every `dnl*` guest, assigned to its cluster, with **VMID** (custom field), vCPU/RAM/disk, role, and **primary IP**.

**IPAM**
- **VLANs:** 1000 `shared_mgt`, 1101/1102/1103 (dc01), 1201 (dc02), 1301 (dc03), 1 `lab_lan`.
- **Prefixes:** `172.16.10.0/24`, `10.110.10/20/30.0/24`, `10.120.10.0/24`, `10.130.10.0/24`, `172.16.254.0/24` — each tied to its VLAN.
- **IP Addresses:** assign to VM/device interfaces; set the primary IP per object.

**Custom fields — the SoT hooks that drive the generators (#62):**

| Field | Applies to | Type | Purpose |
|-------|-----------|------|---------|
| `vmid` | Virtual Machine | integer | the NZSS VMID |
| `log_category` | VM / Device / IP | choice (`network`/`security`/`compute`/`storage`/`others`) | rsyslog `sources.json` |
| `log_vendor` | VM / Device / IP | text (`cisco`/`asa`/…) | rsyslog `sources.json` |
| `snmp_version` | Device / IP | choice (`v2c`/`v3`/`none`) | SNMP onboarding |
| `snmp_module` | Device / IP | text (default `if_mib`) | Prometheus `file_sd` `__param_module` |
| `snmp_auth` | Device / IP | text (`lab_v3`/`lab_v2`) | Prometheus `file_sd` `__param_auth` |

> Later, a script/report hits the **NetBox API**, filters by these fields, and renders
> `sources.json` / `snmp_devices.json` / DNS / Ansible inventory — the concrete outputs are
> tracked in **#62**. NetBox becomes the one place you edit; the configs follow.

---

## Verification & success criteria

**✅ Success criteria — NetBox is up when:**
- [ ] `systemctl status netbox netbox-rq nginx postgresql redis-server` all active.
- [ ] `https://dnlnbx101.mgmt.devnetlabs.com/` loads and you log in as the superuser.
- [ ] The FQDN resolves via Technitium (record in **`mgmt`** zone) → `172.16.10.55`.
- [ ] A test object (a VLAN + a prefix) saves and the API returns it with a token.
- [ ] Redis-backed jobs work (an object change enqueues without error in `netbox-rq`).

**🧪 End-to-end test:**
```bash
systemctl is-active netbox netbox-rq nginx postgresql redis-server     # all "active"
curl -sk https://localhost/login/ | grep -i netbox                     # login page served
getent hosts dnlnbx101.mgmt.devnetlabs.com                             # -> 172.16.10.55
# API smoke (create a token in the UI: Admin -> API Tokens):
curl -sk -H "Authorization: Token <token>" https://localhost/api/ipam/vlans/ | jq '.count'
```

**⚠️ Watch out for:**
- **Record in the wrong DNS zone** — NetBox is mgmt-tier → `mgmt.devnetlabs.com`, not `dc01`.
- **`ALLOWED_HOSTS`** — must list the FQDN + IP or NetBox returns HTTP 400 (`Bad Request`).
- **`SECRET_KEY` / DB password** drift between `configuration.py` and PostgreSQL — auth/login failures.
- **`netbox-rq` not running** — background jobs (webhooks, reports, later the generators) silently don't fire.
- **Redis vs valkey** — Ubuntu may ship `valkey`; NetBox needs a Redis-compatible server on `:6379`.
- **Version drift** — `NETBOX_VER` is a placeholder; use the current stable and re-run `upgrade.sh` on upgrades.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| Web → HTTP 400 Bad Request | FQDN/IP not in `ALLOWED_HOSTS` | add it to `configuration.py`; `sudo systemctl restart netbox` |
| 502 Bad Gateway from nginx | gunicorn (`netbox`) down / wrong upstream port | `systemctl status netbox`; confirm proxy_pass `127.0.0.1:8001` |
| `upgrade.sh` fails on migrate | DB creds / PostgreSQL down | verify `DATABASE` in `configuration.py`; `psql -U netbox -h localhost -W netbox` |
| Login OK but changes error | `netbox-rq` / Redis down | `systemctl status netbox-rq redis-server`; `redis-cli ping` |
| Static assets 404 / unstyled UI | `collectstatic` not run | re-run `sudo /opt/netbox/upgrade.sh` |
| FQDN won't resolve | record missing or in wrong zone | add `dnlnbx101` A `172.16.10.55` in **`mgmt.devnetlabs.com`** (live Technitium) |
| API 403 | missing/expired token or wrong header | create a token (Admin → API Tokens); `Authorization: Token <token>` |

---

See also: [lld.md](lld.md) · [naming-convention.md](naming-convention.md) ·
[vmid-plan.md](vmid-plan.md) · [OPEN-ITEMS.md](OPEN-ITEMS.md)
