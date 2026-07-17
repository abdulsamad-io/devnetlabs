# TrueNAS Setup Runbook — `dnlnas101`

Build and configure the DevNetLabs TrueNAS VM on dc01, with the 1.92 TB SSD passed
through for a ZFS data pool.

## Host facts

| Item | Value |
|------|-------|
| Hostname | `dnlnas101` |
| Role | TrueNAS / NAS (`nas`) |
| VMID | 1301 (VM, dc01) |
| OS | TrueNAS Community Edition (SCALE) **25.10.4 Goldeye** |
| IP | `10.110.30.50/24` (static, VLAN 1103 / `dc01_nas`) |
| Gateway | `10.110.30.1` |
| vCPU / RAM | 2 × `x86-64-v2-AES` / 8 GB (**ballooning off** — ZFS ARC) |
| Boot disk | 32 GB on `local-lvm` (NVMe) |
| Data disk | Intel DC S4500 **1.92 TB** SATA, passed through by-id |
| Machine / BIOS | q35 / OVMF (UEFI), `pre-enrolled-keys=0` |

**Concept:** TrueNAS runs as a VM; the physical SSD is handed to it so ZFS owns the
data disk. TrueNAS then exports SMB/NFS shares consumed by other guests (e.g. Plex
`dnlplx101`). The TrueNAS OS lives on a small NVMe-backed virtual disk — **never** on
the data SSD.

---

## Part A — Verify the data disk (on dc01)

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,TRAN
ls -l /dev/disk/by-id/ | grep -iv part
lspci | grep -iE 'sata|ahci|vmd'
```

Expected: the SSD appears as `sda`, model `INTEL SSDSC2KB019T7`, `TRAN=sata`, with a
stable path **`/dev/disk/by-id/ata-INTEL_SSDSC2KB019T7_BTYS818300LU1P9DGN`**.

> **If the disk is missing entirely**, it's a BIOS issue, not Proxmox:
> - #1 cause on 13th-gen Intel mini PCs: **Intel VMD enabled** — hides SATA from Linux.
>   BIOS → set SATA to **AHCI**, **disable VMD/RST**.
> - Also check the SATA port/bay is enabled and the drive is seated.
> Raw disks show under **dc01 → Disks**, *not* Datacenter → Storage. For passthrough we
> deliberately do **not** create Proxmox storage on it.

**Check what's on it before wiping** (creating the pool is irreversible):
```bash
blkid /dev/sda1 /dev/sda2
zpool import                 # any importable ZFS pool?
mount -o ro -t ntfs3 /dev/sda1 /mnt/check && ls -lah /mnt/check; umount /mnt/check
```
*(This drive shipped with an empty NTFS volume — `$RECYCLE.BIN` + `System Volume
Information` only — safe to wipe.)*

---

## Part B — Get the ISO

Download **TrueNAS Community Edition (SCALE)** to dc01: **local → ISO Images →
Download from URL**.

- URL: `https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.4/TrueNAS-SCALE-25.10.4.iso`
- SHA256: `efb57cc9a23835c2ffd74326c61251bdb3d627f57bcd2a806a152aee0bb98d66`
- Do this on the **LAN** (not via the Cloudflare tunnel — 100 MB cap).

Confirm it landed: `pvesm list local --content iso`

---

## Part C — Create the VM (boot disk only, no passthrough yet)

> Attaching the data disk *after* install removes any risk of installing TrueNAS onto
> the 1.9 TB SSD.

```bash
qm create 1301 \
  --name dnlnas101 \
  --machine q35 --bios ovmf \
  --cpu x86-64-v2-AES --cores 2 --sockets 1 \
  --memory 8192 --balloon 0 \
  --scsihw virtio-scsi-single \
  --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1103

