# keepalived VIP Setup — syslog collectors `dnllog101` / `dnllog201`

A floating **VIP `172.16.10.70`** across the two rsyslog collectors so that **only the
active node receives syslog and fans out** to Loki/Graylog — no double-ingest — with
automatic failover. Context: [logging-design.md](logging-design.md),
[rsyslog-setup.md](rsyslog-setup.md).

## Facts

| Item | Value |
|------|-------|
| VIP | **`172.16.10.70/24`** (VLAN 1000; reserved, outside DHCP pool) |
| MASTER | `dnllog101` (dc01) — priority 150 |
| BACKUP | `dnllog201` (dc02) — priority 100 |
| VRID | `51` (must match both; unique on VLAN 1000) |
| Protocol | VRRP — **unicast** (robust on Proxmox VNets; multicast optional) |

**How it removes duplication:** sources point **only at the VIP**, so only the VIP-holder
receives → only it writes files + forwards. The standby's rsyslog sits idle until it
takes the VIP.

---

## Prerequisites

- Both collectors on **VLAN 1000**, with static mgmt IPs (`<log101-ip>` / `<log201-ip>`).
- `172.16.10.70` reserved (not in the DHCP pool).
- rsyslog listening on **all addresses** (`0.0.0.0:514`) — the default — so it answers on
  the VIP whenever the host holds it. (No `ip_nonlocal_bind` needed unless a service binds
  the VIP specifically.)

## Step 1 — Install

```bash
sudo apt update && sudo apt install -y keepalived
```

## Step 2 — Health check script

Fail over if **rsyslog** dies (not only if the whole host dies). `/etc/keepalived/chk_rsyslog.sh`:
```bash
#!/bin/sh
# healthy if rsyslog is running AND listening on 514/tcp
pgrep -x rsyslogd >/dev/null && ss -lnt 'sport = :514' | grep -q ':514'
```
```bash
sudo chmod 750 /etc/keepalived/chk_rsyslog.sh
```

## Step 3 — Config

**`dnllog101` (MASTER) — `/etc/keepalived/keepalived.conf`:**
```
global_defs {
    enable_script_security
    script_user root
}
vrrp_script chk_rsyslog {
    script   "/etc/keepalived/chk_rsyslog.sh"
    interval 2
    fall     2
    rise     2
    weight   -60          # 150-60=90 < 100 -> BACKUP takes over if rsyslog fails
}
vrrp_instance VI_SYSLOG {
    state          MASTER
    interface      ens18            # NIC on VLAN 1000 (check with: ip -br a)
    virtual_router_id 51
    priority       150
    advert_int     1
    unicast_src_ip <log101-ip>      # this host
    unicast_peer   { <log201-ip> }  # the other host
    authentication { auth_type PASS; auth_pass <shared-secret> }
    virtual_ipaddress { 172.16.10.70/24 dev ens18 }
    track_script { chk_rsyslog }
}
```

**`dnllog201` (BACKUP)** — identical **except**:
```
    state          BACKUP
    priority       100
    unicast_src_ip <log201-ip>
    unicast_peer   { <log101-ip> }
```
> **Priority math:** MASTER 150, BACKUP 100, `weight -60` → a failed rsyslog drops the
> master to 90 (< 100) so the backup wins. If you used `weight -40` it'd stay at 110 and
> **never** fail over — the drop must cross the backup's priority.

## Step 4 — Firewall (ufw)

Allow VRRP between the two collectors, and syslog inbound. Simplest lab approach —
trust the peer host fully (covers unicast VRRP, IP proto 112):
```bash
sudo ufw allow from <log101-ip>                                   # (run on log201)
sudo ufw allow from <log201-ip>                                   # (run on log101)
sudo ufw allow proto udp to any port 514
sudo ufw allow proto tcp to any port 514
```
*(Purist alternative: allow only IP proto 112 from the peer via `/etc/ufw/before.rules`.
For multicast VRRP instead of unicast, also allow `224.0.0.18`.)*

## Step 5 — Enable & verify

