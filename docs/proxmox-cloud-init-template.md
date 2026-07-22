# Proxmox Cloud-init Template — `tmpl-ubuntu2604`

Build the cloud-init-ready Ubuntu template that [`terraform/dc01_infra`](../terraform/dc01_infra/README.md)
full-clones. Built from Ubuntu's **cloud image** (already cloud-init enabled), not an ISO
install. Do this on the **node you'll clone on** (standalone nodes don't share templates —
build it on dc01 for `dc01_infra`; repeat per node).

## Facts

| Item | Value |
|------|-------|
| VMID / name | **1902** · `tmpl-ubuntu2604` |
| OS | **Ubuntu 26.04 LTS ("Resolute Raccoon")** — cloud image, codename `resolute` |
| Machine / BIOS | q35 / **OVMF** (matches the fleet; clones inherit firmware from the template) |
| CPU | `x86-64-v2-AES` (portable) |
| Extras | `qemu-guest-agent` baked in; cloud-init drive; serial console |

> Clones inherit the template's **firmware/machine** (the Terraform module doesn't set
> them), so set them here to what you want fleet-wide.

## Build (on the dc01 Proxmox node, as root)

```bash
# 1. Ubuntu 26.04 (resolute) cloud image
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img
```
> **Check:** the file downloads and `qemu-img info resolute-server-cloudimg-amd64.img` shows a qcow2.

```bash
# 2. Bake in the guest agent (so PVE/Terraform can read each clone's IP)
apt-get install -y libguestfs-tools
virt-customize -a resolute-server-cloudimg-amd64.img \
  --install qemu-guest-agent --run-command 'systemctl enable qemu-guest-agent'
```
> **Check:** `virt-customize` finishes `[ ... ] finished`. Skip only if you'll install the
> agent via cloud-init instead.

```bash
# 3. VM shell — q35 + OVMF + agent
qm create 1902 --name tmpl-ubuntu2604 --machine q35 --bios ovmf \
  --cpu x86-64-v2-AES --cores 2 --memory 2048 \
  --scsihw virtio-scsi-single --ostype l26 \
  --net0 virtio,bridge=vmbr0 --agent enabled=1
qm set 1902 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0

# 4. Import the cloud image as the OS disk, attach on scsi0
qm importdisk 1902 resolute-server-cloudimg-amd64.img local-lvm
qm set 1902 --scsi0 local-lvm:vm-1902-disk-1,discard=on,ssd=1   # confirm the volume name from importdisk output

# 5. Cloud-init drive + serial console (cloud images need it) + boot disk
qm set 1902 --ide2 local-lvm:cloudinit
qm set 1902 --serial0 socket --vga serial0
qm set 1902 --boot order=scsi0

# 6. Grow the (tiny) cloud image, then seal as a template
qm disk resize 1902 scsi0 20G
qm template 1902
```
> **Check:** `qm config 1902` shows `template: 1` , `scsi0` (the cloud image), `ide2: …cloudinit`,
> `serial0: socket`, `agent: enabled=1`. **Do NOT** set `ciuser`/`cipassword`/`sshkeys`/`ipconfig0`
> here — Terraform's `initialization` block supplies identity per clone.

## Verification & success criteria

**✅ Success — the template is usable when:**
- [ ] `qm config 1902` shows `template: 1`, a cloud-init drive (`ide2: local-lvm:cloudinit`), serial console, and `agent: enabled=1`.
- [ ] **No** baked-in identity (`ciuser`/`sshkeys`/`ipconfig0` absent).
- [ ] A throwaway clone boots, applies cloud-init (user/IP/keys), and reports its IP via the agent.

**🧪 Test (clone → boot → check → destroy):**
```bash
qm clone 1902 999 --name ci-test
qm set 999 --ipconfig0 ip=dhcp --ciuser test --sshkeys ~/.ssh/authorized_keys
qm start 999
qm guest cmd 999 network-get-interfaces   # agent answers with an IP  -> cloud-init + agent OK
qm stop 999 && qm destroy 999
```
Then `cd terraform/dc01_infra && terraform plan` will clone `1902` for real.

**⚠️ Watch out for:**
- **Baked identity** — the #1 mistake: setting cloud-init user/IP on the *template* makes every clone identical. Leave them blank.
- **No guest agent** — `agent { enabled = true }` (module) then waits forever for an IP; bake it in (step 2).
- **No serial console** — Ubuntu cloud images can appear to hang at boot without `serial0`.
- **Wrong disk name** — `importdisk` may create `vm-1902-disk-1` (disk-0 is the efidisk); confirm from its output before `--scsi0`.
- **Per-node** — the template only exists on the node you built it on; rebuild on dc02/dc03 for their infra folders.
- **Firmware mismatch** — clones inherit q35/OVMF from here; keep it consistent with your other VMs.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| Clone boots but no IP / Terraform hangs | guest agent missing | bake `qemu-guest-agent` (step 2) or install via cloud-init; `qm guest cmd <id> network-get-interfaces` |
| Clone hangs at boot (blank console) | no serial console | `qm set <tmpl> --serial0 socket --vga serial0`; re-clone |
| Every clone has the same user/IP | identity baked into the template | clear `ciuser`/`cipassword`/`sshkeys`/`ipconfig0` on 1902; re-clone |
| `qm set --scsi0 …disk-1` → volume not found | wrong imported-disk name | read `importdisk` output / `qm config 1902` `unused0:`; attach that exact volid |
| Clone won't boot (OVMF) | efidisk/boot order | ensure `efidisk0` exists + `boot order=scsi0`; or rebuild with `--bios seabios` (simpler) |
| Terraform clone fails cross-node | template only on one node | build the template on the target node (standalone; no shared template store) |

*(ISO alternative: install Ubuntu 26.04 from ISO, `apt install cloud-init qemu-guest-agent`,
`cloud-init clean --logs`, shut down, `qm template`. More manual than the cloud image.)*

---

See also: [terraform/dc01_infra](../terraform/dc01_infra/README.md) ·
[vmid-plan.md](conventions/vmid-plan.md) · [ansible/linux-baseline](../ansible/linux-baseline/README.md)
(runs after, for in-guest config)
