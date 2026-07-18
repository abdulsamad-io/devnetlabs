# Prometheus Setup Runbook — `dnlprm101`

Stand up the dc01 **Prometheus** metrics store with an on-box **`snmp_exporter`** for lab
SNMP (MikroTik, switches, firewalls). Grafana (`dnlgrf101`) queries it with PromQL.
Native binaries + systemd. Context: [grafana-setup.md](grafana-setup.md) · [lld.md](lld.md).

## Facts

| Item | Value |
|------|-------|
| Hostname | `dnlprm101` |
| Role | Prometheus + `snmp_exporter` (`prm`) |
| VMID | **1106** (VM, dc01) |
| OS | Ubuntu Server 26.04 LTS |
| VLAN / IP | **dc01_apps (1101)** — **`10.110.10.72/24`**, gw `10.110.10.1` |
| FQDN | `dnlprm101.dc01.devnetlabs.com` (apps-VLAN host → **dc01** zone) |
| vCPU / RAM | 2 × `x86-64-v2-AES` / 4 GB |
| Disks | 16 GB OS + **32 GB** data → `/var/lib/prometheus` (TSDB) |
| Listeners | Prometheus HTTP **`:9090`** · `snmp_exporter` **`127.0.0.1:9116`** (local only) |
| Retention | **30 days** (`--storage.tsdb.retention.time=30d`) |

> **Scrape model (per the LLD):** `dnlprm101` scrapes the **full fleet across both DCs**
> and is the **authoritative, always-on** copy; dc02's `dnlprm201` is an independent
> redundant copy (gaps when dc02 is off). Each Prometheus polls devices through its **own
> local `snmp_exporter`** (the proxy pattern) — so `snmp_exporter` stays bound to
> `127.0.0.1` and needs no inbound firewall rule.

---

## Part A — Create the VM (on dc01)

```bash
qm create 1106 --name dnlprm101 --machine q35 --bios ovmf \
  --cpu x86-64-v2-AES --cores 2 --sockets 1 --memory 4096 \
  --scsihw virtio-scsi-single --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1101
qm set 1106 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 1106 --scsi0 local-lvm:16,discard=on,ssd=1      # OS disk
qm set 1106 --scsi1 local-lvm:32,discard=on,ssd=1      # -> /var/lib/prometheus (TSDB)
qm set 1106 --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom
qm set 1106 --boot order='ide2;scsi0'
qm start 1106
```
> Use the **dc01_apps SDN VNet** name if configured, else `vmbr0,tag=1101`. Check dc01 thin
> pool headroom (`lvs pve/data`) first.

## Part B — Install Ubuntu + static IP

Install onto the **16 GB** disk (not the 32 GB data disk). Eject the ISO, then
`/etc/netplan/01-net.yaml`:
```yaml
network:
  version: 2
  ethernets:
    ens18:                                   # confirm: ip -br a
      addresses: [10.110.10.72/24]
      routes: [{ to: default, via: 10.110.10.1 }]
      nameservers: { addresses: [172.16.10.53, 172.16.10.54], search: [dc01.devnetlabs.com] }
```
```bash
sudo hostnamectl set-hostname dnlprm101
sudo netplan apply
sudo timedatectl set-timezone Europe/Amsterdam
```
> **Check:** `ip -br a` shows `.72`; `getent hosts dnlgrf101.dc01.devnetlabs.com` resolves.
> Clock sync matters — Prometheus rejects samples with skewed timestamps.

## Part C — Base config + firewall

Key-only SSH (mirror the bastion), `chrony`, `unattended-upgrades`, `ufw`. Allow SSH from
mgmt/lab_lan and the Prometheus API/UI (`:9090`) from Grafana + where you browse:
```bash
sudo apt update && sudo apt install -y chrony unattended-upgrades ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 172.16.10.0/24  to any port 22   proto tcp    # SSH (mgmt / bastion)
sudo ufw allow from 172.16.254.0/24 to any port 22   proto tcp    # SSH (lab_lan)
sudo ufw allow from 10.110.10.71    to any port 9090 proto tcp    # Grafana queries (dnlgrf101)
sudo ufw allow from 172.16.10.0/24  to any port 9090 proto tcp    # direct UI (mgmt)
sudo ufw allow from 172.16.254.0/24 to any port 9090 proto tcp    # direct UI (lab_lan)
sudo ufw enable
```
> `snmp_exporter` (`:9116`) is **not** opened — only the local Prometheus scrapes it. SNMP
> polling is **outbound** UDP/161 to devices (ufw default-allow outgoing covers it).

## Part D — Mount the data disk

