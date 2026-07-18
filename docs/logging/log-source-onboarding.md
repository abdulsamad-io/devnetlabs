# Log Source Onboarding — per-device syslog config

How to point each device/OS at the central collector. Expands **Part 7** of
[rsyslog-setup.md](rsyslog-setup.md).

## Common rules

- **Destination:** the syslog **VIP `172.16.10.70`**, port **514** (never a single
  collector's IP — the VIP fails over).
- **Transport:** prefer **TCP** for reliability (mandatory-ish for chatty firewalls);
  UDP is fine for low-volume gear that only speaks UDP.
- **Source interface / IP:** pin the device's syslog **source to its mgmt IP** — that IP
  is the classification key (see below), so it must be stable.
- **Timestamps:** enable high-resolution timestamps with timezone where the OS allows.
- **Severity:** `informational` is a good default (drop to `notice`/`warning` for noisy gear).

**Collector-side step (once per device):** add the device's mgmt IP → `category/vendor`
in `/etc/rsyslog.d/devnetlabs-sources.json`, then reload: `sudo pkill -HUP rsyslogd`.
(Eventually generated from NetBox — issue #33.) Unmatched IPs land in `others/`.

> **Check (collector side):** after editing, `jq . /etc/rsyslog.d/devnetlabs-sources.json`
> parses cleanly and lists the new IP, then `sudo pkill -HUP rsyslogd` returns no error.

| Device | Classification (`sources.json` value) |
|--------|----------------------------------------|
| Cisco IOS/IOS-XE/IOS-XR/NX-OS | `network/cisco` |
| Juniper Junos | `network/juniper` |
| Arista EOS | `network/arista` |
| MikroTik | `network/mikrotik` |
| Cisco ASA | `security/asa` |
| Cisco FTD | `security/ftd` |
| Palo Alto PAN-OS | `security/panos` |
| FortiGate | `security/fortigate` |
| Check Point | `security/checkpoint` |
| Linux / Proxmox | `compute/linux` |
| Windows | `compute/windows` |
| TrueNAS | `storage/truenas` |

---

## Network

### Cisco IOS / IOS-XE
```
service timestamps log datetime msec localtime show-timezone
logging source-interface <mgmt-int>
logging host 172.16.10.70 transport tcp port 514
logging trap informational
```

### Cisco IOS-XR
```
logging source-interface <mgmt-int> vrf default
logging hostnameprefix <hostname>
logging 172.16.10.70 vrf default severity info
logging trap informational
```

### Cisco NX-OS
```
logging timestamp milliseconds
logging source-interface mgmt0
logging server 172.16.10.70 6 use-vrf management facility local7   # 6 = informational
```

### Juniper Junos
```
set system syslog host 172.16.10.70 any info
set system syslog host 172.16.10.70 port 514
set system syslog host 172.16.10.70 source-address <mgmt-ip>
set system syslog time-format year millisecond
```

### Arista EOS
```
logging source-interface Management1
logging host 172.16.10.70 514 protocol tcp
logging trap informational
logging format timestamp high-resolution
```
*(If mgmt is in a VRF: `logging vrf MGMT host 172.16.10.70 514`.)*

### MikroTik (RouterOS) — the core router
```
/system logging action add name=to-collector target=remote \
    remote=172.16.10.70 remote-port=514 src-address=<mgmt-ip> bsd-syslog=yes
/system logging add topics=info  action=to-collector
/system logging add topics=warning action=to-collector
/system logging add topics=error action=to-collector
/system logging add topics=critical action=to-collector
```

---

## Security

### Cisco ASA
```
logging enable
logging timestamp rfc5424
logging device-id hostname
logging host <mgmt-nameif> 172.16.10.70 tcp/514      # or udp/514
logging trap informational
```

### Cisco FTD (Firepower Threat Defense)
Configured in the **manager**, not device CLI:
- **FMC:** Devices → Platform Settings → **Syslog** → *Syslog Servers* → add `172.16.10.70`
  (protocol/port), then enable syslog under *Logging* and on access-control rules.
- **FDM:** Device → System Settings → **Logging Settings** → add the syslog server.

### Palo Alto PAN-OS
1. **Device → Server Profiles → Syslog** → add profile: server `172.16.10.70`, transport
   TCP/UDP, port 514, format **IETF** (RFC 5424) or BSD.
2. Attach it: **Objects → Log Forwarding** profile (traffic/threat) *and* **Device → Log
   Settings** (System/Config). Commit.

### FortiGate (FortiOS)
```
config log syslogd setting
    set status enable
    set server "172.16.10.70"
    set port 514
    set mode reliable          # TCP; use 'udp' for UDP
    set facility local7
    set format rfc5424
end
config log syslogd filter
    set severity information
end
```

### Check Point
Log Exporter (on the mgmt/log server):
```
cp_log_export add name devnetlabs target-server 172.16.10.70 target-port 514 protocol tcp format syslog
cp_log_export restart name devnetlabs
```

---

## Compute

### Linux / Proxmox (rsyslog client → forward)
`/etc/rsyslog.d/90-forward.conf`:
```
*.*  @@172.16.10.70:514
```
`@@` = TCP, `@` = UDP. Then `sudo systemctl restart rsyslog`. For resilience, wrap with a
queued `action(type="omfwd" ... queue.type="linkedList" queue.filename="fwd" action.resumeRetryCount="-1")`.
*(Proxmox nodes are Debian → classify `compute/linux`.)*

### Windows (nxlog Community — no native syslog)
`nxlog.conf` (minimal):
```
<Extension syslog>  Module xm_syslog  </Extension>
<Input eventlog>    Module im_msvistalog  </Input>
<Output collector>
    Module om_tcp
    Host 172.16.10.70
    Port 514
    Exec to_syslog_ietf();
</Output>
<Route r>  Path eventlog => collector  </Route>
```
*(Alternatives: Windows Event Forwarding, or ship straight to Graylog via Sidecar — but
that bypasses the rsyslog pipeline.)*

---

## Storage

### TrueNAS (SCALE)
UI: **System Settings → Advanced → Syslog** → Syslog Server `172.16.10.70:514`,
transport TCP/UDP, and set the Syslog Level. (Classify `storage/truenas`.)

---

## Anything else
Same pattern: point the device's syslog at `172.16.10.70:514` (TCP preferred, pinned
source IP), then map its IP in `sources.json`. Until mapped, its logs appear in
`others/` — the signal to add it.

---

## Verification & success criteria

Per onboarded device — check on the **active** collector:

**✅ Success criteria — a source is onboarded when:**
- [ ] Its mgmt IP is mapped in `devnetlabs-sources.json` and the map reloaded (`sudo pkill -HUP rsyslogd`).
- [ ] Its logs land in the **expected `category/vendor`** file — **not** `others/`.
- [ ] Each line carries the device's **source IP** and a sane RFC3339 timestamp.
- [ ] The device targets the **VIP `172.16.10.70`**, not a single collector's IP.

**🧪 Test:**
```bash
# configure the device, generate/await an event, then on the active collector:
ls -t /var/log/devnetlabs_logs/<category>/<vendor>/                 # today's file exists & grows
sudo tail -f /var/log/devnetlabs_logs/<category>/<vendor>/<vendor>-$(date +%F).log
sudo tail -f /var/log/devnetlabs_logs/others/others-$(date +%F).log # still here = not classified
```
Expected: the event appears under `<category>/<vendor>/` with the device's source IP in the line.

**⚠️ Watch out for:**
- **Landed in `others/`** — the source IP isn't mapped, or the device sends from a *different* interface IP than you mapped. Pin the device's syslog **source-interface / source-address** to its mgmt IP.
- **Nothing arrives** — an ACL/firewall between device and VIP, a transport mismatch, or the device pointing at a collector IP instead of the VIP.
- **UDP silently drops** — no delivery guarantee; prefer TCP for chatty gear and confirm with a manual event.
- **Forgot the HUP reload** — a new mapping doesn't take effect until `sudo pkill -HUP rsyslogd`.
- **Device clock skew** — events bucket into the wrong day's file; enable NTP + high-res timestamps.

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| Device's logs land in `others/` | source IP not in `sources.json`, or device sources from a different IP | add the mapping + `sudo pkill -HUP rsyslogd`; pin the device's syslog `source-interface`/`source-address` to its mgmt IP |
| No logs arrive at all | ACL/firewall to the VIP, wrong transport, or pointing at a collector IP not the VIP | `sudo tcpdump -ni any port 514` on the active collector; confirm the device targets `172.16.10.70`; check TCP vs UDP |
| Intermittent loss on a chatty device | UDP has no delivery guarantee | switch the device to **TCP** (`@@` / `transport tcp` / `mode reliable`) |
| New mapping didn't take effect | forgot the reload | `jq . …sources.json` (valid?) then `sudo pkill -HUP rsyslogd` |
| Lines bucket into the wrong day's file | device clock skew | enable NTP + high-resolution timestamps on the device |
| Windows host sends nothing | nxlog not running / wrong output target | `Get-Service nxlog`; check `nxlog.conf` `om_tcp` Host = `172.16.10.70` |

---

See also: [rsyslog-setup.md](rsyslog-setup.md) · [keepalived-setup.md](keepalived-setup.md) ·
[logging-design.md](logging-design.md)