qm set 1301 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 1301 --scsi0 local-lvm:32,discard=on,ssd=1
qm set 1301 --ide2 local:iso/TrueNAS-SCALE-25.10.4.iso,media=cdrom
qm set 1301 --boot order='ide2;scsi0'
qm start 1301
```

- `--net0`: use the **nas-zone SDN VNet** if configured (bridge = VNet name, no tag), or
  the VLAN-aware `vmbr0` with `tag=1103` as shown.
- `--balloon 0`: ballooning off (ZFS ARC).
- `pre-enrolled-keys=0`: avoids Secure Boot signature issues with the TrueNAS bootloader.

> **Boot menu troubleshooting:** if the boot menu shows only `UEFI QEMU QEMU HARDDISK`
> (no DVD), the ISO isn't mounted — check `qm config 1301 | grep ide2` and
> `pvesm list local --content iso`, ensure the `ide2` filename matches exactly, then
> `qm set 1301 --boot order='ide2;scsi0'` and restart.

---

## Part D — Install TrueNAS

Open the VM **Console**:
1. GRUB → **Start TrueNAS SCALE Installation** (the first / non-serial option).
2. Installer → **Install/Upgrade** → target the **32 GB `scsi0`** disk (the only disk
   present) → set the admin password → finish.
3. Eject the ISO and boot from disk:
   ```bash
   qm set 1301 --ide2 none,media=cdrom
   qm set 1301 --boot order='scsi0'
   qm reboot 1301
   ```

> **Check:** after reboot the console reaches the TrueNAS login/URL banner, and
> `qm config 1301 | grep -E 'boot|scsi'` shows `boot: order=scsi0` (booting the 32 GB
> disk, not the CD/data disk).

---

## Part E — Attach the 1.92 TB data SSD (now safe)

```bash
qm set 1301 --scsi1 /dev/disk/by-id/ata-INTEL_SSDSC2KB019T7_BTYS818300LU1P9DGN,discard=on,ssd=1,backup=0
```
- `by-id` → never renumbers across reboots.
- `backup=0` → vzdump won't try to snapshot 1.9 TB of NAS data (backed up separately).

> **Set a unique disk serial** (avoids a pool-wizard error). Proxmox presents
> virtual/passthrough disks without a serial, so every VM disk reads serial `None` and
> the pool wizard fails with *"Disks have duplicate serial numbers: None (sda, sdb)"*.
> Stop the VM and append a unique `serial=` to each disk line (edit
> `/etc/pve/qemu-server/1301.conf`), e.g.:
> ```
> scsi0: local-lvm:vm-1301-disk-1,discard=on,size=32G,ssd=1,serial=BOOT001
> scsi1: /dev/disk/by-id/ata-INTEL_SSDSC2KB019T7_BTYS818300LU1P9DGN,backup=0,discard=on,ssd=1,serial=S4500DATA01
> ```

---

## Part F — Configure TrueNAS (web UI)

1. **Network → Global Configuration:** hostname `dnlnas101`.
2. **Network → Interfaces:** set the NIC to **static `10.110.30.50/24`**, gateway
   `10.110.30.1`, DNS as appropriate. (Alternatively a DHCP reservation on the MikroTik.)
3. **Storage → Disks:** the passed SSD still has NTFS partitions — select it and
   **Wipe** (Quick). *This is the destructive step (confirmed safe in Part A).*
4. **Storage → Create Pool:** single-disk (stripe) vdev on that SSD — **no redundancy**.
5. **Datasets → Add**, then **Shares** → SMB (Windows) and/or NFS (Unix) as needed.
   Plex (`dnlplx101`) mounts media from here.

---

## Part G — Backup & caveats

- **Single-disk pool = zero redundancy.** Back it up:
  - ZFS **replication** to another node, and/or
  - **PBS**. This ties into the still-open **M.2 2242 role** decision (local PBS vs
    vzdump + replication target) — see [OPEN-ITEMS.md](OPEN-ITEMS.md).
- Disk passthrough (by-id) gives TrueNAS a virtual SCSI disk, not a raw HBA — SMART
  visibility is limited. For a single home-lab SSD this is the pragmatic standard;
  the purist alternative is PCIe passthrough of the whole SATA controller (only clean
  if that controller is alone in its IOMMU group).
- Do **not** create Proxmox storage/LVM on `sda` — it's dedicated to this VM.

---

## Part H — As-built configuration

**Pool:** `dnl_pool001` — single-disk **stripe**, ~1.75 TiB, **no redundancy**.

**Datasets** (under `dnl_pool001`):

| Dataset | Preset | Purpose | Shared via |
|---------|--------|---------|------------|
| `abdulsamad_nas` | SMB | Abdulsamad's personal files | SMB |
| `hameedah_nas` | SMB | Hameedah's personal files | SMB |
| `media_nas` | Multiprotocol | Plex media library | SMB + NFS |

**Shares:**
- **SMB** (service running): `abdulsamad_nas`, `hameedah_nas`, `media_nas`
- **NFS** (service running): `/mnt/dnl_pool001/media_nas` — for Plex (`dnlplx101`);
  restrict allowed networks to `10.110.20.0/24` (media).

**Users / auth:** SMB authenticates by **account name**, not share name. Login user is
**`abdoolsamad`** (+ `hameedah` for her share).
> ⚠️ **Spelling gap:** shares are named `abdulsamad_nas` etc., but the TrueNAS account
> is **`abdoolsamad`** (double-o, matching the bastion user). Always map with the
> **account** name.

**Windows client mapping:**
```powershell
net use \\10.110.30.50 /delete /y      # clear stale sessions first
net use Z: \\10.110.30.50\abdulsamad_nas /user:abdoolsamad * /persistent:yes
```

---

## Part I — Snapshot & replication plan

- **Snapshots** (accidental-deletion / ransomware protection) — *to configure:*
  Data Protection → **Periodic Snapshot Tasks** on `abdulsamad_nas` and `hameedah_nas`
  (e.g. hourly, retain 2 weeks). Lighter/none on `media_nas` (large, re-downloadable).
  *Snapshots do not protect against the disk dying.*
- **Replication** (disk-failure protection) — *pending:* Data Protection →
  **Replication** to an off-box target (dc03 PBS or the M.2 2242). Until this exists,
  the NAS holds the **only** copy of important files — a real risk on a single-disk
  pool. Blocked on the **M.2 2242 role** decision (see [OPEN-ITEMS.md](OPEN-ITEMS.md)).

---

## Troubleshooting notes

- **Pool wizard "Error: topology — duplicate serial numbers: None".** Passthrough/virtual
  disks have no serial in Proxmox → set a unique `serial=` per disk (see Part E).
- **SMB map fails with System error 86 ("network password is not correct").** Usually a
  **username mismatch** — `/user:` must be the TrueNAS **account** (`abdoolsamad`), not
  the share name. Clear stale sessions first (`net use \\10.110.30.50 /delete /y`).
- **Disk not visible in Proxmox at all** → BIOS: set SATA to **AHCI**, disable
  **VMD/RST** (see Part A).

---

## Verification & success criteria

**✅ Success criteria — the NAS is serving when:**
- [ ] TrueNAS boots from the **32 GB** virtual disk (never the 1.92 TB SSD).
- [ ] The data SSD is a healthy ZFS pool (`dnl_pool001`, **ONLINE**) on the passed-through disk.
- [ ] Static IP `10.110.30.50` reachable; web UI loads; hostname `dnlnas101`.
- [ ] SMB/NFS shares mount from a client using the **account** name (`abdoolsamad`).

**🧪 Tests:**
```bash
# on dc01 — confirm passthrough + unique serials:
grep -E 'scsi[01]:' /etc/pve/qemu-server/1301.conf     # each line has a unique serial=
# in TrueNAS (shell or UI):
zpool status dnl_pool001                               # state: ONLINE, no errors
# from a Windows client:
net use Z: \\10.110.30.50\abdulsamad_nas /user:abdoolsamad * /persistent:yes   # maps OK
```
Expected: pool **ONLINE**, share maps without error, files read/write.

**⚠️ Watch out for:**
- **Installed onto the 1.9 TB SSD** — attach the data disk **after** install (Part E); target the 32 GB disk in the installer.
- **Pool wizard "duplicate serial numbers: None"** — Proxmox gives passthrough disks no serial; set a unique `serial=` per disk (Part E).
- **SMB error 86** — username mismatch: use the TrueNAS **account** `abdoolsamad` (double-o), not the share name; clear stale sessions first (`net use \\10.110.30.50 /delete /y`).
- **Disk absent in Proxmox** — BIOS: set SATA to **AHCI**, disable **VMD/RST** (Part A).
- **Single-disk pool = no redundancy** — snapshots ≠ backups; replication/PBS still pending (#18).

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| Pool wizard: *duplicate serial numbers: None* | passthrough/virtual disks have no serial | set a unique `serial=` per disk in `/etc/pve/qemu-server/1301.conf` (Part E) |
| SMB map fails, System error 86 | username mismatch | use the TrueNAS **account** `abdoolsamad` (double-o), not the share name; `net use \\10.110.30.50 /delete /y` first |
| Data SSD not visible in Proxmox | Intel **VMD/RST** enabled in BIOS | BIOS → SATA **AHCI**, disable VMD/RST; re-seat/enable the bay |
| TrueNAS installed on the 1.9 TB SSD | data disk attached before install | attach the data disk **after** install (Part E); target the 32 GB disk |
| Very slow SMB/NFS transfer (~10 MB/s) | 100 Mbps MikroTik (RB951 Fast Ethernet) is the bottleneck | known lab limit — a gigabit switch/router is the fix, not TrueNAS |
| Boot menu shows no DVD | ISO not mounted | `qm config 1301 \| grep ide2`; re-set `--boot order='ide2;scsi0'` |
| Single-disk pool — data at risk | stripe vdev, no redundancy | snapshots ≠ backups — stand up replication / PBS (#18) |

---

See also: [lld.md](lld.md) · [vmid-plan.md](vmid-plan.md) ·
[network-vlan-design.md](network-vlan-design.md)
