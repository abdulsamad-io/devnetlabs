# ntfy Setup Runbook — `dnlnfy101`

Stand up **ntfy** — a lightweight self-hosted **pub/sub push-notification** hub. Everything
that needs to alert you (Uptime Kuma, Prometheus Alertmanager, Grafana, PBS backups, cron
scripts) POSTs to a **topic**; you subscribe from the phone app / web / CLI. Native install
(`apt` + systemd). Context: [uptime-kuma-setup.md](uptime-kuma-setup.md) · [../lld.md](../lld.md).

## Facts

| Item | Value |
|------|-------|
| Hostname | `dnlnfy101` |
| Role | ntfy — notification hub (`nfy`) |
| VMID | **1108** (VM, dc01) |
| OS | Ubuntu Server 26.04 LTS |
| VLAN / IP | **dc01_apps (1101)** — **`10.110.10.74/24`**, gw `10.110.10.1` |
| FQDN | `dnlnfy101.dc01.devnetlabs.com` (apps-VLAN → **dc01** zone) |
| vCPU / RAM | 1 × `x86-64-v2-AES` / 1 GB (tiny) |
| Disk | 16 GB OS (`local-lvm`) |
| Listener | HTTP **`:80`** (publish/subscribe API + web) |
| Deploy | **native** — official `apt` package + systemd (`ntfy.service`) |

> Model: **topics are ad-hoc** — publishing to `…/lab-alerts` creates it. Auth is optional;
> for a LAN-only hub, restricting write to the lab subnets (below) is enough for a start.

---

## Part A — Create the VM (on dc01)

```bash
qm create 1108 --name dnlnfy101 --machine q35 --bios ovmf \
  --cpu x86-64-v2-AES --cores 1 --sockets 1 --memory 1024 \
  --scsihw virtio-scsi-single --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1101
qm set 1108 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 1108 --scsi0 local-lvm:16,discard=on,ssd=1
qm set 1108 --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom
qm set 1108 --boot order='ide2;scsi0'
qm start 1108
```

## Part B — Install Ubuntu + static IP

`/etc/netplan/01-net.yaml`:
```yaml
network:
  version: 2
  ethernets:
    ens18:
      addresses: [10.110.10.74/24]
      routes: [{ to: default, via: 10.110.10.1 }]
      nameservers: { addresses: [172.16.10.53, 172.16.10.54], search: [dc01.devnetlabs.com] }
```
```bash
sudo hostnamectl set-hostname dnlnfy101
sudo netplan apply
sudo timedatectl set-timezone Europe/Amsterdam
```

## Part C — Base config + firewall

Key-only SSH (mirror the bastion), `chrony`, `unattended-upgrades`, `ufw`. Allow SSH + the
ntfy HTTP port from the lab (publishers + you):
```bash
sudo apt update && sudo apt install -y chrony unattended-upgrades ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 172.16.10.0/24  to any port 22 proto tcp     # SSH (mgmt / bastion)
sudo ufw allow from 172.16.254.0/24 to any port 22 proto tcp     # SSH (lab_lan)
sudo ufw allow from 172.16.10.0/24  to any port 80 proto tcp     # publish/subscribe (mgmt)
sudo ufw allow from 172.16.254.0/24 to any port 80 proto tcp     # you (lab_lan)
sudo ufw allow from 10.110.10.0/24  to any port 80 proto tcp     # publishers (Kuma/Prom/Grafana)
sudo ufw enable
```

## Part D — Install ntfy (official apt repo)

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://archive.heckel.io/apt/pubkey.txt | sudo gpg --dearmor -o /etc/apt/keyrings/ntfy.gpg
echo "deb [signed-by=/etc/apt/keyrings/ntfy.gpg] https://archive.heckel.io/apt debian main" \
  | sudo tee /etc/apt/sources.list.d/ntfy.list
