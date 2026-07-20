# Linux Machine Baseline — DevNetLabs

The standard configuration every Ubuntu guest gets, applied **right after install and
before** the service-specific runbook steps. It consolidates the "Base config + firewall"
block that's otherwise copy-pasted across every VM runbook
([bastion-setup](../bastion-setup.md), [loki-setup](../logging/loki-setup.md),
[prometheus-setup](../monitoring/prometheus-setup.md), [netbox-setup](../netbox-setup.md)…)
so there's **one source of truth** and no drift.

- **Level 1 — Operational baseline:** mandatory on **every** host.
- **Level 2 — Security hardening:** opt-in, applied per-host (edge/security-sensitive
  boxes first). Clearly separated so you adopt it deliberately.

> **Reference implementation:** the bastion `dnladm101` already runs the full Level 1 +
> parts of Level 2 — see [bastion-setup.md](../bastion-setup.md) Part D. This doc
> generalises it to the whole fleet. It's also the spec for a future Ansible `base` role
> ([#25](../OPEN-ITEMS.md)).

## Applicability

| | |
|---|---|
| OS | Ubuntu Server **26.04 LTS** (the fleet standard) |
| Login user | your admin user (e.g. `abdoolsamad`) in `sudo` + `sshusers` |
| Auth | **SSH keys only** (no passwords) |
| Time zone | **`Europe/Amsterdam`** (IANA — never `CEST`/`CET`, which break tools like NetBox) |
| DNS | Technitium `172.16.10.53` / `172.16.10.54`; search domain = the host's zone |

---

# Level 1 — Operational baseline (every host)

Order matters: identity → time → network/DNS → SSH → firewall → updates → users →
packages. Run each block, confirm its **Check**, then move on.

## 1. Identity — hostname

```bash
sudo hostnamectl set-hostname dnl<role><dc><nn>     # e.g. dnlprm101 (see naming-convention.md)
```
> **Check:** `hostnamectl` shows the new static hostname; it matches the VMID/DNS record.

## 2. Time sync — chrony (NTP)

```bash
sudo apt update && sudo apt install -y chrony
sudo timedatectl set-timezone Europe/Amsterdam
sudo systemctl enable --now chrony
```
Point chrony at the standard lab NTP sources (a drop-in `/etc/chrony/conf.d/devnetlabs.conf`):
```
pool 0.nl.pool.ntp.org iburst
server ntspool.time.nl iburst
server time1.google.com iburst
server time2.google.com iburst
```
> **Why it's Level 1, not cosmetic:** Prometheus **rejects samples with skewed timestamps**,
> and rsyslog files bucket by date — a wrong clock scatters logs into the wrong day's file.
> **Check:** `timedatectl` → correct TZ, "System clock synchronized: yes";
> `chronyc tracking` shows a synced source with small offset.

## 3. Network + DNS (netplan + systemd-resolved)

Static addressing, Technitium resolvers, and the **correct search domain for the host's
VLAN** — mgmt-VLAN (1000) hosts use `mgt.devnetlabs.com`; per-node-VLAN hosts use
`dcNN.devnetlabs.com`. `/etc/netplan/01-net.yaml`:
```yaml
network:
  version: 2
  ethernets:
    ens18:                                   # confirm the NIC name: ip -br a
      addresses: [10.110.10.72/24]           # this host's static IP
      routes: [{ to: default, via: 10.110.10.1 }]
      nameservers:
        addresses: [172.16.10.53, 172.16.10.54]
        search: [dc01.devnetlabs.com]        # mgt.devnetlabs.com for VLAN-1000 hosts
```
```bash
sudo netplan apply
```
> **Check:** `ip -br a` shows the static IP; `resolvectl status` lists **only**
> `172.16.10.53/.54` (no stray `8.8.8.8`) with the right search domain;
> `getent hosts dnldns101.mgt.devnetlabs.com` resolves.
>
> ⚠️ **Two real gotchas from this lab:**
> - A **stray netplan file** (e.g. cloud-init's) with `8.8.8.8` *first* makes internal
>   zones **NXDOMAIN** — remove/settle the resolver order so only Technitium answers.
> - The zone is **`mgt`**, not `mgmt` — a search-domain typo breaks short-name lookups
>   (`ssh dnllog101`) on VLAN-1000 hosts.

## 4. SSH — key-only + hardened drop-in

Install your public key (`~/.ssh/authorized_keys`, `700`/`600`), then apply the hardening
drop-in. Filename `10-` sorts **before** `50-cloud-init.conf`, and sshd uses the *first*
value per setting, so ours wins. `/etc/ssh/sshd_config.d/10-hardening.conf`:
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
AllowTcpForwarding yes          # ProxyJump needs it; only agent-forwarding is off
```
```bash
sudo groupadd -f sshusers && sudo usermod -aG sshusers $USER
sudo sshd -t && sudo systemctl reload ssh      # validate BEFORE reload
```
> **Golden rule:** keep the Proxmox console (or current session) open until a **fresh**
> key-only login is proven — a bad `sshd_config` only bites the *next* login.
> **Check:** `sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|allowgroups'`
> → `no` / `no` / `sshusers`. Full client-key setup: [bastion-setup.md](../bastion-setup.md).

## 5. Host firewall — ufw (default deny)

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 172.16.10.0/24  to any port 22 proto tcp    # SSH — VLAN 1000 (mgmt/bastion)
sudo ufw allow from 172.16.254.0/24 to any port 22 proto tcp    # SSH — lab_lan
sudo ufw enable
```
> **Per-service ports (`:3100`, `:9090`, `:8000`…) are opened in each service's runbook**,
> not here — the baseline only guarantees SSH-from-mgmt + default-deny.
> **Check:** `sudo ufw status verbose` → default deny incoming; `22` from the two /24s only.

## 6. Automatic security updates — unattended-upgrades

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades      # enable
```
Confirm security updates are enabled in `/etc/apt/apt.conf.d/50unattended-upgrades`
(the `${distro_id}:${distro_codename}-security` origin is uncommented). Optional auto-reboot
for kernel updates (pick a quiet window):
```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
```
> **On-demand nodes (dc02):** they only patch while powered on — expect a catch-up run each
> boot. **Check:** `sudo unattended-upgrade --dry-run --debug` runs clean;
> `systemctl status unattended-upgrades` is active.

## 7. Users, sudo & access

- One **named admin** per person in `sudo` + `sshusers`; **no shared accounts**.
- **Root has no password login** (`PermitRootLogin no` from §4; root SSH is off).
- Service accounts (e.g. `prometheus`, `loki`) are **`--system --shell /usr/sbin/nologin`**
  — no interactive login (created by their runbooks).
```bash
id $USER                                   # in sudo + sshusers
sudo passwd -S root                        # root: locked (L) or no password login
```

## 8. Package hygiene

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt autoremove --purge -y
```
Keep the footprint minimal — install only what a role needs; don't add desktop/GUI packages
to a server. `needrestart` (default on Ubuntu Server) will flag services to restart after
library upgrades.

## 9. Syslog forwarding (→ central collectors)

Every host ships `*.*` to the rsyslog collectors so logs land in the central tree → Loki +
Graylog. Forward to the **primary** collector with **failover** to the second (so both
`dnllog101`/`dnllog201` are used, but never simultaneously — sending to both at once would
double-ingest). `/etc/rsyslog.d/90-devnetlabs-forward.conf`:
```
# primary
*.* action(type="omfwd" target="172.16.10.71" port="514" protocol="tcp"
    action.resumeRetryCount="-1" queue.type="linkedList" queue.filename="fwd_devnetlabs_1"
    queue.maxDiskSpace="256m" queue.saveOnShutdown="on")
# failover — only when the primary is suspended
*.* action(type="omfwd" target="172.16.10.72" port="514" protocol="tcp"
    action.execOnlyWhenPreviousIsSuspended="on"
    action.resumeRetryCount="-1" queue.type="linkedList" queue.filename="fwd_devnetlabs_2"
    queue.maxDiskSpace="256m" queue.saveOnShutdown="on")
```
```bash
sudo rsyslogd -N1 && sudo systemctl restart rsyslog     # validate, then apply
```
> **Alternative:** point at the keepalived **VIP `172.16.10.70`** instead of the pair (per
> [../logging/log-source-onboarding.md](../logging/log-source-onboarding.md)) — same
> no-duplicate guarantee, failover handled by keepalived rather than the client.
> **The collectors themselves don't run this** — they *receive* and fan out
> ([../logging/rsyslog-setup.md](../logging/rsyslog-setup.md)); forwarding their own logs
> back in would loop. **Check:** on the active collector, this host's messages appear under
> `/var/log/devnetlabs_logs/` (in `compute/linux`, or `others/` until its IP is classified).

---

# Level 2 — Security hardening (opt-in, per-host)

Apply to internet-adjacent/edge hosts (`dnlctl101`), the bastion, and anything holding
sensitive data first; roll out fleet-wide as you're comfortable. Each block is independent.

## A. SSH brute-force protection — fail2ban

```bash
sudo apt install -y fail2ban
sudo tee /etc/fail2ban/jail.d/sshd.local >/dev/null <<'EOF'
[sshd]
enabled  = true
maxretry = 4
findtime = 10m
bantime  = 1h
# don't lock yourself out from the mgmt networks:
ignoreip = 127.0.0.1/8 172.16.10.0/24 172.16.254.0/24
EOF
sudo systemctl enable --now fail2ban
```
> The bastion already runs this. **Check:** `sudo fail2ban-client status sshd`.
> Unban yourself: `sudo fail2ban-client set sshd unbanip <ip>`.

## B. Audit logging — auditd + a baseline ruleset

```bash
sudo apt install -y auditd audispd-plugins
sudo tee /etc/audit/rules.d/10-baseline.rules >/dev/null <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k sshd
-w /var/log/auth.log -p wa -k authlog
-a always,exit -F arch=b64 -S execve -F euid=0 -k rootcmd
EOF
sudo augenrules --load && sudo systemctl enable --now auditd
```
> **Check:** `sudo auditctl -l` lists the rules; `sudo ausearch -k identity` returns events
> after you touch a watched file. Forward `auditd`/auth logs to the syslog collector so they
> land in the `compute/linux` tree.

## C. Kernel & network sysctl hardening

`/etc/sysctl.d/60-hardening.conf` (safe for a non-routing Linux VM):
```
# spoofing / routing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.ip_forward = 0            # leave 0 unless the host must route
net.ipv4.tcp_syncookies = 1
# ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1
# kernel
kernel.randomize_va_space = 2
```
```bash
sudo sysctl --system      # apply + check for errors
```
> ⚠️ **Do NOT set `ip_forward = 0` on a host that must route** (e.g. a container/NAT host).
> **Check:** `sysctl net.ipv4.tcp_syncookies` → `= 1`.

## D. Login banner (authorised-use notice)

```bash
echo "Authorized access only. Activity is logged and monitored." | sudo tee /etc/issue.net
sudo sed -i 's|^#\?Banner.*|Banner /etc/issue.net|' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
```
> **Check:** the banner shows on the next SSH connection (before the prompt).

## E. File integrity — AIDE

```bash
sudo apt install -y aide
sudo aideinit                                   # builds the baseline DB (slow first run)
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```
A daily check ships with the package (`/etc/cron.daily/aide`); mail/forward its report.
> **Check:** `sudo aide --check` reports "found 0 differences" on a clean box. Re-run
> `aideinit` after intended changes so the DB doesn't drift into noise.

## F. Misc hardening

```bash
# disable core dumps (avoid leaking secrets from memory)
echo '* hard core 0' | sudo tee /etc/security/limits.d/10-nocore.conf
echo 'kernel.core_pattern=|/bin/false' | sudo tee /etc/sysctl.d/61-nocore.conf && sudo sysctl --system
# restrict cron to root + admins
sudo bash -c 'echo root > /etc/cron.allow; echo $SUDO_USER >> /etc/cron.allow'
```
Optional: blacklist USB storage on headless VMs, remove unused listeners
(`sudo ss -tulpn` — anything you don't recognise), disable IPv6 if genuinely unused.

---

## Applying the baseline (Level 1 checklist)

Run in order on a fresh install; confirm each **Check** before moving on:

- [ ] **1** hostname set (`hostnamectl`)
- [ ] **2** chrony installed, TZ `Europe/Amsterdam`, clock synced (`timedatectl`, `chronyc tracking`)
- [ ] **3** static IP + Technitium DNS + correct search domain, no stray `8.8.8.8` (`resolvectl status`)
- [ ] **4** key-only SSH, hardening drop-in in effect (`sudo sshd -T`), fresh login proven
- [ ] **5** ufw default-deny, SSH from mgmt/lab_lan only (`ufw status verbose`)
- [ ] **6** unattended-upgrades enabled (`--dry-run` clean)
- [ ] **7** named admin in `sudo`+`sshusers`; root login off
- [ ] **8** fully patched, `autoremove` run
- [ ] **9** rsyslog forwards to the collectors (primary→failover); logs land in the central tree

> In each service runbook, the old "Part C — Base config" now reduces to: **"Apply the
> [Linux baseline](conventions/linux-baseline.md) Level 1, then open this service's ports."**

---

## Verification & success criteria

**✅ Success criteria — a host meets the baseline when:**
- [ ] Time zone is `Europe/Amsterdam` and the clock is **synced** (no skew).
- [ ] DNS resolves internal FQDNs via **Technitium only** (no public resolver first).
- [ ] SSH accepts **keys only** — password + root login are refused.
- [ ] ufw is **default-deny incoming**; only SSH-from-mgmt (+ the service's own ports) are open.
- [ ] `unattended-upgrades` applies **security** updates automatically.
- [ ] Only a **named admin** can log in (in `sshusers`); no shared/anon accounts.
- [ ] *(Level 2, where applied)* fail2ban/auditd/sysctl/AIDE active and reporting.

**🧪 End-to-end test:**
```bash
timedatectl                                              # TZ Amsterdam; "synchronized: yes"
resolvectl status | grep -E 'DNS Servers|DNS Domain'     # 172.16.10.53/.54; correct search
getent hosts dnldns101.mgt.devnetlabs.com                # resolves internally
sudo sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|allowgroups'   # no / no / sshusers
ssh -o PreferredAuthentications=password <host>          # MUST fail (publickey only)
sudo ufw status verbose                                  # default deny in; 22 from the two /24s
sudo unattended-upgrade --dry-run | tail                 # runs clean
```

**⚠️ Watch out for:**
- **Clock skew** — the silent killer: Prometheus drops skewed samples, logs land in the
  wrong day's file. Confirm `chronyc tracking`, not just that chrony is installed.
- **Stray resolver** — a cloud-init/netplan file listing `8.8.8.8` first NXDOMAINs internal
  zones; `resolvectl status` must show Technitium only.
- **`mgt` vs `mgmt`** — the zone is `mgt.devnetlabs.com`; a search-domain typo breaks
  short-name resolution on VLAN-1000 hosts.
- **Locking yourself out** — validate `sshd -t` and prove a fresh login before closing the
  session; keep the Proxmox console as the escape hatch.
- **`AllowGroups sshusers`** — your user must be in `sshusers` or *every* login is denied.
- **ufw ordering** — enable ufw only **after** the SSH allow rules exist, or you drop your
  own session.
- **Level 2 `ip_forward=0`** — don't apply it to a host that must route (NAT/container host).

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| Internal FQDNs won't resolve | stray resolver (8.8.8.8) first, or wrong search domain | `resolvectl status`; remove the stray netplan/cloud-init resolver; set search to `mgt`/`dcNN.devnetlabs.com` |
| `ssh <host>` → `Permission denied (publickey)` | key not installed / bad perms / not in `sshusers` | `ssh -v`; `~/.ssh` 700 + `authorized_keys` 600; `sudo usermod -aG sshusers <user>` |
| Locked out after sshd change | bad `10-hardening.conf` | Proxmox console → `sudo sshd -t` → fix → `systemctl reload ssh` |
| Prometheus "sample too old/new" / logs in wrong day | clock skew | `timedatectl`; `chronyc tracking`; fix the chrony source, `systemctl restart chrony` |
| No packets reach a service after install | ufw default-deny, service port not opened | open it in the service runbook: `sudo ufw allow from <src> to any port <p> proto tcp` |
| Security updates not applying | unattended-upgrades not enabled / origin commented | `sudo dpkg-reconfigure -plow unattended-upgrades`; check `50unattended-upgrades` origins |
| Own IP got fail2ban-banned | repeated failed auth | `sudo fail2ban-client set sshd unbanip <ip>`; confirm `ignoreip` covers the mgmt /24s |
| AIDE check floods with diffs | DB not re-baselined after intended changes | `sudo aideinit` → move `aide.db.new` → `aide.db` |
| `NetBox`/tool rejects timezone | non-IANA TZ (`CEST`) | `sudo timedatectl set-timezone Europe/Amsterdam` |

---

See also: [bastion-setup.md](../bastion-setup.md) (reference implementation) ·
[naming-convention.md](naming-convention.md) · [tagging-plan.md](tagging-plan.md) ·
[network-vlan-design.md](../network/network-vlan-design.md) ·
[log-source-onboarding.md](../logging/log-source-onboarding.md)
