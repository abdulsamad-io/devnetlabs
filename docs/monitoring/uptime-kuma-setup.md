# Uptime Kuma Setup Runbook — `dnlukm101`

Stand up **Uptime Kuma** — self-hosted **black-box availability monitoring** (HTTP/TCP/
ping/DNS + TLS-cert-expiry), a dashboard, a public status page, and push notifications
(to **ntfy**). Complements Prometheus (white-box metrics) with dead-simple up/down.
Context: [prometheus-setup.md](prometheus-setup.md) · [ntfy-setup.md](ntfy-setup.md) ·
[../lld.md](../lld.md).

## Facts

| Item | Value |
|------|-------|
| Hostname | `dnlukm101` |
| Role | Uptime Kuma — availability monitor (`ukm`) |
| VMID | **1107** (VM, dc01) |
| OS | Ubuntu Server 26.04 LTS |
| VLAN / IP | **dc01_apps (1101)** — **`10.110.10.73/24`**, gw `10.110.10.1` |
| FQDN | `dnlukm101.dc01.devnetlabs.com` (apps-VLAN → **dc01** zone) |
| vCPU / RAM | 2 × `x86-64-v2-AES` / 2 GB |
| Disk | 16 GB OS (`local-lvm`) — SQLite state in a Docker volume |
| Listener | HTTP **`:3001`** (web UI + API) |
| Deploy | **Docker, single container** (`louislam/uptime-kuma`) |

> **First Docker workload on the fleet** — a *deliberate, single-container* footprint (Uptime
> Kuma has no first-class native package; Docker is its supported, lowest-effort path). This is
> **not** the full docker-host decision — it's one container on one VM. A native Node.js install
> is possible but fiddlier (Node version pinning + a hand-rolled systemd unit).

---

## Part A — Create the VM (on dc01)

```bash
qm create 1107 --name dnlukm101 --machine q35 --bios ovmf \
  --cpu x86-64-v2-AES --cores 2 --sockets 1 --memory 2048 \
  --scsihw virtio-scsi-single --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1101
qm set 1107 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 1107 --scsi0 local-lvm:16,discard=on,ssd=1
qm set 1107 --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom
qm set 1107 --boot order='ide2;scsi0'
qm start 1107
```

## Part B — Install Ubuntu + static IP

Single 16 GB disk. Eject the ISO, then `/etc/netplan/01-net.yaml`:
```yaml
network:
  version: 2
  ethernets:
    ens18:
      addresses: [10.110.10.73/24]
      routes: [{ to: default, via: 10.110.10.1 }]
      nameservers: { addresses: [172.16.10.53, 172.16.10.54], search: [dc01.devnetlabs.com] }
```
```bash
sudo hostnamectl set-hostname dnlukm101
sudo netplan apply
sudo timedatectl set-timezone Europe/Amsterdam
```
> **Check:** `ip -br a` shows `.73`; `getent hosts dnlnfy101.dc01.devnetlabs.com` resolves.

## Part C — Base config + firewall

Key-only SSH (mirror the bastion), `chrony`, `unattended-upgrades`, `ufw`. Allow SSH + the UI:
```bash
sudo apt update && sudo apt install -y chrony unattended-upgrades ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 172.16.10.0/24  to any port 22   proto tcp    # SSH (mgmt / bastion)
sudo ufw allow from 172.16.254.0/24 to any port 22   proto tcp    # SSH (lab_lan)
sudo ufw allow from 172.16.10.0/24  to any port 3001 proto tcp    # UI (mgmt)
sudo ufw allow from 172.16.254.0/24 to any port 3001 proto tcp    # UI (lab_lan)
sudo ufw enable
```
> Uptime Kuma reaches its *targets* **outbound** (default-allow), so no inbound rules for
> monitoring — only the UI port needs opening.

## Part D — Install Docker

```bash
sudo apt install -y docker.io
sudo systemctl enable --now docker
docker --version
```
> `docker.io` (Ubuntu's package) is fine for one container. (Use Docker's official repo if you
> want the latest engine.)

## Part E — Run Uptime Kuma

