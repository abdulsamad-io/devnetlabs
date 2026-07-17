# Bastion / Jump Host Setup Runbook — `dnladm101`

Practical, repeatable steps to build and harden the DevNetLabs jump host.
For the *why* behind each choice, this runbook is deliberately terse — see the inline
notes.

## Host facts

| Item | Value |
|------|-------|
| Hostname | `dnladm101` |
| Role | Admin / bastion (jump) host (`adm`) |
| VMID | 1002 (VM, dc01) |
| OS | Ubuntu 26.04 |
| IP | `172.16.10.2` (static, VLAN 1000 / shared_mgt) |
| Login user | `abdoolsamad` |
| Management networks | `172.16.10.0/24` (VLAN 1000) **and** `172.16.254.0/24` (lab_lan) |
| Auth model | **SSH keys only** (MFA planned later) |
| CPU type | `x86-64-v2-AES` (portable across dc01/dc02, not `host`) |

**Concept in one line:** the bastion is the single guarded door to the lab. Because the
MikroTik routes freely between VLANs, this one host on VLAN 1000 can reach every device.
Admin access to the bastion is expected from either management network — the wired mgmt
VLAN (`172.16.10.0/24`) or the flat `lab_lan` WiFi/wired segment (`172.16.254.0/24`).
It becomes a real security *control* only once devices are restricted to accept SSH
**only from `172.16.10.2`** (see "Make it a real bastion" below).

---

## Part A — Generate your SSH key (Windows client)

> Windows 10/11 ship OpenSSH built in — no Mac/Linux needed. Run everything in
> **PowerShell**. Keys live in `C:\Users\<you>\.ssh\`.

**1. Confirm OpenSSH is present:**
```powershell
ssh -V        # e.g. OpenSSH_for_Windows_9.x
```

**2. Generate a dedicated lab key** (one line — PowerShell dislikes `\` continuations,
and a full `-f` path avoids `~` quirks). The custom filename avoids clobbering any
existing work key (`id_ed25519`):
```powershell
ssh-keygen -t ed25519 -a 100 -f "$env:USERPROFILE\.ssh\id_ed25519_devnetlabs" -C "Abdulsamad Kazeem <abdulsamadayobami@gmail.com>"
```
| Flag | Meaning |
|------|---------|
| `-t ed25519` | Modern, strong, small key type |
| `-a 100` | 100 KDF rounds — slows brute-forcing of the private-key file if the laptop is stolen |
| `-f ...id_ed25519_devnetlabs` | Dedicated key file (won't overwrite the work key) |
| `-C "Name <email>"` | Cosmetic label baked into the public key; no security effect |

Set a **passphrase** when prompted (encrypts the private key at rest).

Files produced:
- `id_ed25519_devnetlabs` — **private key**, never leaves this PC.
- `id_ed25519_devnetlabs.pub` — **public key**, safe to copy to servers.

**3. View the public key** (you'll paste this onto the bastion):
```powershell
Get-Content "$env:USERPROFILE\.ssh\id_ed25519_devnetlabs.pub"
```

---

## Part B — Install the public key on the bastion (Windows)

> **Windows has no `ssh-copy-id`.** Use one of these instead (both rely on password
> login still working for this first connection).

**Option A — PowerShell one-liner:**
```powershell
$pub = Get-Content "$env:USERPROFILE\.ssh\id_ed25519_devnetlabs.pub"
ssh abdoolsamad@172.16.10.2 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

**Option B — manual (foolproof):** copy the `Get-Content` output, then on the bastion
(Proxmox console or SSH):
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys      # paste the key line, save
chmod 600 ~/.ssh/authorized_keys
```
> The `700`/`600` permissions matter: SSH refuses key files other users can read.

> **Check:** `ssh abdoolsamad@172.16.10.2 'grep -c devnetlabs ~/.ssh/authorized_keys'` → `1`
> (the key is installed). A key-only `ssh jump` login is proven in Part D.

---

## Part C — SSH client config (Windows)

Edit `C:\Users\<you>\.ssh\config` (plain text, no extension):
```powershell
notepad "$env:USERPROFILE\.ssh\config"
```
Add:
```
Host jump
    HostName 172.16.10.2
    User abdoolsamad
    IdentityFile ~/.ssh/id_ed25519_devnetlabs
    IdentitiesOnly yes
