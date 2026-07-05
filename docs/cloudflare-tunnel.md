# Cloudflare Zero Trust Tunnel — dc01

**Status: design, not yet built.**

**Goal:** publish the dc01 Proxmox VE UI at `pve.devnetlabs.com`, gated by Cloudflare
Access, with **no port forwarding** — ideal for the double-NAT WAN (the connector is
outbound-only on port 7844).

---

## Connector

`cloudflared` in a **Debian VM on dc01, VLAN 1000**.

- Suggested VMID **1006**, hostname **`dnlctl001`**
- Sizing: 1 vCPU / 512 MB / 4 GB

### Install (apt)

```bash
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install -y cloudflared
```

> The **old CF signing key was removed 30 Apr 2026** — you must use the current
> `cloudflare-main.gpg`, especially on Debian 13 / Trixie.

---

## Steps

1. **Create the tunnel.** Zero Trust dashboard → **Networks/Networking → Tunnels** →
   create tunnel `dnl-dc01` (Cloudflared) → run
   `sudo cloudflared service install eyJ...<token>` in the VM → connector shows
   **Healthy**.

2. **Add the public hostname.** `pve.devnetlabs.com` → **HTTPS** → `<dc01-ip>:8006`.
   Under *Additional application settings*:
   - **No TLS Verify: ON** (Proxmox self-signed 8006)
   - **Disable Chunked Encoding: ON**
   - (optionally HTTP2 origin)

   DNS CNAME is auto-created — **do not** add an A record.

3. **Access application (Self-hosted)** for `pve.devnetlabs.com`: Allow policy
   (your email / OTP or SSO).
   - **Disable the "binding cookie"** — otherwise you log in but see an empty
     datacenter and get *"Connection error – server offline?"*.

4. **Console fix.** Add a **second** Access application with a **Bypass** policy on
   `pve.devnetlabs.com/api2/json/*/vncwebsocket` (still secure — Proxmox's own login
   still applies). Required for the noVNC console WebSocket.

---

## Caveats

- **100 MB upload cap** on the CF proxy (free plan) → do **ISO uploads on the LAN**,
  not through the tunnel.
- Keep `cloudflared` updated.
- **One connector on VLAN 1000 can front all three nodes** — add hostnames
  `dc02.devnetlabs.com` / `dc03.devnetlabs.com` / `pbs.devnetlabs.com` → the
  respective `<ip>:8006` (or `:8007` for PBS).

---

## IaC path (future)

Cloudflare Terraform provider:
- `cloudflare_zero_trust_tunnel_cloudflared` + `_config`
- `cloudflare_dns_record`
- `cloudflare_zero_trust_access_application` / `_access_policy`
- tunnel token via the `_token` data source → into Ansible `host_vars`.