Guarded, same as the other builds — identify the empty 32 GB disk; never `mkfs` the OS disk:
```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
PRMDISK=/dev/sdb                                 # the empty 32G disk you confirmed
if [ -n "$(lsblk -no NAME "$PRMDISK" | tail -n +2)" ] || lsblk -no MOUNTPOINTS "$PRMDISK" | grep -q .; then
  echo "REFUSING: $PRMDISK has partitions/mountpoint — that's the OS disk."
else
  sudo mkfs.ext4 -L prom_data "$PRMDISK"
  echo 'LABEL=prom_data /var/lib/prometheus ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
  sudo mkdir -p /var/lib/prometheus && sudo mount -a
fi
```

## Part E — Install Prometheus (upstream binary + systemd)

Prometheus isn't in the Grafana apt repo; use the upstream release (current, and matches
the native-binary approach). Set `PROM_VER` to the latest from <https://prometheus.io/download>:
```bash
PROM_VER=3.13.1                                  # <-- check prometheus.io/download (current at time of writing)
cd /tmp
wget -q https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-amd64.tar.gz
tar xzf prometheus-${PROM_VER}.linux-amd64.tar.gz
cd prometheus-${PROM_VER}.linux-amd64

sudo useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
sudo install -m 0755 prometheus promtool /usr/local/bin/
sudo mkdir -p /etc/prometheus
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
```
systemd unit `/etc/systemd/system/prometheus.service`:
```ini
[Unit]
Description=Prometheus
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=30d \
  --web.listen-address=0.0.0.0:9090
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
*(Alternative for a quick lab: `sudo apt install prometheus prometheus-snmp-exporter` — simpler but older versions.)*

## Part F — Install `snmp_exporter` (on-box, localhost)

Set `SNMP_VER` from <https://github.com/prometheus/snmp_exporter/releases>:
```bash
SNMP_VER=0.30.1                                  # <-- check the releases page (current at time of writing)
cd /tmp
wget -q https://github.com/prometheus/snmp_exporter/releases/download/v${SNMP_VER}/snmp_exporter-${SNMP_VER}.linux-amd64.tar.gz
tar xzf snmp_exporter-${SNMP_VER}.linux-amd64.tar.gz
sudo install -m 0755 snmp_exporter-${SNMP_VER}.linux-amd64/snmp_exporter /usr/local/bin/
sudo mkdir -p /etc/snmp_exporter
sudo cp snmp_exporter-${SNMP_VER}.linux-amd64/snmp.yml /etc/snmp_exporter/   # default: if_mib + common modules
sudo chown -R prometheus:prometheus /etc/snmp_exporter
```
systemd unit `/etc/systemd/system/snmp_exporter.service`:
```ini
[Unit]
Description=Prometheus SNMP Exporter
After=network-online.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/snmp_exporter --config.file=/etc/snmp_exporter/snmp.yml --web.listen-address=127.0.0.1:9116
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
> The shipped `snmp.yml` covers `if_mib` (interfaces) + common modules. For vendor-specific
> OIDs (MikroTik, Cisco, PAN-OS…), regenerate it with the snmp_exporter **generator** from
> the vendor MIBs — a later refinement.

## Part G — Prometheus config (`/etc/prometheus/prometheus.yml`)

Self-scrape + the **SNMP proxy** pattern (Prometheus hands each device target to the local
`snmp_exporter`). List **all fleet device IPs across both DCs** under `snmp` targets:
```yaml
global:
  scrape_interval: 30s
  scrape_timeout: 10s

scrape_configs:
  - job_name: prometheus                 # self
    static_configs:
      - targets: ['localhost:9090']

  # - job_name: node                     # enable once node_exporter (:9100) is on hosts
  #   static_configs:
  #     - targets: ['10.110.10.70:9100','10.110.10.71:9100','10.110.10.72:9100']

  - job_name: snmp
    metrics_path: /snmp
    params:
      module: [if_mib]                   # default module (per-device override via a label — see below)
    file_sd_configs:                     # targets live in a JSON file, hot-reloaded on change
      - files: ['/etc/prometheus/targets/snmp_*.json']
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9116      # the LOCAL snmp_exporter does the polling
```

**Device list — a JSON file, edit/generate freely.** `file_sd_configs` reads any
`/etc/prometheus/targets/snmp_*.json`; Prometheus **auto-reloads within `refresh_interval`
— no restart**. List all fleet devices (both DCs). Create the dir + file:
```bash
sudo mkdir -p /etc/prometheus/targets
sudo tee /etc/prometheus/targets/snmp_devices.json >/dev/null <<'EOF'
[
  { "targets": ["172.16.10.1"],  "labels": { "vendor": "mikrotik", "role": "core-router" } },
  { "targets": ["10.120.10.1"],  "labels": { "vendor": "mikrotik", "role": "svi" } }
]
EOF
sudo chown -R prometheus:prometheus /etc/prometheus/targets
```
- Each object's `targets` are device mgmt IPs; `labels` are attached to every series from
  those devices (filter in PromQL / Grafana by `vendor`, `role`, …).