sudo apt update && sudo apt install -y ntfy
sudo systemctl enable --now ntfy
```
> Installs `/usr/bin/ntfy` + `ntfy.service`, config at `/etc/ntfy/server.yml`.

## Part E — Configure `/etc/ntfy/server.yml`

Minimum:
```yaml
base-url: "http://dnlnfy101.dc01.devnetlabs.com"
listen-http: ":80"
# behind-proxy: true          # set when Traefik fronts it (X-Forwarded-*)
# --- optional access control (lock down writes; keep it simple to start) ---
# auth-file: "/var/lib/ntfy/user.db"
# auth-default-access: "deny-all"   # then grant users/tokens per topic
```
```bash
sudo systemctl restart ntfy
```
> Start **open** (LAN-restricted by ufw) for the quick win; add `auth-*` + per-topic ACLs later
> when it's fronted by Traefik/Authentik. Cache/attachment dirs default under `/var/cache/ntfy`.

## Part F — Test publish/subscribe

```bash
# publish (from any lab host):
curl -d "hello from $(hostname)" http://dnlnfy101.dc01.devnetlabs.com/lab-alerts
# subscribe (CLI) or point the ntfy phone app at the server + topic 'lab-alerts':
curl -s http://dnlnfy101.dc01.devnetlabs.com/lab-alerts/json    # streams messages
```
Wire it into producers: **Uptime Kuma** (Notification → ntfy), **Alertmanager**/**Grafana**
(webhook/ntfy receiver), **PBS** hook scripts — all POST to `…/lab-alerts`.

## Part G — DNS record

Add the A record `dnlnfy101 → 10.110.10.74` in the **`dc01.devnetlabs.com`** zone (Technitium).

---

## Verification & success criteria

**✅ Success criteria — ntfy is serving when:**
- [ ] `systemctl is-active ntfy` → `active`; `curl -sI http://localhost/ | head -1` → `200`.
- [ ] A `curl -d …` publish to a topic is received by a subscriber (CLI or phone app).
- [ ] The FQDN resolves (`dc01` zone) and is reachable from the lab subnets.
- [ ] At least one real producer (Uptime Kuma) delivers a notification to your device.

**🧪 End-to-end test:**
```bash
systemctl is-active ntfy
# terminal 1 (subscribe):  curl -s http://localhost/ci-test/json
# terminal 2 (publish):    curl -d "e2e $(date +%T)" http://localhost/ci-test
getent hosts dnlnfy101.dc01.devnetlabs.com                # -> 10.110.10.74
```
Expected: the published line appears in the subscriber stream within a second.

**⚠️ Watch out for:**
- **Port 80 in use / privileged bind** — the `ntfy` service runs as its own user but binds `:80` via the unit; if `:80` clashes, set `listen-http: ":8080"` and adjust ufw.
- **`base-url` mismatch** — must match how clients reach it (FQDN), or web-app links/attachments break; set it explicitly.
- **Wide-open writes** — fine LAN-only behind ufw, but anyone on the lab can publish to any topic until you add `auth-*`. Lock down before exposing via Traefik.
- **behind-proxy** — set `behind-proxy: true` only once Traefik is actually in front (else rate-limits key off the proxy IP).
- **DNS record zone** — apps-VLAN host → `dc01.devnetlabs.com`, not `mgt`.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| `ntfy` won't start | bad `server.yml` / port clash | `journalctl -u ntfy -n50`; `ntfy serve --help`; check `listen-http` |
| Publish works locally, not from other hosts | ufw missing the source subnet on `:80` | add `ufw allow from <subnet> to any port 80 proto tcp` |
| Web UI links wrong / attachments 404 | `base-url` not set or wrong | set `base-url` to the FQDN; `systemctl restart ntfy` |
| Producer (Kuma/Grafana) can't deliver | wrong server URL/topic, or blocked | `curl -d test http://dnlnfy101.dc01.devnetlabs.com/lab-alerts` from that host |
| Everyone can publish/read | no auth configured | add `auth-file` + `auth-default-access: deny-all` + per-topic grants |
| Rate-limited unexpectedly behind Traefik | `behind-proxy` not set → limits by proxy IP | set `behind-proxy: true` once Traefik fronts it |

---

See also: [uptime-kuma-setup.md](uptime-kuma-setup.md) · [prometheus-setup.md](prometheus-setup.md) ·
[grafana-setup.md](grafana-setup.md) · [../lld.md](../lld.md)
