# Ansible — Linux Baseline

Reusable playbook that applies the DevNetLabs **Linux baseline** to every Ubuntu guest.
It's the automation of [../../docs/conventions/linux-baseline.md](../../docs/conventions/linux-baseline.md)
(Level 1 mandatory + Level 2 opt-in hardening).

> Unlike the [technitium](../technitium/) project (API-driven, `connection: local`), this
> one runs **over SSH with sudo** against real Linux hosts.

## Add / remove hosts (the "template")

Everything host-specific lives in **[`inventory.yml`](inventory.yml)**. Add a host with one
line under the zone group that matches its VLAN (the group sets the DNS search domain):
```yaml
zone_dc01:                       # search dc01.devnetlabs.com
  hosts:
    dnllok101: { ansible_host: 10.110.10.70 }   # <- add / remove lines here
```
`zone_mgt` (VLAN 1000 → `mgt.devnetlabs.com`), `zone_dc01/02/03` (per-node VLANs). Nothing
else needs touching to onboard a host.

## What it configures

**Level 1 (every host):** hostname · chrony + timezone `Europe/Amsterdam` (NTP sources in
`baseline_ntp_sources`) · resolvers + search domain (systemd-resolved drop-in) · key-only
SSH hardening drop-in + `sshusers` · ufw default-deny (SSH from mgmt/lab_lan) ·
unattended-upgrades · sudo/allow-group · passwordless sudo (`baseline_passwordless_sudo`,
on) · rsyslog forwarding to the collectors · package hygiene.

> **Syslog forwarding** (`baseline_syslog_servers`, default `172.16.10.71`→`172.16.10.72`)
> sends `*.*` to the primary collector and **fails over** to the second only if the first
> is down — using both without double-ingesting into Loki/Graylog. Set it to `['172.16.10.70']`
> to use the keepalived VIP instead. The collectors set `baseline_manage_syslog: false`
> (host_vars) so they don't forward their own logs into their own pipeline.

**Level 2 (opt-in, `-e baseline_hardening=true`):** fail2ban · auditd + rules · sysctl
network hardening · SSH login banner · AIDE.

Tunables (DNS servers, ufw sources, sshd options, toggles) are in
[`roles/baseline/defaults/main.yml`](roles/baseline/defaults/main.yml) — override per
group/host in the inventory or `host_vars/`.

## Prerequisites

- Install the collections once:
  ```bash
  cd ansible/linux-baseline
  ansible-galaxy collection install -r requirements.yml
  ```
- **A control-node SSH key whose public half is on every target.** The key in
  `inventory.yml` (`all.vars.ansible_ssh_private_key_file`) must exist **on the box you run
  `ansible-playbook` from** — not just on your laptop. Your personal `id_ed25519_devnetlabs`
  private key lives on your Windows client (per [bastion-setup.md](../../docs/bastion-setup.md));
  the bastion only holds its *public* half. So if the **bastion is your control node**,
  give it its own key and push the public half to each target (password auth still works
  until the baseline disables it):
  ```bash
  # on the bastion (control node):
  ssh-keygen -t ed25519 -a 100 -f ~/.ssh/id_ed25519_devnetlabs -C "ansible@dnladm101"
  for h in 172.16.10.71 172.16.10.72 172.16.10.50 10.110.10.70 10.110.10.71 10.110.10.53; do
    ssh-copy-id -i ~/.ssh/id_ed25519_devnetlabs.pub abdoolsamad@"$h"
  done
  ```
  The bastion targets itself via `ansible_connection: local` (set in the inventory), so it
  needs no key to itself. *(Alternative: SSH into the bastion with agent forwarding
  `ssh -A` and drop `ansible_ssh_private_key_file` so Ansible uses your forwarded agent.)*
- **Only list built, powered-on hosts** in `inventory.yml`. Unbuilt hosts (e.g. Prometheus,
  ntfy) are commented out — uncomment them once they exist, or a run fails `UNREACHABLE`.
- **`become` needs passwordless sudo on this fleet.** The hosts use a custom sudo prompt
  (`[sudo: authenticate]`) that overrides Ansible's own prompt, so `-K`/become-password
  times out (`waiting for privilege escalation prompt`) no matter the timeout — even though
  the password itself is fine. The role manages `/etc/sudoers.d/90-ansible`
  (`baseline_passwordless_sudo: true`), but a **brand-new host needs a one-time manual
  bootstrap** (writing the drop-in needs sudo). On the target, once:
  ```bash
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-ansible >/dev/null \
    && sudo chmod 440 /etc/sudoers.d/90-ansible && sudo visudo -c
  ```
  After that, run the playbook with **no `-K`**; the role keeps the drop-in idempotent.

## Usage

```bash
cd ansible/linux-baseline
ansible-playbook site.yml --check --diff          # DRY RUN first — always
ansible-playbook site.yml                         # apply Level 1 to all hosts
ansible-playbook site.yml --limit dnllog101       # one host
ansible-playbook site.yml --tags ssh,ufw          # a subset
ansible-playbook site.yml -e baseline_hardening=true   # + Level 2 hardening
```
Tags: `identity time dns users ssh ufw updates packages hardening`.

## Per-host overrides (`host_vars/`)

Anything in `defaults/main.yml` can be overridden per host. Two examples in use:

**Service ports** — the baseline only opens SSH; a service's own ports go in `host_vars/<host>.yml`:
```yaml
# host_vars/dnllok101.yml
baseline_ufw_extra_rules:
  - { port: "3100", proto: tcp, from: "10.110.10.71" }   # Loki API <- Grafana
```
**Extra DNS search domains** — the bastion searches every zone so `ssh <shortname>` works
for apps-VLAN hosts, not just its own `mgt` zone ([`host_vars/dnladm101.yml`](host_vars/dnladm101.yml)):
```yaml
# host_vars/dnladm101.yml
baseline_dns_search_extra: [dc01.devnetlabs.com, dc02.devnetlabs.com, dc03.devnetlabs.com]
```

## Safety notes

- **Run `--check --diff` first.** SSH + ufw changes can lock you out if the inventory user/key
  or `baseline_ufw_ssh_sources` are wrong.
- **No lockout by design:** users are added to `sshusers` *before* `AllowGroups` is set, and
  the sshd reload runs `sshd -t &&` first — a bad render fails the play without reloading.
- **DNS is non-destructive:** managed via a `systemd-resolved` drop-in; the role never
  rewrites the interface IP. If a host's netplan sets per-link `nameservers`, those win for
  that link — keep them consistent with `baseline_dns_servers`.
- **`baseline_apt_upgrade` is off by default** (a full-upgrade is disruptive); enable per run.

## Next

Once NetBox is the SoT (#23/#62), generate `inventory.yml` from it instead of hand-editing.