```bash
docker run -d --name uptime-kuma --restart unless-stopped \
  -p 3001:3001 \
  -v uptime-kuma:/app/data \
  louislam/uptime-kuma:1
```
- `--restart unless-stopped` + `systemctl enable docker` → survives reboots (no systemd unit needed).
- Named volume `uptime-kuma` holds the SQLite DB + config (persists across container upgrades).
- Upgrade later: `docker pull louislam/uptime-kuma:1 && docker rm -f uptime-kuma && <re-run>`.
> **Check:** `docker ps` shows it `Up`; `curl -sI http://localhost:3001/ | head -1` → `HTTP/1.1 200`.

## Part F — First-run setup

1. Browse `http://10.110.10.73:3001/` (or the FQDN once the DNS record is in), create the admin.
2. **Add monitors** — the fleet's services + devices, e.g.:
   - HTTP: `https://dnlgrf101.dc01.devnetlabs.com`, `https://dnlnbx101.mgt.devnetlabs.com`, PVE `:8006`
   - TCP: Loki `10.110.10.70:3100`, Prometheus `10.110.10.72:9090`
   - Ping: MikroTik `172.16.10.1`, TrueNAS `10.110.30.50`
   - TLS cert-expiry alerts on the HTTPS monitors
3. **Notifications → Add → ntfy** — server `http://dnlnfy101.dc01.devnetlabs.com`, a topic
   (e.g. `lab-alerts`); attach it to the monitors. (See [ntfy-setup.md](ntfy-setup.md).)
4. Optional **Status Page** for an at-a-glance lab health view.

## Part G — DNS record

Add the A record `dnlukm101 → 10.110.10.73` in the **`dc01.devnetlabs.com`** zone (Technitium).

---

## Verification & success criteria

**✅ Success criteria — Uptime Kuma is serving when:**
- [ ] `docker ps` shows `uptime-kuma` `Up`, restart policy `unless-stopped`.
- [ ] The UI loads at `http://10.110.10.73:3001/` and the admin is created.
- [ ] At least one monitor is **green (Up)**, and one deliberately-bad monitor goes **Down**.
- [ ] An **ntfy** notification fires on a state change (test with a paused/resumed monitor).
- [ ] State survives a container recreate (volume `uptime-kuma` persists).

**🧪 End-to-end test:**
```bash
docker ps --filter name=uptime-kuma
curl -sI http://localhost:3001/ | head -1                 # HTTP/1.1 200
# add a monitor to a known-up host -> green; add one to 10.0.0.254 -> Down + ntfy push
docker volume inspect uptime-kuma >/dev/null && echo "volume OK"
```

**⚠️ Watch out for:**
- **First Docker workload** — confirm `docker` is enabled (`systemctl is-enabled docker`) so the container comes back after reboot.
- **Data loss on upgrade** — always keep the `-v uptime-kuma:/app/data` volume; never run without it.
- **UI exposed** — `:3001` is HTTP with app-level login; put it behind Traefik + SSO later, don't expose it externally raw.
- **Alert storms** — set sensible retry/heartbeat intervals so a flapping target doesn't spam ntfy.
- **DNS record zone** — apps-VLAN host → `dc01.devnetlabs.com`, not `mgt`.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| UI won't load | container down / ufw / wrong port | `docker ps -a`; `docker logs uptime-kuma`; `sudo ufw status`; port is `3001` |
| Container gone after reboot | Docker not enabled / no restart policy | `sudo systemctl enable --now docker`; re-run with `--restart unless-stopped` |
| Monitors all Down | egress blocked or DNS broken on the VM | `curl`/`ping` the target from the VM; check `resolvectl status` |
| ntfy notifications don't fire | wrong ntfy URL/topic or ntfy unreachable | test `curl -d test http://dnlnfy101.dc01.devnetlabs.com/lab-alerts`; re-check the notification config |
| Lost history after `docker rm` | ran without the named volume | always mount `-v uptime-kuma:/app/data`; restore from a volume backup if taken |
| TLS-expiry checks not alerting | cert-expiry notify not enabled on the monitor | enable "Certificate Expiry" on the HTTPS monitor |

---

See also: [prometheus-setup.md](prometheus-setup.md) · [ntfy-setup.md](ntfy-setup.md) ·
[grafana-setup.md](grafana-setup.md) · [../lld.md](../lld.md)