```
- `IdentityFile` — use *this* key for this host (`~` is fine inside the config file).
- `IdentitiesOnly yes` — offer *only* this key, so SSH doesn't try the work key first
  and burn `MaxAuthTries`.

Test: `ssh jump`

> **MobaXterm:** point the session's *Advanced SSH settings → Use private key* at
> `C:\Users\<you>\.ssh\id_ed25519_devnetlabs`, and set the jump under
> *Network settings → SSH gateway*. Stick with the native Windows `.ssh` location to
> avoid "where's my key" confusion with MobaXterm's private home.

---

## Part C (Linux / macOS) — key setup from a Linux client

Equivalent of Parts A–C when your client is Linux/macOS. Keys live in `~/.ssh/`, and
unlike Windows the standard tools (`ssh-keygen`, `ssh-copy-id`) are all present.

**1. Generate the key** (bash accepts `\` line continuations and `~`):
```bash
ssh-keygen -t ed25519 -a 100 \
  -f ~/.ssh/id_ed25519_devnetlabs \
  -C "Abdulsamad Kazeem <abdulsamadayobami@gmail.com>"
```
Same flags as Part A. Set a passphrase when prompted. View the public key with:
```bash
cat ~/.ssh/id_ed25519_devnetlabs.pub
```

**2. Install the public key** — Linux *has* `ssh-copy-id`, so this is one command
(needs password login still working for the first connection):
```bash
ssh-copy-id -i ~/.ssh/id_ed25519_devnetlabs.pub abdoolsamad@172.16.10.2
```

**3. Client config** — the config block is **identical to Part C**; only the file path
differs (`~/.ssh/config`, i.e. `/home/<you>/.ssh/config`):
```
Host jump
    HostName 172.16.10.2
    User abdoolsamad
    IdentityFile ~/.ssh/id_ed25519_devnetlabs
    IdentitiesOnly yes
```
Ensure private-key permissions are tight (ssh-keygen sets these, but to be sure):
```bash
chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_ed25519_devnetlabs
```
Test: `ssh jump`

---

## Part D — Server-side hardening (on `dnladm101`)

> **Golden rule:** keep your working session (or the Proxmox console) open until a
> *new* login is proven to work. A bad SSH config can lock you out.

**1. User + allow-list group:**
```bash
sudo adduser abdoolsamad
sudo usermod -aG sudo abdoolsamad
sudo groupadd sshusers
sudo usermod -aG sshusers abdoolsamad
```

**2. Harden `sshd` via a drop-in** (filename `10-` sorts *before* the cloud image's
`50-cloud-init.conf`; SSH uses the **first** value it reads for each setting, so ours
wins):
```bash
sudo nano /etc/ssh/sshd_config.d/10-hardening.conf
```
```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowGroups sshusers
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
```
> Keep `AllowTcpForwarding yes` — ProxyJump needs it. Only *agent* forwarding is off.

**3. Validate, then apply** (validation is the safety net):
```bash
sudo sshd -t                 # silence = OK
sudo systemctl reload ssh
```
Then prove a fresh `ssh jump` login works **before** closing your original session.

**4. Host firewall (default deny)** — allow SSH from **both** management networks:
```bash
sudo apt update && sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 172.16.10.0/24 to any port 22 proto tcp     # VLAN 1000
sudo ufw allow from 172.16.254.0/24 to any port 22 proto tcp    # lab_lan
sudo ufw enable
```

**5. Patching, time, brute-force backstop:**
```bash
sudo apt install -y unattended-upgrades chrony fail2ban
sudo dpkg-reconfigure -plow unattended-upgrades
```
- `chrony` — accurate clock (logs today; MFA/certs later).
- `fail2ban` — auto-bans repeat SSH offenders.

**6. Log forwarding** (once `dnllog101` exists) — point rsyslog at the log server.

---

## Part E — Using the jump host

From the client, with the `~/.ssh/config` above:
```
Host dc01 dc02 dc03 mikrotik
    ProxyJump jump
    User abdoolsamad
