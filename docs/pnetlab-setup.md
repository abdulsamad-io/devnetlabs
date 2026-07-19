# PNETLab Setup Runbook — `dnlpnt201`

Build the **PNETLab** network-emulation platform on **dc02** (the heavy / nested-virt node).
PNETLab runs device images (Cisco, Juniper, PAN-OS…) as nested VMs, so it needs **nested
virtualization**, lots of RAM, and a big image store — which lives on a **separate 300 GB
data volume**, not the OS disk. Context: [lld.md](lld.md) · [vmid-plan.md](conventions/vmid-plan.md).

> **Placement is still an open decision (#19)** — dc02 (`dnlpnt201`) vs a light on-demand
> dc01 (`dnlpnt101`). This runbook builds the documented dc02 allocation.

## Facts

| Item | Value |
|------|-------|
| Hostname | `dnlpnt201` |
| Role | PNETLab — network emulation (`pnt`) |
| VMID | **2101** (VM, dc02) |
| VLAN / IP | mgmt NIC on **VLAN 1000** — **`172.16.10.60/24`**, gw `172.16.10.1` (UI + SSH); lab uplinks on dc02_apps (1201) as needed |
| FQDN | `dnlpnt201.mgt.devnetlabs.com` (UI reachable on the mgmt NIC → **mgt** zone) |
| CPU | **`host`** — **required** for nested KVM (⚠️ *not* the fleet's `x86-64-v2-AES`) |
| vCPU / RAM | **4 vCPU** / **20 GB** (`--balloon 0`; scale cores up for big labs) |
| Disks | **40 GB OS** + **300 GB data** → `/opt/unetlab` (images + labs) |
| Machine / BIOS | q35 / **SeaBIOS** (appliance-friendly; see OVMF note) |
| Web UI | HTTP **`:80`**, default login **`admin` / `pnet`** (change on first login) |
| Media | latest **PNETLab ISO** from <https://pnetlab.com> (OVA import is an alternative) |

> **CPU caveat:** `host` exposes VMX for nested KVM but **breaks live-migration** to a
> dissimilar node — PNETLab is effectively **node-locked to dc02** (which is fine; dc02 is
> the nested-virt node). This is a deliberate exception to the `x86-64-v2-AES` convention.

---

## Part A — Enable nested virtualization on the dc02 host (prerequisite)

On the **dc02 Proxmox node** (Intel):
```bash
cat /sys/module/kvm_intel/parameters/nested       # want: Y
# if N:
echo "options kvm-intel nested=1" | sudo tee /etc/modprobe.d/kvm-intel.conf
sudo modprobe -r kvm_intel 2>/dev/null; sudo modprobe kvm_intel   # or reboot the node if in use
```
> Without host-level nested virt, the VM's `host` CPU won't expose `vmx` and PNETLab's device
> nodes fail to start.

## Part B — Create the VM (on dc02)

```bash
qm create 2101 --name dnlpnt201 --machine q35 --bios seabios \
  --cpu host --cores 4 --sockets 1 --memory 20480 --balloon 0 \
  --scsihw virtio-scsi-single --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1000
qm set 2101 --scsi0 local-lvm:40,discard=on,ssd=1      # OS disk
qm set 2101 --scsi1 local-lvm:300,discard=on,ssd=1     # -> /opt/unetlab (images + labs)
qm set 2101 --ide2 local:iso/PNETLab_<ver>.iso,media=cdrom   # <-- the ISO you downloaded
qm set 2101 --boot order='ide2;scsi0'
qm start 2101
```
- `--cpu host` + `--balloon 0` (nested guests need real, non-ballooned RAM).
- Add a lab-uplink NIC later if you want labs to reach the real network:
  `qm set 2101 --net1 virtio,bridge=vmbr0,tag=1201`.
> ⚠️ **Thin-pool headroom:** 300 GB is large. Check dc02 first — `lvs -o name,lv_size,data_percent pve/data`
> — the pool was ~76 % used earlier; a 300 GB thin disk over-commits and can fill it as
> images land. Consider a different/dedicated storage for `scsi1` if space is tight.
> **OVMF note:** if the PNETLab ISO won't boot/install under SeaBIOS, retry with q35+OVMF
> (`--bios ovmf` + an `--efidisk0`); appliance installers vary.

## Part C — Install PNETLab (from the ISO)

Open the VM **Console** and follow the installer: target the **40 GB `scsi0`** disk (leave the
300 GB `scsi1` untouched), set the root password, and complete. Then eject the ISO:
```bash
qm set 2101 --ide2 none,media=cdrom && qm set 2101 --boot order='scsi0' && qm reboot 2101
```
> The installer lays PNETLab down on `scsi0` (its data tree at `/opt/unetlab`). We relocate
> that heavy tree to the 300 GB disk in Part E — do it **before** loading images.

## Part D — Network (mgmt IP on VLAN 1000)

PNETLab's mgmt interface is **`pnet0`**. Set a static IP for the UI/SSH. Via the wizard
(`/opt/unetlab/wrappers/unl_wrapper -a fixpermissions` era tooling) or edit netplan/interfaces:
```
# /etc/netplan/01-mgmt.yaml (bridge pnet0 to ens18)
network:
  version: 2
  ethernets: { ens18: {} }
  bridges:
    pnet0:
      interfaces: [ens18]
      addresses: [172.16.10.60/24]
      routes: [{ to: default, via: 172.16.10.1 }]
      nameservers: { addresses: [172.16.10.53, 172.16.10.54], search: [mgt.devnetlabs.com] }
```
```bash
sudo netplan apply
sudo hostnamectl set-hostname dnlpnt201
sudo timedatectl set-timezone Europe/Amsterdam
```
> PNETLab uses `pnet0..pnet9` bridges — `pnet0` is management; `pnet1+` map to extra NICs for
> lab-to-real-network "cloud" bridges. **Check:** `ip -br a` shows `172.16.10.60` on `pnet0`.

## Part E — Move the data store to the 300 GB volume

Put `/opt/unetlab` (images, labs, temp) on `scsi1` so the OS disk stays lean:
```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS         # identify the empty 300G disk (e.g. sdb)
DATADISK=/dev/sdb                                  # the 300G disk you confirmed
sudo mkfs.ext4 -L pnet_data "$DATADISK"
sudo systemctl stop pnetlab 2>/dev/null; sudo pkill -f unl_wrapper 2>/dev/null || true
sudo mv /opt/unetlab /opt/unetlab.old
sudo mkdir -p /opt/unetlab
echo 'LABEL=pnet_data /opt/unetlab ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mount -a
sudo rsync -aHAX /opt/unetlab.old/ /opt/unetlab/    # copy the tree onto the data disk
sudo /opt/unetlab/wrappers/unl_wrapper -a fixpermissions
sudo rm -rf /opt/unetlab.old
sudo reboot
```
> Guard: only `mkfs` the **empty 300 GB** disk (no partitions/mountpoint) — never the OS disk.
> `unl_wrapper -a fixpermissions` re-applies PNETLab's ownership after the move.

## Part F — First login + images

1. Browse `http://172.16.10.60/` (or `http://dnlpnt201.mgt.devnetlabs.com/` once the DNS
   record is in). Log in **`admin` / `pnet`** → change the password immediately.
2. Add device images under **`/opt/unetlab/addons/`** (qemu/iol/dynamips) — now on the 300 GB
   volume — then `sudo /opt/unetlab/wrappers/unl_wrapper -a fixpermissions`. (PNETLab's online
   "store" can pull community images.)
3. Build a test lab with 2 nodes and start them to confirm nested virt works.

## Part G — DNS record

Add `dnlpnt201 → 172.16.10.60` in the **`mgt.devnetlabs.com`** zone (mgmt NIC → mgt zone).

---

## Verification & success criteria

**✅ Success criteria — PNETLab is usable when:**
- [ ] **Nested virt present in the guest:** `egrep -c '(vmx|svm)' /proc/cpuinfo` > 0 (and `kvm-ok` OK).
- [ ] `/opt/unetlab` is mounted from the **300 GB** disk (`df -h /opt/unetlab`), OS disk lean.
- [ ] Web UI loads at `http://172.16.10.60/` and login works (password changed).
- [ ] A 2-node test lab **starts and the nodes boot** (proves nested KVM end-to-end).
- [ ] `20 GB` RAM + `4 vCPU` present (`free -g`, `nproc`), balloon off.

**🧪 End-to-end test:**
```bash
egrep -c '(vmx|svm)' /proc/cpuinfo          # >0  (nested virt exposed)
kvm-ok 2>/dev/null || sudo apt install -y cpu-checker && kvm-ok
df -h /opt/unetlab                          # mounted from the 300G disk
free -g; nproc                              # ~20G, 4
ip -br a | grep 172.16.10.60                # pnet0 mgmt IP
# UI: create a 2-node lab -> Start -> both nodes reach console
```

**⚠️ Watch out for:**
- **No nested virt** — the #1 failure: nodes won't start. Needs `kvm-intel nested=1` on dc02 (Part A) **and** `--cpu host`.
- **`host` CPU blocks migration** — PNETLab is node-locked to dc02; don't expect to live-migrate it.
- **Thin pool fills** — 300 GB thin + big images can exceed dc02's free pool; watch `lvs pve/data`.
- **Data on OS disk** — do the Part E move **before** loading images, or the OS disk fills.
- **Permissions after moving/adding images** — always run `unl_wrapper -a fixpermissions`.
- **DNS zone** — mgmt NIC → `mgt.devnetlabs.com` (not dc02).

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| Lab nodes won't start / "cannot allocate" | nested virt off | `egrep -c '(vmx\|svm)' /proc/cpuinfo`; enable `kvm-intel nested=1` on dc02 + `--cpu host` |
| ISO won't boot / installer hangs | SeaBIOS vs OVMF mismatch | retry with `--bios ovmf` + `--efidisk0` (or vice-versa) |
| Web UI unreachable | wrong IP on `pnet0` / ufw / service down | `ip -br a`; `systemctl status pnetlab`/`apache2`/`nginx`; check the mgmt NIC bridge |
| `/opt/unetlab` still on OS disk | data move skipped or fstab wrong | `df -h /opt/unetlab`; redo Part E; `findmnt /opt/unetlab` |
| Images present but nodes fail | wrong permissions/paths | `sudo /opt/unetlab/wrappers/unl_wrapper -a fixpermissions`; confirm image dir under `/opt/unetlab/addons/` |
| Disk full mid-lab | thin pool over-committed on dc02 | `lvs pve/data`; free space or move `scsi1` to larger storage |
| Can't reach real network from a lab | no uplink NIC / cloud bridge | add `--net1 …tag=1201`, map it to a `pnetX` cloud in the lab |

---

See also: [lld.md](lld.md) · [vmid-plan.md](conventions/vmid-plan.md) ·
[naming-convention.md](conventions/naming-convention.md) · [network/network-vlan-design.md](network/network-vlan-design.md)
