# PNETLab Setup Runbook — `dnlpnt101` (dc01) + `dnlpnt201` (dc02)

Build **PNETLab** network-emulation. Two instances by design:

| | **`dnlpnt101`** (this build) | **`dnlpnt201`** |
|---|---|---|
| Node | **dc01** (GEEKOM i9, **always-on**) | dc02 (HPE ML150, **on-demand**) |
| Use | **small / medium** labs | **medium / large** labs |
| VMID | **1109** | 2101 |
| VLAN / IP (mgmt NIC) | **dc01_apps (1101)** — `10.110.10.60/24`, gw `10.110.10.1` | dc02_apps (1201) — `10.120.10.60/24`, gw `10.120.10.1` |
| OOB NIC (lab mgmt plane) | **dc01_lab_oob (4001)** — 10.251.0.0/16 | dc02_lab_oob (4002) — 10.252.0.0/16 |
| FQDN | `dnlpnt101.dc01.devnetlabs.com` | `dnlpnt201.dc02.devnetlabs.com` |
| vCPU / RAM | **4 / 20 GB** | scale up (e.g. 6–8 / 32–48 GB) |
| Data disk | **300 GB** → `/opt/unetlab` | larger (e.g. 500 GB+) |

Both need **nested virtualization**, live on their **node's apps VLAN** (not shared_mgt),
and keep the image/lab store on a **separate data volume**. This runbook walks **`dnlpnt101`
on dc01**; the dc02 variant differs only by the values above (deltas called out inline).
Context: [lld.md](lld.md) · [vmid-plan.md](conventions/vmid-plan.md). Placement per **#19**.

## Facts (`dnlpnt101`)

| Item | Value |
|------|-------|
| Hostname | `dnlpnt101` · Role `pnt` · VMID **1109** (dc01) |
| OS | PNETLab (Ubuntu-based) — latest ISO from <https://pnetlab.com> (OVA import is an alternative) |
| VLAN / IP (mgmt) | **dc01_apps (1101)** — **`10.110.10.60/24`**, gw `10.110.10.1` |
| OOB NIC | **dc01_lab_oob (4001)** — L2 uplink for the lab-device mgmt plane (no host IP) |
| FQDN | `dnlpnt101.dc01.devnetlabs.com` (apps VLAN → **dc01** zone) |
| CPU | **`host`** — required for nested KVM (⚠️ not `x86-64-v2-AES`) |
| vCPU / RAM | **4 vCPU** / **20 GB** (`--balloon 0`) |
| Disks | **40 GB OS** + **300 GB data** → `/opt/unetlab` (images + labs) |
| Machine / BIOS | q35 / **SeaBIOS** (appliance-friendly; OVMF fallback noted) |
| Web UI | HTTP **`:80`**, default **`admin` / `pnet`** (change on first login) |

> **CPU caveat:** `host` exposes VMX for nested KVM but **breaks live-migration** to a
> dissimilar node — each PNETLab is node-locked. Fine here (dc01 = i9-13900HK with VT-x).

---

## Part A — Enable nested virtualization on the target node

On the **dc01** Proxmox node (repeat on dc02 for `dnlpnt201`):
```bash
cat /sys/module/kvm_intel/parameters/nested       # want: Y
# if N:
echo "options kvm-intel nested=1" | sudo tee /etc/modprobe.d/kvm-intel.conf
sudo modprobe -r kvm_intel 2>/dev/null; sudo modprobe kvm_intel   # or reboot the node
```
> Without host-level nested virt, the VM's `host` CPU won't expose `vmx` and PNETLab's lab
> nodes fail to start.

## Part B — Create the VM (on dc01)

```bash
qm create 1109 --name dnlpnt101 --machine q35 --bios seabios \
  --cpu host --cores 4 --sockets 1 --memory 20480 --balloon 0 \
  --scsihw virtio-scsi-single --ostype l26 --onboot 1 \
  --net0 virtio,bridge=vmbr0,tag=1101
qm set 1109 --net1 virtio,bridge=vmbr0,tag=4001         # OOB NIC -> lab-device mgmt plane (VLAN 4001)
qm set 1109 --scsi0 local-lvm:40,discard=on,ssd=1      # OS disk
qm set 1109 --scsi1 local-lvm:300,discard=on,ssd=1     # -> /opt/unetlab (images + labs)
qm set 1109 --ide2 local:iso/PNETLab_<ver>.iso,media=cdrom   # <-- the ISO you downloaded
qm set 1109 --boot order='ide2;scsi0'
qm start 1109
```
- `--cpu host` + `--balloon 0` (nested guests need real, pinned RAM).
- **`net0`** = host mgmt/UI on dc01_apps; **`net1`** = the **OOB uplink** on `dc01_lab_oob`
  (VLAN 4001). `net1` carries no host IP — it's an L2 trunk into a PNETLab **cloud** (Part F).
