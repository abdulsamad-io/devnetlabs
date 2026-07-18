# SNMP Source Onboarding — per-device SNMPv2c / SNMPv3 config

How to enable SNMP on each device and register it with Prometheus. The metrics analog of
[log-source-onboarding.md](../logging/log-source-onboarding.md); expands the SNMP job in
[prometheus-setup.md](prometheus-setup.md).

## How the polling works (read this first)

Prometheus doesn't speak SNMP — the on-box **`snmp_exporter`** does. Prometheus hands each
device to the **local** `snmp_exporter` (the proxy relabel), which polls it over **UDP/161**
and returns metrics. So onboarding a device is **three edits, all on the Prometheus side**
plus enabling SNMP on the device:

```
device (UDP/161) ──poll── snmp_exporter (127.0.0.1:9116) ──/snmp── Prometheus ──▶ Grafana
```

**Poller IPs** (allow these on each device's SNMP ACL): `10.110.10.72` (`dnlprm101`, dc01)
**and** `10.120.10.72` (`dnlprm201`, dc02) — both Prometheus servers poll the full fleet
independently.

## Common rules

- **Version:** prefer **SNMPv3 (authPriv)** for anything that supports it — v2c sends the
  community in cleartext. Use **v2c** only for gear that can't do v3.
- **Read-only.** Monitoring never needs write; use RO community / a read-only v3 user.
- **Restrict by source IP** on the device to the two poller IPs above.
- **Consistent creds across the fleet** keep the `snmp_exporter` `auths:` list small — e.g.
  one v3 user `monitor` everywhere, one fallback v2c community for legacy gear.
- **No traps here** — this is polling. (Traps could go to the syslog/Graylog path later.)

**Three collector-side edits per device** (do on **both** `dnlprm101` and `dnlprm201`):
1. Define/confirm a matching **`auth`** in `snmp_exporter`'s `snmp.yml` (community or v3 creds).
2. Add the device to the **file_sd JSON** (`/etc/prometheus/targets/snmp_*.json`), with
   `__param_module` / `__param_auth` labels if it differs from the job default.
3. That's it — Prometheus hot-reloads the target; `snmp_exporter` reload only needed if you
   changed `snmp.yml`.

---

## Network

### MikroTik (RouterOS) — the core router
```
# v2c
/snmp community add name=labmon addresses=10.110.10.72/32,10.120.10.72/32 read-access=yes
/snmp set enabled=yes contact="netops" location="lab"
# v3 (authPriv) — set the community to authorized/private with auth+encryption
/snmp community add name=v3mon addresses=10.110.10.72/32,10.120.10.72/32 \
    security=private authentication-protocol=SHA1 authentication-password=<authpass> \
    encryption-protocol=AES encryption-password=<privpass>
```

### Cisco IOS / IOS-XE
```
! v2c
snmp-server community labmon RO 99
access-list 99 permit 10.110.10.72
access-list 99 permit 10.120.10.72
! v3 (authPriv)
snmp-server view MONVIEW iso included
snmp-server group MONGRP v3 priv read MONVIEW
snmp-server user monitor MONGRP v3 auth sha <authpass> priv aes 128 <privpass>
```

### Cisco NX-OS
```
snmp-server community labmon group network-operator          ! v2c
snmp-server user monitor auth sha <authpass> priv aes-128 <privpass>   ! v3
```

### Juniper Junos
```
# v2c
set snmp community labmon authorization read-only
set snmp community labmon clients 10.110.10.72/32
set snmp community labmon clients 10.120.10.72/32
# v3 (authPriv)
set snmp v3 usm local-engine user monitor authentication-sha authentication-password <authpass>
set snmp v3 usm local-engine user monitor privacy-aes128 privacy-password <privpass>
set snmp v3 vacm security-to-group security-model usm security-name monitor group MONGRP
set snmp v3 vacm access group MONGRP default-context-prefix security-model usm security-level privacy read-view all
set snmp view all oid .1 include
```

### Arista EOS
```
snmp-server community labmon ro                              ! v2c
snmp-server view MONVIEW iso included
snmp-server group MONGRP v3 priv read MONVIEW
snmp-server user monitor MONGRP v3 auth sha <authpass> priv aes <privpass>
```

---

## Security

### Cisco ASA
```
! v2c (poll)
snmp-server host <mgmt-nameif> 10.110.10.72 poll community labmon version 2c
snmp-server host <mgmt-nameif> 10.120.10.72 poll community labmon version 2c
! v3 (authPriv)
snmp-server group MONGRP v3 priv
snmp-server user monitor MONGRP v3 auth sha <authpass> priv aes 128 <privpass>
snmp-server host <mgmt-nameif> 10.110.10.72 poll version 3 monitor
```

### Palo Alto PAN-OS
**Device → Setup → Operations → SNMP Setup.** v2c: set the community. v3: add a user with
auth (SHA) + priv (AES) and a view. Commit. (Also **Device → Setup → Management** must
permit SNMP on the mgmt interface / interface mgmt-profile.)

### FortiGate (FortiOS)
```
config system snmp sysinfo
    set status enable
end
config system snmp community                 # v2c
    edit 1
        set name labmon
        config hosts
            edit 1
                set ip 10.110.10.72 255.255.255.255
            next
        end
    next
end
config system snmp user                      # v3
    edit monitor
        set security-level auth-priv
        set auth-proto sha256
        set auth-pwd <authpass>
        set priv-proto aes256
        set priv-pwd <privpass>
    next
end
```

### Check Point
Gaia clish: `set snmp agent on`, `set snmp community labmon read-only` (v2c) or
`set snmp usm user monitor security-level authPriv auth-pass-phrase <authpass>
privacy-pass-phrase <privpass>` (v3); `set snmp agent-version any`.

---

## Compute

### Linux (net-snmp `snmpd`)
`/etc/snmp/snmpd.conf`:
```
# v2c
rocommunity labmon 10.110.10.72
rocommunity labmon 10.120.10.72
# v3 (create once, stop snmpd first) — appends to /var/lib/snmp/snmpd.conf:
#   sudo systemctl stop snmpd
#   sudo net-snmp-create-v3-user -ro -A <authpass> -a SHA -X <privpass> -x AES monitor
```
`sudo systemctl restart snmpd`. Bind `agentaddress udp:161` on the mgmt IP.

### Windows
Native SNMP is deprecated. Options: enable the legacy **SNMP Service** feature (v2c only,
community + permitted managers), or run a Prometheus **`windows_exporter`** instead (scraped
directly on `:9182` — no SNMP). For a metrics lab, `windows_exporter` is the cleaner path.

---

## Storage

### TrueNAS (SCALE)
**System Settings → Services → SNMP** → enable; set the **Community** (v2c). For v3, set the
username + auth/priv. Restrict to the poller IPs at the firewall.

---

## Collector side — `snmp_exporter` auths + Prometheus target

**1. Define the auth(s)** in `/etc/snmp_exporter/snmp.yml` on **both** `dnlprm101` and
`dnlprm201` (add to the `auths:` map alongside the shipped modules):
```yaml
auths:
  lab_v2:
    version: 2
    community: labmon
  lab_v3:
    version: 3
    username: monitor
    security_level: authPriv
    password: <authpass>
    auth_protocol: SHA
    priv_protocol: AES
    priv_password: <privpass>
```
```bash
sudo systemctl reload snmp_exporter || sudo systemctl restart snmp_exporter   # reload snmp.yml
```

**2. Pass a default `auth` in the SNMP job** (`/etc/prometheus/prometheus.yml`, Part G of
[prometheus-setup.md](prometheus-setup.md)) — add `auth` next to `module`:
```yaml
    params:
      module: [if_mib]
      auth:   [lab_v3]        # default; per-device override via __param_auth below
```

**3. Add the device** to `/etc/prometheus/targets/snmp_devices.json` (hot-reloaded).
Override module/auth per device with `__param_*` labels:
```json
[
  { "targets": ["172.16.10.1"], "labels": { "vendor": "mikrotik", "__param_auth": "lab_v3" } },
  { "targets": ["10.20.0.10"],  "labels": { "vendor": "cisco-asa", "__param_module": "if_mib", "__param_auth": "lab_v2" } }
]
```

---

## Verification & success criteria

**✅ Success criteria — a device is onboarded when:**
- [ ] SNMP is enabled on the device (v2c community or v3 user), restricted to the poller IPs.
- [ ] A matching `auth` exists in `snmp.yml` on **both** Prometheus nodes.
- [ ] The device is in the file_sd JSON and shows **`up`** under Prometheus targets.
- [ ] `snmp_exporter` returns real metrics for it (not an auth/timeout error).
- [ ] Its series are visible in Grafana with the expected `vendor`/labels.

**🧪 Test (on the Prometheus node):**
```bash
# raw poll through the local exporter (swap module/auth as needed):
curl -s 'localhost:9116/snmp?target=172.16.10.1&module=if_mib&auth=lab_v3' | head
# from the device side, confirm the exporter can reach it:
snmpwalk -v3 -l authPriv -u monitor -a SHA -A <authpass> -x AES -X <privpass> 172.16.10.1 sysName   # v3
snmpget  -v2c -c labmon 172.16.10.1 .1.3.6.1.2.1.1.5.0                                               # v2c
# target health:
curl -s 'localhost:9090/api/v1/targets' | jq '.data.activeTargets[]|select(.labels.job=="snmp")|{instance,health}'
```
Expected: the `/snmp` curl returns metrics, and the target's `health` is `up`.

**⚠️ Watch out for:**
- **v3 auth/priv mismatch** — protocol (SHA/SHA256, AES/AES256) and passwords must match *exactly* on device and `snmp.yml`; a mismatch = silent timeout/`up=0`.
- **Community typo / not RO-from-poller** — device ACL must permit `.72` on both DCs.
- **Wrong `module`** — must exist in `snmp.yml` and match the device's OIDs (`if_mib` for interfaces).
- **UDP/161 blocked** — inter-VLAN routing is open, but a device-side firewall may drop the poller.
- **`snmp.yml` only on one node** — do the auth edit on **both** `dnlprm101` and `dnlprm201`.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| Target `health="down"`, error `request timeout` | device SNMP off / wrong community or v3 creds / UDP-161 blocked | `snmpwalk`/`snmpget` from the Prometheus node; fix creds or the device ACL |
| `/snmp?...` → `unknown auth` | `auth` name not in `snmp.yml` | add the `auths:` entry; `systemctl reload snmp_exporter` |
| `/snmp?...` → `unknown module` | `module` not in `snmp.yml` | use a shipped module or regenerate `snmp.yml` with the generator |
| Metrics come back but sparse/empty | wrong module for the vendor's OIDs | pick/generate a vendor module; verify with `snmpwalk` on the OID tree |
| Works on dc01 Prometheus, not dc02 | `snmp.yml` auth or target only added on one node | replicate the `snmp.yml` + file_sd edits on `dnlprm201` |
| `all series labelled instance="127.0.0.1:9116"` | proxy `relabel_configs` missing | restore the three relabel rules (prometheus-setup Part G) |
| Device added to JSON but no target | invalid JSON / wrong glob | `jq . …snmp_devices.json`; check **Status → Service Discovery** |
| v3 "wrong digest" / "decryption error" | auth/priv protocol or password mismatch | align `auth_protocol`/`priv_protocol` + passwords on device and `snmp.yml` |

---

See also: [prometheus-setup.md](prometheus-setup.md) · [log-source-onboarding.md](../logging/log-source-onboarding.md) ·
[grafana-setup.md](grafana-setup.md) · [lld.md](../lld.md)
