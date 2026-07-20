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

**Level 1 (every host):** hostname · chrony + timezone `Europe/Amsterdam` · resolvers +
search domain (systemd-resolved drop-in) · key-only SSH hardening drop-in + `sshusers` ·
ufw default-deny (SSH from mgmt/lab_lan) · unattended-upgrades · sudo/allow-group · package
hygiene.

**Level 2 (opt-in, `-e baseline_hardening=true`):** fail2ban · auditd + rules · sysctl
network hardening · SSH login banner · AIDE.

Tunables (DNS servers, ufw sources, sshd options, toggles) are in
[`roles/baseline/defaults/main.yml`](roles/baseline/defaults/main.yml) — override per
group/host in the inventory or `host_vars/`.

## Prerequisites

- Key-based SSH to each host already works (bootstrap via
  [../../docs/bastion-setup.md](../../docs/bastion-setup.md)) — the login user + key are in
  `inventory.yml` (`all.vars`).
- Install the collections once:
  ```bash
  cd ansible/linux-baseline
  ansible-galaxy collection install -r requirements.yml
  ```

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

## Per-host service ports

The baseline only opens SSH. A service's own ports go in `host_vars/<host>.yml`, e.g.:
```yaml
# host_vars/dnllok101.yml
baseline_ufw_extra_rules:
  - { port: "3100", proto: tcp, from: "10.110.10.71" }   # Loki API <- Grafana
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
