# Loki Setup Runbook — `dnllok101`

Stand up the always-on **Loki** log store on dc01. Grafana **Alloy** on the rsyslog
collectors tails `/var/log/devnetlabs_logs/**` and pushes here; Grafana queries it with
LogQL. Single-binary Loki, filesystem storage, 60-day retention. Context:
[logging-design.md](logging-design.md) · [rsyslog-setup.md](rsyslog-setup.md) (Part 6).

## Facts

| Item | Value |
|------|-------|
| Hostname | `dnllok101` |
| Role | Loki log store (`lok`) |
| VMID | **1104** (VM, dc01) |
| OS | Ubuntu Server 26.04 LTS |
| VLAN / IP | **dc01_apps (1101)** — **`10.110.10.70/24`**, gw `10.110.10.1` |
| FQDN | `dnllok101.dc01.devnetlabs.com` (per-node-VLAN host → **dc01** zone, #28) |
| vCPU / RAM | 2 × `x86-64-v2-AES` / 4 GB |
| Disks | 16 GB OS (`local-lvm`) + **32 GB** data → `/var/lib/loki` |
| Listener | HTTP **`:3100`** (push + query API) |
| Storage / retention | filesystem chunks + **TSDB** index, **60-day** retention |

> **Why dc01_apps, not mgmt:** deliberately on the apps VLAN. Collectors (VLAN 1000) reach
> it cross-VLAN via the MikroTik (inter-VLAN routing is open). Being a per-node-VLAN host,
> its DNS zone is `dc01.devnetlabs.com` — so Alloy must push to the **FQDN**
> `dnllok101.dc01.devnetlabs.com:3100`, not the short name.

---

## Part A — Create the VM (on dc01)

```bash
qm create 1104 --name dnllok101 --machine q35 --bios ovmf \
  --cpu x86-64-v2-AES --cores 2 --sockets 1 --memory 4096 \
  --scsihw virtio-scsi-single --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1101
qm set 1104 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 1104 --scsi0 local-lvm:16,discard=on,ssd=1      # OS disk
qm set 1104 --scsi1 local-lvm:32,discard=on,ssd=1      # -> /var/lib/loki
qm set 1104 --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom
qm set 1104 --boot order='ide2;scsi0'
qm start 1104
```
> Use the **dc01_apps SDN VNet** name if configured, else `vmbr0,tag=1101`. Mind the thin
> pool headroom on dc01 (`lvs pve/data`) before adding disks.

## Part B — Install Ubuntu + static IP

Install onto the **16 GB** disk — same caution as the collectors: **do not** target the
32 GB data disk. Eject the ISO, then `/etc/netplan/01-net.yaml`:
```yaml
network:
  version: 2
  ethernets:
    ens18:                                   # confirm: ip -br a
      addresses: [10.110.10.70/24]
      routes: [{ to: default, via: 10.110.10.1 }]
      nameservers: { addresses: [172.16.10.53, 172.16.10.54], search: [dc01.devnetlabs.com] }
```
```bash
sudo hostnamectl set-hostname dnllok101
sudo netplan apply
sudo timedatectl set-timezone Europe/Amsterdam
```
> **Check:** `ip -br a` shows `.70` on `ens18`; `getent hosts dnldns101.mgmt.devnetlabs.com`
> resolves (DNS reachable cross-VLAN).

## Part C — Base config + firewall

Key-only SSH (mirror the bastion), `chrony`, `unattended-upgrades`, `ufw`. Allow SSH from
the mgmt networks and the Loki API **only** from the collectors (and Grafana later):
```bash
sudo apt update && sudo apt install -y chrony unattended-upgrades ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 172.16.10.0/24  to any port 22   proto tcp    # SSH (mgmt / bastion)
sudo ufw allow from 172.16.254.0/24 to any port 22   proto tcp    # SSH (lab_lan)
sudo ufw allow from 172.16.10.71    to any port 3100 proto tcp    # Alloy push (dnllog101)
sudo ufw allow from 172.16.10.72    to any port 3100 proto tcp    # Alloy push (dnllog201)
# add your Grafana host/subnet -> :3100 when Grafana exists
sudo ufw enable
```
> **No change needed on the collectors** — their Alloy→Loki push is *outbound* (ufw
> default-allow outgoing). This `:3100` allow is the only new firewall rule, and it lives
> **here** on the Loki host.

## Part D — Mount the data disk

Same guarded approach as the collectors — identify the empty 32 GB disk; never `mkfs` the
OS disk:
```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS       # data disk = 32G, TYPE disk, no children/mount
LOKIDISK=/dev/sdb                                # set to the empty 32G disk you confirmed
if [ -n "$(lsblk -no NAME "$LOKIDISK" | tail -n +2)" ] || lsblk -no MOUNTPOINTS "$LOKIDISK" | grep -q .; then
  echo "REFUSING: $LOKIDISK has partitions/mountpoint — that's the OS disk."
else
  sudo mkfs.ext4 -L loki_data "$LOKIDISK"
  echo 'LABEL=loki_data /var/lib/loki ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
  sudo mkdir -p /var/lib/loki && sudo mount -a
fi
```

## Part E — Install Loki (Grafana apt repo)

```bash
sudo apt install -y gpg
sudo mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update && sudo apt install -y loki
# The package creates the 'loki' USER but with primary group 'nogroup' and NO 'loki'
# group, so `chown loki:loki` fails until we create the group and make it loki's primary:
getent group loki >/dev/null || sudo groupadd --system loki
sudo usermod -g loki loki
sudo chown -R loki:loki /var/lib/loki
```
> The package creates the `loki` user + `loki.service` and reads `/etc/loki/config.yml`.
> ⚠️ It does **not** create a `loki` group and sets the user's primary group to `nogroup`
> — hence the `groupadd`/`usermod` above; the service unit is `User=loki` with no
> `Group=`, so it uses whatever loki's primary group is.

## Part F — Configure Loki (single-binary, filesystem, 60-day retention)

Overwrite `/etc/loki/config.yml`:
```yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore: { store: inmemory }

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index: { prefix: index_, period: 24h }

limits_config:
  retention_period: 1440h            # 60 days
  reject_old_samples: true
  reject_old_samples_max_age: 168h   # drop lines older than 7d (raise to replay old archives)
  volume_enabled: true

compactor:
  working_directory: /var/lib/loki/compactor
  retention_enabled: true            # REQUIRED — actually deletes data past retention_period
  delete_request_store: filesystem
```
```bash
sudo systemctl enable --now loki
sudo systemctl restart loki
```
> **Check:** `curl -s localhost:3100/ready` → `ready`; `journalctl -u loki -n30` clean;
> chunks appear under `/var/lib/loki/chunks` once data flows.

## Part G — Point Alloy at Loki (on **both** collectors)

Set the Loki endpoint to the **FQDN** in `/etc/alloy/config.alloy`:
```alloy
loki.write "default" { endpoint { url = "http://dnllok101.dc01.devnetlabs.com:3100/loki/api/v1/push" } }
```
```bash
sudo systemctl restart alloy
```
> The short name `dnllok101` won't resolve under the collectors' `mgmt.devnetlabs.com`
> search domain (Loki is in `dc01.devnetlabs.com`). Use the FQDN — or add
> `dc01.devnetlabs.com` to the collectors' netplan `search` list.

## Part H — DNS record

Add the A record to the **`dc01.devnetlabs.com`** zone (Technitium):
`dnllok101 → 10.110.10.70`. (Codified in `ansible/zones/dc01.devnetlabs.com.zone`.)

---

## Verification & success criteria

**✅ Success criteria — Loki is serving when:**
- [ ] `curl -s localhost:3100/ready` on dnllok101 → `ready`.
- [ ] `dnllok101.dc01.devnetlabs.com` resolves to `10.110.10.70` from the collectors.
- [ ] Alloy on both collectors pushes with **no** endpoint errors (`journalctl -u alloy`).
- [ ] A test syslog line is queryable in Loki, carrying `category`/`vendor` labels.
- [ ] Chunks land on the mounted data disk (`/var/lib/loki`), not on `/`.

**🧪 End-to-end test:**
```bash
# on a collector — resolve + reach Loki:
getent hosts dnllok101.dc01.devnetlabs.com                 # -> 10.110.10.70
curl -s http://dnllok101.dc01.devnetlabs.com:3100/ready    # ready
# generate a line via the VIP (keepalived up):
logger -n 172.16.10.70 -P 514 -d "loki e2e test"
# on dnllok101 — query it:
curl -sG http://localhost:3100/loki/api/v1/labels | jq .   # includes "category","vendor"
curl -sG http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={category="others"}' | jq '.data.result | length'   # > 0
df -h /var/lib/loki                                        # data on the 32G disk
```
Expected: `/ready` → `ready`, labels include `category`/`vendor`, the test line is returned.

**⚠️ Watch out for:**
- **Alloy can't resolve `dnllok101`** — use the **FQDN**; the mgmt search domain won't find the dc01 zone. Symptom: `journalctl -u alloy` shows no-such-host on the push endpoint.
- **`:3100` blocked** — the Loki host ufw must allow `:3100` from the collectors (`.71`/`.72`) and Grafana; the collectors need **no** change (push is outbound).
- **Empty queries / no labels** — Alloy still can't read the tree: apply the `syslog:adm` group fix ([rsyslog-setup.md](rsyslog-setup.md) Part 4) and confirm `sudo -u alloy` can read a log file.
- **Retention not enforced** — `compactor.retention_enabled: true` (+ `delete_request_store`) is required; without it Loki keeps data forever regardless of `retention_period`.
- **`/` fills up** — chunks must live on the data disk via `common.path_prefix: /var/lib/loki`; verify with `df -h`.
- **Old samples rejected** — `reject_old_samples_max_age` drops lines older than 7d; replaying old archives needs it raised.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| `chown loki:loki` → `invalid group 'loki'` | package made the `loki` user with primary group `nogroup`, no `loki` group | `getent group loki \|\| sudo groupadd --system loki` → `sudo usermod -g loki loki` → retry |
| `/ready` → `Ingester not ready: waiting for 15s` | normal startup grace period | wait ~20 s and re-`curl`; it flips to `ready` |
| `/labels` empty, queries return `0` | Alloy can't read the tree, or nothing ingested | fix `fileGroup="adm"` on the collectors (rsyslog Part 4); `sudo -u alloy head` a log file |
| Alloy journal: `lookup dnllok101 … no such host` | endpoint uses the **short** name | use the FQDN `http://dnllok101.dc01.devnetlabs.com:3100/loki/api/v1/push` |
| Collector can't reach `:3100` | Loki host ufw missing the allow | on Loki: `sudo ufw allow from 172.16.10.71 to any port 3100 proto tcp` (and `.72`) |
| Old data never deleted | `compactor.retention_enabled` not set | set `retention_enabled: true` + `delete_request_store: filesystem`; restart |
| `/` fills up while `/var/lib/loki` is empty | chunks written to root | set `common.path_prefix: /var/lib/loki`; confirm the data disk is mounted |
| Stream count flat but data seems missing | `.data.result \| length` counts **streams**, not lines; same file path merges into one stream | query content (`\|= "…"`) or count `.values[]` |
| Push rejected: entry too far behind | line older than `reject_old_samples_max_age` (7 d) | raise it to replay old archives, or accept the drop |

---

See also: [logging-design.md](logging-design.md) · [rsyslog-setup.md](rsyslog-setup.md) ·
[log-collector-setup.md](log-collector-setup.md) · [lld.md](lld.md)
