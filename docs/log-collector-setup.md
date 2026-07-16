# Log Collector VM Setup — `dnllog101` / `dnllog201`

Provision the two Ubuntu **rsyslog collector** VMs (an HA pair). This runbook builds the
**VMs + base OS**; the service config lives in [rsyslog-setup.md](rsyslog-setup.md) and
the floating VIP in [keepalived-setup.md](keepalived-setup.md).

## Facts

| Item | `dnllog101` | `dnllog201` |
|------|-------------|-------------|
| Node | dc01 (always-on) | dc02 (on-demand) |
| VMID | **1004** | **2004** |
| IP | **172.16.10.71/24** | **172.16.10.72/24** |
| HA role | active (VIP holder) | standby |

**Shared:** VIP **`172.16.10.70`** · VLAN 1000 · gateway `172.16.10.1` · DNS `172.16.10.53`
· OS **Ubuntu Server 26.04 LTS** (matches the fleet) · **2 vCPU** `x86-64-v2-AES` · **2 GB**
RAM · **16 GB** OS disk + **80 GB** log data disk. Build **both identically**.

> Why a separate 80 GB disk: the `/var/log/devnetlabs_logs/` archive (90-day retention)
> is the only real capacity driver — keep it off root so logs can't fill `/`.

---

## Part A — Create the VM (run on the respective Proxmox node)

**dc01 — `dnllog101` (VMID 1004):**
```bash
qm create 1004 --name dnllog101 --machine q35 --bios ovmf \
  --cpu x86-64-v2-AES --cores 2 --sockets 1 --memory 2048 \
  --scsihw virtio-scsi-single --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1000
qm set 1004 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 1004 --scsi0 local-lvm:16,discard=on,ssd=1      # OS disk
qm set 1004 --scsi1 local-lvm:80,discard=on,ssd=1      # -> /var/log/devnetlabs_logs
qm set 1004 --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom
qm set 1004 --boot order='ide2;scsi0'
qm start 1004
```

**dc02 — `dnllog201` (VMID 2004):** identical, on the dc02 node shell, with
`--name dnllog201`, VMID `2004`, and the same VLAN 1000 NIC
(`--net0 virtio,bridge=vmbr0,tag=1000`). `--onboot 1` so it comes up as the standby
whenever dc02 is powered on.

> Swap `vmbr0,tag=1000` for your **SDN mgmt VNet** name if that's how the node is set up.

## Part B — Install Ubuntu + static IP

Console → install **Ubuntu Server (minimal)**, target the 16 GB `scsi0` disk, create your
admin user. After install, eject the ISO:
```bash
qm set 1004 --ide2 none,media=cdrom && qm set 1004 --boot order='scsi0' && qm reboot 1004
```
Set hostname + static IP. `/etc/netplan/01-mgmt.yaml` (dnllog101 shown; use `.72` +
`dc02.devnetlabs.com` for dnllog201):
```yaml
network:
  version: 2
  ethernets:
    ens18:                                   # confirm with: ip -br a
      addresses: [172.16.10.71/24]
      routes: [{ to: default, via: 172.16.10.1 }]
      nameservers: { addresses: [172.16.10.53], search: [dc01.devnetlabs.com] }
```
```bash
sudo hostnamectl set-hostname dnllog101      # dnllog201 on the other
sudo netplan apply
```
> Search-domain zoning for mgmt hosts is pending the shared-VLAN DNS decision (#28) —
> `dc01`/`dc02` shown for now.

## Part C — Base config

**User + key-only SSH** (mirror the bastion — see [bastion-setup.md](bastion-setup.md)):
create your user, install your public key, then the `10-hardening.conf` sshd drop-in
(`PasswordAuthentication no`, `PermitRootLogin no`, `AllowGroups sshusers`).

**Time (critical) + patching:**
```bash
sudo apt update && sudo apt install -y chrony unattended-upgrades ufw
sudo dpkg-reconfigure -plow unattended-upgrades
```
> `chrony` matters here specifically: log **filenames** use the collector's date
> (`%$now%`) and rotation keys off it — a wrong clock mis-buckets logs.

**Firewall (default deny):**
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 172.16.10.0/24  to any port 22 proto tcp     # SSH (mgmt)
sudo ufw allow from 172.16.254.0/24 to any port 22 proto tcp     # SSH (lab_lan)
sudo ufw allow proto udp to any port 514                          # syslog in
sudo ufw allow proto tcp to any port 514
sudo ufw allow from 172.16.10.72                                  # VRRP peer (on log101; use .71 on log201)
sudo ufw enable
```

## Part D — Mount the log data disk

```bash
lsblk                                                # find the 80G disk (e.g. /dev/sdb)
sudo mkfs.ext4 -L devnetlabs_logs /dev/sdb
echo 'LABEL=devnetlabs_logs /var/log/devnetlabs_logs ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /var/log/devnetlabs_logs && sudo mount -a
sudo install -d -m 0750 -o syslog -g adm /var/log/devnetlabs_logs
```
(Mount by **LABEL** so a device-letter change doesn't break `fstab`.)

## Part E — Install the services

1. **rsyslog collector** — listeners, `sources.json` classification, dynafile tree,
   rotation, Loki/Graylog fan-out: follow [rsyslog-setup.md](rsyslog-setup.md).
2. **keepalived VIP `172.16.10.70`** — MASTER on `dnllog101`, BACKUP on `dnllog201`,
   `chk_rsyslog` failover: follow [keepalived-setup.md](keepalived-setup.md).

## Part F — Verify

```bash
hostnamectl                                  # dnllog101 / dnllog201
ip -br a                                      # .71 / .72 on ens18
df -h /var/log/devnetlabs_logs                # the 80G disk is mounted
timedatectl                                   # clock synced (chrony)
```
Then the VIP + syslog end-to-end checks from the keepalived/rsyslog runbooks.

---

See also: [rsyslog-setup.md](rsyslog-setup.md) · [keepalived-setup.md](keepalived-setup.md) ·
[logging-design.md](logging-design.md) · [lld.md](lld.md)