- **dc02 variant (`dnlpnt201`):** VMID `2101`, `--name dnlpnt201`, `net0 tag=1201`,
  **`net1 tag=4002`**, larger RAM/disk.
> ⚠️ **Thin-pool headroom:** a 300 GB thin disk over-commits — check the node first with
> `lvs -o name,lv_size,data_percent pve/data`; images can fill it. Use a larger/dedicated
> storage for `scsi1` if space is tight (esp. dc02's larger disk).
> **OVMF note:** if the ISO won't boot under SeaBIOS, retry q35+OVMF (`--bios ovmf` + `--efidisk0`).

## Part C — Install PNETLab (from the ISO)

Console → run the installer, target the **40 GB `scsi0`** disk (leave `scsi1` untouched), set
the root password, finish. Then eject the ISO:
```bash
qm set 1109 --ide2 none,media=cdrom && qm set 1109 --boot order='scsi0' && qm reboot 1109
```
> The installer puts PNETLab's tree at `/opt/unetlab` on `scsi0`. Relocate it to the 300 GB
> disk in Part E **before** loading images.

## Part D — Network (dc01_apps)

PNETLab's mgmt interface is **`pnet0`**. Static IP on dc01_apps:
```
# /etc/netplan/01-net.yaml (pnet0 = mgmt over ens18; ens19 = OOB, no host IP)
network:
  version: 2
  ethernets:
    ens18: {}
    ens19: {}                              # OOB NIC (VLAN 4001) — left unconfigured; PNETLab bridges it as pnet1
  bridges:
    pnet0:
      interfaces: [ens18]
      addresses: [10.110.10.60/24]
      routes: [{ to: default, via: 10.110.10.1 }]
      nameservers: { addresses: [172.16.10.53, 172.16.10.54], search: [dc01.devnetlabs.com] }
```
```bash
sudo netplan apply
sudo hostnamectl set-hostname dnlpnt101
sudo timedatectl set-timezone Europe/Amsterdam
```
> `pnet0` = **host management** (dc01_apps); `pnet1+` are the lab "cloud" bridges. Give the
> **OOB NIC (`ens19`, VLAN 4001) no host IP** — it's an L2 uplink; PNETLab maps it to a
> **cloud** (`pnet1`, Part F) so emulated devices' mgmt ports land on the OOB segment and
> DHCP from Technitium (relayed). **Confirm the NIC order** (`ip -br l`) so `ens18`=net0(apps)
> and `ens19`=net1(OOB) — swap if the kernel enumerated them the other way.
> **Check:** `ip -br a` shows `10.110.10.60` on `pnet0`, and **no IP** on `ens19`.
> (dc02 variant: mgmt `10.120.10.60` / `search: [dc02.devnetlabs.com]`, OOB NIC on VLAN 4002.)

## Part E — Move the data store to the 300 GB volume

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS         # identify the empty 300G disk (e.g. sdb)
DATADISK=/dev/sdb                                  # the 300G disk you confirmed
sudo mkfs.ext4 -L pnet_data "$DATADISK"
sudo systemctl stop pnetlab 2>/dev/null; sudo pkill -f unl_wrapper 2>/dev/null || true
sudo mv /opt/unetlab /opt/unetlab.old
sudo mkdir -p /opt/unetlab
echo 'LABEL=pnet_data /opt/unetlab ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mount -a
sudo rsync -aHAX /opt/unetlab.old/ /opt/unetlab/
sudo /opt/unetlab/wrappers/unl_wrapper -a fixpermissions
sudo rm -rf /opt/unetlab.old
sudo reboot
```
> Only `mkfs` the **empty 300 GB** disk (no partitions/mountpoint) — never the OS disk.

## Part F — First login + images

1. Browse `http://10.110.10.60/` (or `http://dnlpnt101.dc01.devnetlabs.com/` once DNS is in).
   Log in **`admin` / `pnet`** → change the password.
2. Add device images under **`/opt/unetlab/addons/`** (now on the 300 GB volume), then
   `sudo /opt/unetlab/wrappers/unl_wrapper -a fixpermissions`.
3. Build a 2-node test lab and start it to confirm nested virt works.

## Part G — DNS record

Add `dnlpnt101 → 10.110.10.60` (the **mgmt** NIC) in the **`dc01.devnetlabs.com`** zone
(dc02 variant: `dnlpnt201 → 10.120.10.60` in `dc02.devnetlabs.com`). The OOB NIC gets no
DNS — lab devices on it are ephemeral and DHCP from Technitium without auto-registration.

## Part H — Lab OOB management plane (syslog + SNMP source)

The OOB NIC (`net1`, VLAN 4001) is how emulated devices are managed, logged, and polled —
**out of band** from the lab data paths.

1. **Expose the OOB NIC as a cloud in PNETLab.** In the lab, add a **Network** of type
   **"Cloud"/bridge** mapped to the interface backing `net1` (PNETLab labels the extra NICs
   `pnet1..9`; `net1` → **`pnet1`**). Attach each device's **management port** to that cloud.
2. **Address + DHCP.** The device's mgmt port now sits on VLAN 4001 → it gets a
   `10.251.0.0/16` lease from Technitium (relayed by the MikroTik — see
   [network-vlan-design.md](network/network-vlan-design.md#lab-oob-management-networks-4001--4002)).
   Static addressing is fine too (outside the DHCP range).
3. **Point telemetry at the OOB source.** On each device, **source syslog and SNMP from the
   OOB (mgmt) interface** so the collectors/poller see a `10.251`/`10.252` address:
   - **syslog** → VIP `172.16.10.70:514`, sourced from the OOB IP.
   - **SNMP** → allow pollers `10.110.10.72` + `10.120.10.72`, agent on the OOB IP.
   Per-vendor CLI: [log-source-onboarding.md](logging/log-source-onboarding.md) ·
   [snmp-source-onboarding.md](monitoring/snmp-source-onboarding.md).

> **Why this matters for observability:** lab telemetry rides the **existing** stack — no
> redesign. Because the OOB ranges are known (`10.251`/`10.252`), rsyslog classifies them
> into a **segregated `lab/` tree** (Loki `category="lab"`, shorter retention; a Graylog lab
> stream) and Prometheus tags them **`env=lab`** — keeping churny lab logs/metrics out of
> production dashboards and retention. The isolation firewall permits exactly these flows.

---

## Verification & success criteria

**✅ Success criteria — PNETLab is usable when:**
- [ ] **Nested virt in the guest:** `egrep -c '(vmx|svm)' /proc/cpuinfo` > 0 (and `kvm-ok` OK).
- [ ] `/opt/unetlab` is mounted from the **300 GB** disk (`df -h /opt/unetlab`); OS disk lean.
- [ ] Web UI loads at `http://10.110.10.60/`; login works (password changed).
- [ ] A 2-node test lab **starts and the nodes boot** (nested KVM end-to-end).
- [ ] `20 GB` RAM + `4 vCPU` present (`free -g`, `nproc`), balloon off.
- [ ] **OOB works:** a lab device on the `pnet1` cloud gets a `10.251` lease, its syslog
      reaches the VIP (lands in `lab/`), and `dnlprm101` can `snmpwalk` its OOB IP — but it
      **cannot** reach an infra host (isolation holds).

**🧪 End-to-end test:**
```bash
egrep -c '(vmx|svm)' /proc/cpuinfo          # >0
kvm-ok 2>/dev/null || (sudo apt install -y cpu-checker && kvm-ok)
df -h /opt/unetlab                          # mounted from the 300G disk
free -g; nproc                              # ~20G, 4
ip -br a | grep 10.110.10.60                # pnet0 mgmt IP
```

**⚠️ Watch out for:**
- **No nested virt** — the #1 failure: lab nodes won't start. Needs `kvm-intel nested=1` on the node **and** `--cpu host`.
- **`host` CPU blocks migration** — each PNETLab is node-locked (dc01 / dc02 respectively).
- **Thin pool fills** — big images vs the node's free pool; watch `lvs pve/data`.
- **Data on OS disk** — do the Part E move **before** loading images.
- **Permissions after moving/adding images** — always `unl_wrapper -a fixpermissions`.
- **DNS zone** — apps-VLAN host → `dcNN.devnetlabs.com` (dc01 here), not `mgt`.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| Lab nodes won't start / "cannot allocate" | nested virt off | `egrep -c '(vmx\|svm)' /proc/cpuinfo`; enable `kvm-intel nested=1` on the node + `--cpu host` |
| ISO won't boot / installer hangs | SeaBIOS vs OVMF mismatch | retry with `--bios ovmf` + `--efidisk0` (or vice-versa) |
| Web UI unreachable | wrong IP on `pnet0` / ufw / service down | `ip -br a`; `systemctl status pnetlab`/`apache2`; check the `pnet0` bridge |
| `/opt/unetlab` still on OS disk | data move skipped / fstab wrong | `df -h /opt/unetlab`; redo Part E; `findmnt /opt/unetlab` |
| Images present but nodes fail | wrong permissions/paths | `unl_wrapper -a fixpermissions`; images under `/opt/unetlab/addons/` |
| Disk full mid-lab | thin pool over-committed | `lvs pve/data`; free space or move `scsi1` to larger storage |
| Can't reach real network from a lab | no uplink NIC / cloud bridge | add `--net1 …`, map it to a `pnetX` cloud in the lab |

---

See also: [lld.md](lld.md) · [vmid-plan.md](conventions/vmid-plan.md) ·
[naming-convention.md](conventions/naming-convention.md) · [network/network-vlan-design.md](network/network-vlan-design.md)