- **Add/remove a device:** edit the JSON (keep it valid — `jq . …`) and save; Prometheus
  picks it up on the next refresh. To confirm: **Status → Service Discovery / Targets** in
  the UI.
- **Per-device SNMP module:** override the job default by adding `"__param_module": "<mod>"`
  to that entry's `labels` (a `__param_*` meta-label sets the URL param for just that
  target) — e.g. a Cisco device using a `cisco` module while others use `if_mib`.
- **Dynamic source:** generate this JSON from **NetBox** (same pattern as the rsyslog
  `sources.json`, #33) once NetBox is the SoT — then adds/removes are automatic.

Validate + start everything:
```bash
sudo promtool check config /etc/prometheus/prometheus.yml     # must be SUCCESS
sudo systemctl daemon-reload
sudo systemctl enable --now snmp_exporter prometheus
```
> **Check:** `curl -s localhost:9090/-/ready` → `Prometheus Server is Ready`;
> `curl -s 'localhost:9090/api/v1/targets' | jq '.data.activeTargets[].health'` → `"up"`.

## Part H — Wire Grafana

Grafana (`dnlgrf101`) already provisions a Prometheus datasource at
`http://dnlprm101.dc01.devnetlabs.com:9090` ([grafana-setup.md](grafana-setup.md) Part E).
With Part C's ufw allowing `.71`, it flips from "down" to working — **Connections → Data
sources → Prometheus → Save & test** → "working".

---

## Verification & success criteria

**✅ Success criteria — Prometheus is serving when:**
- [ ] `curl -s localhost:9090/-/ready` → `Prometheus Server is Ready`.
- [ ] `snmp_exporter` answers locally: `curl -s 'localhost:9116/snmp?target=<device-ip>&module=if_mib' | head`.
- [ ] The `snmp` job targets show **`up`** in `:9090/api/v1/targets`.
- [ ] The TSDB writes to `/var/lib/prometheus` (the 32 GB disk), not `/`.
- [ ] Grafana's Prometheus datasource **Save & test** passes and PromQL returns data.

**🧪 End-to-end test:**
```bash
sudo promtool check config /etc/prometheus/prometheus.yml           # SUCCESS
curl -s localhost:9090/-/ready                                      # ready
curl -s 'localhost:9116/snmp?target=172.16.10.1&module=if_mib' | head   # raw SNMP metrics
curl -s 'localhost:9090/api/v1/targets' | jq '.data.activeTargets[]|{job:.labels.job,health}'
df -h /var/lib/prometheus                                           # data on the 32G disk
# in Grafana Explore (Prometheus): up  -> series with value 1
```

**⚠️ Watch out for:**
- **Grafana datasource "down"** — Prometheus ufw must allow Grafana `10.110.10.71` on `:9090` (Part C).
- **SNMP target `down`** — device SNMP not enabled / wrong community / wrong `module`; the `snmp.yml` module must match `params.module`.
- **`instance` shows `127.0.0.1`** — relabel missing; the three `relabel_configs` must be present or every device collapses onto the exporter's address.
- **TSDB on `/`** — `--storage.tsdb.path` must point at the mounted disk.
- **Version drift** — `PROM_VER`/`SNMP_VER` are placeholders; use the current releases.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| `prometheus.service` won't start | bad `prometheus.yml` | `sudo promtool check config …`; `journalctl -u prometheus -n50` |
| Grafana Prometheus datasource times out | Prometheus ufw missing Grafana on `:9090` | `sudo ufw allow from 10.110.10.71 to any port 9090 proto tcp` |
| `snmp` target `health="down"` | device SNMP off / wrong community / unreachable | `curl 'localhost:9116/snmp?target=<ip>&module=if_mib'`; enable SNMP on the device; check UDP/161 reachability |
| All SNMP metrics labelled `instance="127.0.0.1:9116"` | missing/again-ordered `relabel_configs` | restore the three relabel rules (Part G) |
| `snmp_exporter` unknown module | `params.module` not in `snmp.yml` | pick a module present in `snmp.yml`, or regenerate with the generator |
| Edited the JSON but targets didn't change | invalid JSON, or file not matched by the `files:` glob | `jq . /etc/prometheus/targets/snmp_devices.json`; confirm the path/glob; check **Status → Service Discovery** in the UI |
| TSDB fills `/` | wrong `--storage.tsdb.path` | point it at `/var/lib/prometheus`; confirm the disk is mounted |
| Samples rejected (timestamp) | host clock skew | `timedatectl`; ensure chrony synced |
| Retention not applied | flag typo / not restarted | confirm `--storage.tsdb.retention.time=30d`; `systemctl restart prometheus` |

---

See also: [grafana-setup.md](grafana-setup.md) · [loki-setup.md](loki-setup.md) ·
[lld.md](lld.md) · [log-source-onboarding.md](log-source-onboarding.md)
