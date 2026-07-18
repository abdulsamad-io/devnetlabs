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
RAM · **16 GB** OS disk + **50 GB** log data disk. Build **both identically**.

> Why a separate 50 GB disk: the `/var/log/devnetlabs_logs/` archive (60-day retention)
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
qm set 1004 --scsi1 local-lvm:50,discard=on,ssd=1      # -> /var/log/devnetlabs_logs
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

Console → install **Ubuntu Server (minimal)**. At the **"Guided storage configuration"**
step, select the **16 GB disk** (`scsi0`, usually `/dev/sda`) as the install target —
**not** the 50 GB log disk. Before continuing, confirm the storage summary shows the ESP,
`/boot`, and root LVM all landing on the **16 GB** device.

> ⚠️ Installing onto the 50 GB disk is the easiest mistake here: the OS ends up on the
> disk meant for logs and the 16 GB disk sits empty. If `lsblk` after install shows
> `/boot`/`/` on the 50 GB disk, you targeted the wrong one — reinstall onto the 16 GB
> disk before going any further (Part D would otherwise `mkfs` your root disk).

Create your admin user. After install, eject the ISO:
```bash
qm set 1004 --ide2 none,media=cdrom && qm set 1004 --boot order='scsi0' && qm reboot 1004
```
Set hostname + static IP. `/etc/netplan/01-mgmt.yaml` (dnllog101 shown; use `.72` for
dnllog201 — both are mgmt-VLAN hosts, so identical DNS/search):
```yaml
network:
  version: 2
  ethernets:
    ens18:                                   # confirm with: ip -br a
      addresses: [172.16.10.71/24]
      routes: [{ to: default, via: 172.16.10.1 }]
      nameservers: { addresses: [172.16.10.53, 172.16.10.54], search: [mgt.devnetlabs.com] }
```
```bash
sudo hostnamectl set-hostname dnllog101      # dnllog201 on the other
sudo netplan apply
```
> Both collectors sit on the shared mgmt VLAN 1000, so their search domain is
> `mgt.devnetlabs.com` (node-neutral zone — #28 resolved). Both DNS servers
> (`.53`/`.54`) are listed for resolver redundancy.

## Part C — Base config

**User + key-only SSH** (mirror the bastion — see [bastion-setup.md](bastion-setup.md)):
create your user, install your public key, then the `10-hardening.conf` sshd drop-in
(`PasswordAuthentication no`, `PermitRootLogin no`, `AllowGroups sshusers`).

**Time (critical) + patching:**
```bash
sudo apt update && sudo apt install -y chrony unattended-upgrades ufw
sudo dpkg-reconfigure -plow unattended-upgrades
sudo timedatectl set-timezone Europe/Amsterdam   # match the fleet (CET/CEST); Ubuntu defaults to UTC
```
> `chrony` matters here specifically: log **filenames** use the collector's date
> (`%$now%`) and rotation keys off it — a wrong clock mis-buckets logs.
> **Timezone matters for the same reason:** `%$now%` and the RFC3339 line timestamps
> follow the collector's *local* time, so set it to `Europe/Amsterdam` to match the PVE
> nodes (Ubuntu installs default to `Etc/UTC`). Restart rsyslog after any later change
> (`sudo systemctl restart rsyslog`) so the daemon picks up the new zone. Trade-off:
> local time means the daily file boundary shifts at the autumn DST rollback (a repeated
> 02:00–03:00 hour) — harmless with the today+yesterday-uncompressed scheme, but the
> reason some shops keep collectors on UTC.

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

Identify the **empty 50 GB** disk first — the one that is `TYPE disk` with **no child
partitions and no mountpoint**. The OS disk shows `part`/`lvm` children and is mounted at
`/`. Device letters are **not** guaranteed (`scsi0`≠always `sda`), so never blindly
`mkfs /dev/sdb` — formatting the OS disk destroys the install.

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS   # log disk = 50G, TYPE disk, NO children, NO mountpoint
LOGDISK=/dev/sdb                             # <-- set to the empty 50G disk you just confirmed

# Guard: refuse to format anything that has partitions or is mounted (that's the OS disk)
if [ -n "$(lsblk -no NAME "$LOGDISK" | tail -n +2)" ] || lsblk -no MOUNTPOINTS "$LOGDISK" | grep -q .; then
  echo "REFUSING: $LOGDISK has partitions or a mountpoint — that's the OS disk, not the log disk."
else
  sudo mkfs.ext4 -L devnetlabs_logs "$LOGDISK"
  echo 'LABEL=devnetlabs_logs /var/log/devnetlabs_logs ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
  sudo mkdir -p /var/log/devnetlabs_logs && sudo mount -a
  sudo install -d -m 0750 -o syslog -g adm /var/log/devnetlabs_logs
fi
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
df -h /var/log/devnetlabs_logs                # the 50G disk is mounted
timedatectl                                   # clock synced (chrony)
```
Then the VIP + syslog end-to-end checks from the keepalived/rsyslog runbooks.

---

## Verification & success criteria

**✅ Success criteria — the VM base is ready when:**
- [ ] `lsblk` shows `/boot` + `/` (LVM) on the **16 GB** disk; the **50 GB** disk is a bare `disk`.
- [ ] `/var/log/devnetlabs_logs` is mounted from the 50 GB disk (by **LABEL**), owned `syslog:adm`.
- [ ] `ip -br a` shows `.71`/`.72` on `ens18`; DNS resolves via `.53`/`.54`; search `mgt.devnetlabs.com`.
- [ ] `timedatectl` synced + timezone `Europe/Amsterdam`; key-only SSH; ufw default-deny with 514 open.

**🧪 Test (Part F):**
```bash
lsblk                                        # OS on 16G; 50G log disk separate
df -h /var/log/devnetlabs_logs               # mounted from the 50G disk
findmnt /var/log/devnetlabs_logs             # source shows LABEL=devnetlabs_logs
ip -br a; timedatectl                         # .71/.72 on ens18; CEST; NTP synced
```

**⚠️ Watch out for:**
- **OS installed on the 50 GB disk** — the #1 mistake; if `lsblk` shows `/` on the 50 GB disk, reinstall onto the 16 GB disk (Part B).
- **`mkfs` the wrong disk** — Part D's guard refuses a disk with partitions/mountpoint; still eyeball `lsblk` and set `LOGDISK` deliberately.
- **UTC filenames** — set the timezone (Part C) or log dates bucket in UTC.
- **VRRP-peer ufw line** — `.72` on log101, `.71` on log201 (reversed per host).

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| After install, `/boot`/`/` on the **50 GB** disk | installer targeted the wrong disk | reinstall onto the **16 GB** disk (Part B); leave the 50 GB bare |
| Part D refuses to `mkfs` | guard hit — target has partitions or a mountpoint (the OS disk) | re-check `lsblk`; set `LOGDISK` to the empty 50 GB disk |
| `/var/log/devnetlabs_logs` not mounted after reboot | fstab `LABEL` mismatch | `findmnt /var/log/devnetlabs_logs`; `sudo e2label /dev/sdX devnetlabs_logs`; `sudo mount -a` |
| Log filenames show the wrong date | timezone still `Etc/UTC` | `sudo timedatectl set-timezone Europe/Amsterdam`; `systemctl restart rsyslog` |
| VRRP peer traffic blocked | ufw peer line uses the wrong octet | `.72` on log101, `.71` on log201 (reversed per host) |
| No syslog received | rsyslog not listening / firewall | `ss -lntu \| grep :514`; `sudo ufw status`; see [rsyslog-setup.md](rsyslog-setup.md) |

---

See also: [rsyslog-setup.md](rsyslog-setup.md) · [keepalived-setup.md](keepalived-setup.md) ·
[logging-design.md](logging-design.md) · [lld.md](lld.md)