```
Then `ssh dc01` hops **through** `dnladm101` automatically. Your private key stays on
the client — the bastion only forwards a pipe, it never sees your key.

---

## Part F — Make it a real bastion (separate, later task)

Everything above secures the *door*. To make it the *only* door, restrict devices to
accept SSH **only from `172.16.10.2`**:
- **MikroTik:** address-list with the bastion IP + firewall rules allowing mgmt ports
  (22 / Winbox / `:8006` / `:8007`) into device subnets **only from that address**.
- **Per device:** `AllowUsers abdoolsamad@172.16.10.2` as defense-in-depth.

Do this on its own change and verify reachability *before and after* — it touches the
currently open forward chain (see [OPEN-ITEMS.md](OPEN-ITEMS.md)).

---

## Verification & success criteria

**✅ Success criteria — the bastion is ready when:**
- [ ] `ssh jump` logs in **with the key only** (no password prompt).
- [ ] Password auth and root login are both **refused**.
- [ ] SSH is reachable from both mgmt networks (`172.16.10.0/24`, `172.16.254.0/24`) and nowhere else.
- [ ] `ssh dc01` (ProxyJump) hops **through** the bastion without exposing your private key.

**🧪 End-to-end tests:**
```bash
ssh -v jump true 2>&1 | grep -i authenticated        # "Authenticated ... using publickey"
ssh -o PreferredAuthentications=password jump        # MUST fail: "Permission denied (publickey)"
sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|allowgroups'   # no / no / sshusers
sudo ufw status verbose                              # default deny in; 22 from the two /24s only
ssh dc01 hostname                                    # ProxyJump works -> prints dc01's hostname
```

**⚠️ Watch out for:**
- **Locking yourself out** — keep the Proxmox console (or current session) open until a *fresh* `ssh jump` succeeds; a bad `sshd_config` only bites the *next* login.
- **Drop-in ordering** — `10-hardening.conf` must sort before `50-cloud-init.conf`; sshd uses the **first** value per setting. Confirm with `sudo sshd -T`, not by reading the file.
- **`AllowGroups sshusers`** — your user must be in `sshusers` or *every* login is denied (`id abdoolsamad`).
- **Key perms** — `~/.ssh` `700`, `authorized_keys` `600`; SSH silently ignores group/other-readable key files.
- **`IdentitiesOnly yes`** — without it the client may offer other keys first and burn `MaxAuthTries` before the lab key.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| `ssh jump` → `Permission denied (publickey)` | key not installed / wrong perms / user not in `sshusers` / wrong key offered | `ssh -v jump` (which key?); `~/.ssh` 700 + `authorized_keys` 600; `id abdoolsamad` in `sshusers`; add `IdentitiesOnly yes` |
| Locked out after an sshd change | bad `10-hardening.conf` | connect via the **Proxmox console**; `sudo sshd -t`; fix the drop-in; `sudo systemctl reload ssh` |
| Password prompt still appears | `PasswordAuthentication no` not in effect | `sudo sshd -T \| grep -i passwordauth`; ensure `10-` sorts before `50-cloud-init.conf` |
| Valid user's login refused | user not in `AllowGroups sshusers` | `sudo usermod -aG sshusers <user>`; re-login |
| Can't reach bastion from lab_lan | ufw missing the `172.16.254.0/24` rule | `sudo ufw allow from 172.16.254.0/24 to any port 22 proto tcp` |
| `ssh dc01` (ProxyJump) fails | `AllowTcpForwarding no`, or `jump` itself unreachable | confirm `AllowTcpForwarding yes`; verify plain `ssh jump` works first |
| `fail2ban` banned you | repeated failed auth | from another allowed IP: `sudo fail2ban-client set sshd unbanip <ip>` |

---

See also: [naming-convention.md](naming-convention.md) · [vmid-plan.md](vmid-plan.md) ·
[network-vlan-design.md](network-vlan-design.md)