```bash
sudo systemctl enable --now keepalived
```
- **On MASTER:** `ip addr show ens18` → shows `172.16.10.70` as a second address.
- **On BACKUP:** no VIP.
- **Failover test:** on the master, `sudo systemctl stop keepalived` (or `sudo pkill rsyslogd`)
  → within ~1–3 s the VIP appears on the backup (gratuitous ARP updates the switch).
  Restart it and (default preempt) the master reclaims the VIP.
- **State log:** `journalctl -u keepalived -f` shows `Entering MASTER/BACKUP STATE`.
- **End-to-end:** `logger -n 172.16.10.70 -P 514 -d "vip test"` lands on the active
  collector both before and after a failover.

## Notes & gotchas

- **Split-brain:** if the two can't exchange VRRP, **both** become master and both claim
  the VIP → duplication returns. With `unicast_peer` + the ufw peer-allow above this is
  avoided; verify **only one** host shows the VIP.
- **Flapping on failback:** default behaviour preempts (master reclaims on return),
  causing a brief blip. To keep the VIP on whoever currently holds it, set both to
  `state BACKUP` + add `nopreempt` to the instance.
- **Graylog disk-queue** lives on whichever collector holds the VIP; a failover starts a
  fresh buffer on the new active node (acceptable — Loki keeps the full stream).
- **`dc02` is on-demand:** `dnllog201` is only a live standby when dc02 is powered on. If
  dc02 is off, `dnllog101` simply stays master (no peer to fail to) — fine.
- Fill `<log101-ip>` / `<log201-ip>` from the hosts' mgmt reservations and confirm the
  `interface` name (`ip -br a`).

---

## Verification & success criteria

Run the tests in **Step 5**; the pair is healthy when:

**✅ Success criteria:**
- [ ] Exactly **one** host shows `172.16.10.70` (the MASTER); the BACKUP shows none.
- [ ] Stopping rsyslog (or keepalived) on the master moves the VIP to the backup within ~1–3 s.
- [ ] `logger -n 172.16.10.70 -P 514 -d` lands on the current holder **before and after** failover.
- [ ] `journalctl -u keepalived` shows clean `Entering MASTER/BACKUP STATE`, no flapping.
- [ ] After the master returns, the VIP behaves per your preempt choice (reclaims by default).

**⚠️ Watch out for** (see Notes & gotchas for detail):
- **Split-brain** — VRRP can't pass → *both* claim the VIP → duplication. Verify only one holder; check the ufw peer-allow + `unicast_peer`.
- **Weight math** — the drop must take the master *below* the backup (150−60=90 < 100) or it never fails over.
- **Wrong `interface`** — must be the VLAN-1000 NIC (`ip -br a`) or the VIP silently never appears.
- **`dc02` off** — no standby present; the master stays up alone (expected, not a fault).

## Troubleshooting & remediation guide

| Symptom | Likely cause | Diagnose / remediation |
|---------|--------------|------------------------|
| VIP `.70` on **both** nodes (split-brain) | VRRP not passing (ufw blocks proto 112, or `unicast_peer` wrong) | allow the peer in ufw; verify `unicast_src_ip`/`unicast_peer` + matching `virtual_router_id 51`; `sudo tcpdump -ni ens18 vrrp` |
| VIP **never** fails over | `weight` too small — master stays above backup | the drop must cross the backup's priority (150−60=90 < 100); use `weight -60` |
| VIP absent on **both** nodes | wrong `interface`, or keepalived down | fix `interface` to the VLAN-1000 NIC (`ip -br a`); `journalctl -u keepalived` |
| `logger -n 172.16.10.70` silently dropped | no host holds the VIP | `ip -br a \| grep 172.16.10.70`; start keepalived on the master |
| Brief blip / flapping on failback | default preempt (master reclaims) | set both `state BACKUP` + `nopreempt` if the VIP should stay put |
| Health check never trips failover | `chk_rsyslog.sh` not executable / wrong path | `chmod 750 …chk_rsyslog.sh`; run it by hand; confirm `enable_script_security` + `script_user` |
| Graylog buffer "lost" after failover | disk-queue is per-node | expected — the new active starts a fresh buffer; Loki keeps the full stream |

---

See also: [logging-design.md](logging-design.md) · [rsyslog-setup.md](rsyslog-setup.md) ·
[lld.md](../lld.md)
