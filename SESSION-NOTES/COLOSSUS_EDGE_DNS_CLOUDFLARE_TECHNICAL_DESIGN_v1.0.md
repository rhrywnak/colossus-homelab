# COLOSSUS — External Access + DNS Architecture (UDM + Pi-hole + Cloudflare Tunnel) — Technical Design v1.0

**Project:** Colossus Homelab  
**Authoritative Context Source:** `COLOSSUS_HOMELAB_MASTER_CONTEXT.md` fileciteturn0file0  
**Scope:** Internet access for selected self-hosted web apps; segmented internal DNS strategy; protect Proxmox cluster hostname stability.  
**Status:** Draft v1.0 (ready for execution)  
**Date:** 2026-02-09 (America/Detroit)

---

## 0. Executive Summary

This design enables secure internet access to homelab web applications without inbound port forwarding on the UniFi Dream Machine (UDM), while preserving Proxmox cluster hostname stability and supporting a split DNS model:

- **Keep Proxmox node hostnames unchanged** (e.g., `pve-1.local`, `pve-2.local`, `pve-3.local`) to avoid breaking corosync/cert bindings.
- **Family devices use UDM-provided DNS** for maximum stability and minimal friction.
- **Homelab/servers use Pi-hole DNS** for lab control (blocking, logging, internal records).
- **External access uses Cloudflare Tunnel (cloudflared)** running as an “edge” service on **pve-3** (the designated infra/services host) fileciteturn0file0.
- **Split-horizon DNS** is achieved by using the *same public domain names* externally (Cloudflare) and overriding them internally (Pi-hole or UDM) to point directly to internal service IPs.

Recommended production-grade result:
- No open inbound ports on the router.
- Strong authentication at the edge (Cloudflare Access).
- Internal performance optimized via split-horizon (internal clients stay local).

---

## 1. Goals and Non-Goals

### 1.1 Goals

1. Provide **secure internet access** to selected internal web applications.
2. Preserve **Proxmox cluster stability** (no hostname changes).
3. Maintain **household reliability**: family devices should not depend on experimental lab services.
4. Support **repeatability** and “rebuild > mutate” principles fileciteturn0file0.
5. Support **split-horizon DNS**: same friendly names work inside and outside.
6. Keep the solution **operationally boring**: minimal moving parts, predictable recovery.

### 1.2 Non-Goals

- Exposing raw TCP/UDP services broadly to the internet.
- Building a “full enterprise HA” edge cluster.
- Replacing UniFi routing/firewall with an alternative.
- Renaming Proxmox nodes or changing Proxmox cluster domain assumptions.

---

## 2. Current Constraints and Design Rules

From the Colossus master context:

- Node roles are exclusive:  
  - `pve-1` = production workloads  
  - `pve-2` = development workloads  
  - `pve-3` = Proxmox Backup Server and infra/services fileciteturn0file0
- “Rebuild > mutate”, “VMs are disposable; datasets are not”, “Everything important must be scriptable” fileciteturn0file0.

**Critical Proxmox constraint:** Proxmox cluster is hostname-sensitive. **Do not change**:
- Proxmox node hostname
- /etc/hosts mappings used for cluster
- corosync node names
- certificates associated with node names

**Additional DNS constraint:** `.local` is typically reserved for mDNS/Bonjour; however, the cluster is already built on `.local`. We will **not** “fix” this in-place; we will **avoid** using `.local` for new service naming.

---

## 3. Components Overview

### 3.1 UniFi Dream Machine (UDM)

**Role in this design**
- Default gateway, routing, VLAN segmentation, DHCP
- Provides DNS to **family VLAN** (stable “appliance mode”)
- Provides firewall policy enforcement (including “force DNS through Pi-hole” for lab/IoT if desired)

**Key configuration responsibilities**
- Per-network DHCP “DNS Server” assignment
- VLAN isolation and allow rules (DNS access to Pi-hole where required)
- No inbound port forwards (recommended)

---

### 3.2 Pi-hole (DNS for Lab/Servers; Optional for IoT)

**Role**
- DNS server for lab VLAN(s), providing:
  - internal DNS records (host overrides)
  - ad/tracker blocking (optional)
  - query logging and troubleshooting visibility

**Recommended placement**
- Runs as a service on `pve-3` (infra/services role) to align with your role-separation principle fileciteturn0file0.

**Notes**
- For household stability, Pi-hole should **not** be required for the family VLAN.
- You can run Pi-hole as an LXC or VM or container; keep it “boring” and backed up.

---

### 3.3 Cloudflare (Domain + DNS + Tunnel + Access)

**Role**
- Public DNS hosting for your chosen domain
- Terminates TLS at the edge
- Provides **Cloudflare Tunnel** endpoint that maps public hostnames to internal services via an outbound-only tunnel
- Optional: Cloudflare Access (Zero Trust) for authentication and policy

**Key point**
- With Cloudflare Tunnel, you do **not** open inbound ports on the UDM. Internal connector (cloudflared) makes outbound connections to Cloudflare.

---

### 3.4 cloudflared (Tunnel Connector)

**Role**
- Runs inside your homelab as a small service (container/VM)
- Maintains outbound encrypted tunnel to Cloudflare edge
- Routes incoming requests (from Cloudflare) to internal services

**Recommended placement**
- **Dedicated “Edge Services” VM on pve-3** (e.g., `colossus-edge1`) to avoid coupling to app hosts and to maintain infra stability (same pattern as PBS: infra-only).

---

### 3.5 Reverse Proxy (Optional)

**Role**
- Provide internal routing, headers, auth integration, and consistent local access (e.g., nginx/caddy/traefik).
- Not required for Cloudflare Tunnel, but useful if you want a single internal entry point or additional internal policy.

**Recommendation**
- Optional Phase 2 enhancement. Start without it unless you truly need it.

---

## 4. DNS Strategy (Three-Layer Model)

### 4.1 Layer 1 — Infrastructure Hostnames (Do Not Touch)

Examples:
- `pve-1.local`
- `pve-2.local`
- `pve-3.local`

**Rule:** Do not rename. Do not “upgrade” to a new internal domain. Do not rebase cluster names.

---

### 4.2 Layer 2 — Internal Service DNS (Lab-facing)

Goal: friendly hostnames for services used within LAN.

Two acceptable patterns:
1. **Use your purchased public domain internally** (recommended, enables split-horizon)
   - `grafana.<your-domain>`
   - `neo4j.<your-domain>`
2. Use a dedicated internal-only subdomain (still under your public domain):
   - `grafana.int.<your-domain>`
   - `neo4j.int.<your-domain>`

**Where internal records live**
- Pi-hole “Local DNS” records for lab VLAN
- Optionally, UDM static DNS records for a tiny set of household-friendly names

---

### 4.3 Layer 3 — Public DNS (Internet-facing)

Public hostnames under your domain, managed in Cloudflare DNS:
- `grafana.<your-domain>`
- `neo4j.<your-domain>`
- `status.<your-domain>`
- etc.

These resolve to Cloudflare Tunnel endpoints.

---

## 5. Split-Horizon DNS (Recommended)

### 5.1 How it Works

- Externally:
  - `grafana.<your-domain>` → Cloudflare (Tunnel)
- Internally:
  - `grafana.<your-domain>` → **internal service IP** (direct, fast, no hairpin)
- Same hostname works everywhere; only DNS answer differs based on “where you are”.

### 5.2 Where to Implement Overrides

**Option A (recommended): Pi-hole overrides**
- Pi-hole provides overrides to lab VLAN and server VLAN.
- Family VLAN does not depend on Pi-hole.

**Option B: UDM host records for household**
- If you only need a few household internal names, add them in UniFi.
- Keep Pi-hole as lab-only.

---

## 6. Solution Choices (with Pros/Cons)

### 6.1 External Access Options

#### Option 1 — Traditional Port Forwarding + Reverse Proxy on LAN
**Pros**
- No dependency on third-party tunnel
- Works for many protocols if you set it up carefully
- Full control of edge

**Cons**
- Opens inbound ports (constant internet scanning)
- TLS/cert lifecycle complexity
- Requires router/NAT, DDNS, firewall hardening
- Larger attack surface; more maintenance

**Fit for Colossus**
- Conflicts with “boring, rebuildable” unless you invest heavily in edge hardening.
- Not recommended as primary approach.

---

#### Option 2 — VPN (WireGuard/OpenVPN) to Home, No Public Apps
**Pros**
- Very secure, minimal public exposure
- Simple once set up
- No need for public domain (though helpful)

**Cons**
- Not friendly for sharing with others
- Not great for “web apps accessible anywhere” UX
- Mobile clients sometimes finicky

**Fit for Colossus**
- Good as a **secondary** admin access method (recommended to keep anyway).

---

#### Option 3 — Cloudflare Tunnel (Recommended)
**Pros**
- No inbound ports
- Great TLS story (automatic)
- Strong auth with Cloudflare Access
- Handles dynamic IP and CGNAT
- Easy rollback/rebuild: replace a container and config

**Cons**
- Third-party dependency
- Some protocol limitations (primarily HTTP(S) is easiest)
- Need a domain (small yearly cost)
- Must understand Access policies to avoid exposing sensitive apps

**Fit for Colossus**
- Best match to the documented “infra should be boring, scriptable, rebuildable” rules fileciteturn0file0.

---

### 6.2 Internal DNS Options (Family + Lab Separation)

#### Option A — Whole-house Pi-hole
**Pros**
- Network-wide filtering and logging
- Single DNS policy

**Cons**
- Household outage risk when Pi-hole is down/restarted
- “Why can’t I reach X site?” support burden
- Adds pressure during lab experiments

**Fit**
- Not recommended given your evolving lab and desire for stability.

---

#### Option B — Split DNS by VLAN (Recommended)
**Pros**
- Family network stays appliance-stable (UDM DNS)
- Lab network gets visibility/control (Pi-hole)
- Easy troubleshooting boundaries
- Aligns with role separation and “don’t break the house”

**Cons**
- Slightly more network config (per-VLAN DHCP DNS)
- You must be disciplined about which VLAN a device is on

**Fit**
- Best for Colossus.

---

#### Option C — UDM-only DNS + small host overrides
**Pros**
- Very simple; fewer services
- No Pi-hole dependency

**Cons**
- Less control/logging for lab
- Not ideal as lab grows

**Fit**
- Works for household-only names; not enough for the lab long-term.

---

## 7. Recommended Target Architecture

### 7.1 Network Segmentation (Illustrative)

- VLAN 10 — Family/Trusted: DNS = UDM (or ISP/1.1.1.1)
- VLAN 20 — Servers/Lab: DNS = Pi-hole
- VLAN 30 — IoT (optional): DNS = Pi-hole + “force DNS” firewall rules
- VLAN 40 — Guest: DNS = UDM/ISP

*(Your actual VLAN IDs can differ; the design intent remains.)*

---

### 7.2 Placement by Node Role

Per Colossus roles fileciteturn0file0:

- **pve-3 (Infra/Services)**  
  - PBS (already)  
  - **Pi-hole**  
  - **Edge VM running cloudflared**  
  - (Optional) monitoring ingress / uptime checks

- pve-1 (Prod workloads)  
  - Production app VMs and containers

- pve-2 (Dev workloads)  
  - Development app VMs and containers

---

### 7.3 Edge VM Responsibility Boundary (colossus-edge1)

**Runs**
- cloudflared (Tunnel connector)

**Does NOT run**
- databases
- core app services
- experimental workloads

**Data persistence**
- Minimal: config + credentials only
- Store config in version control; store credentials securely offline.

---

## 8. Security Model

### 8.1 Public Exposure Rule

- No direct public exposure of internal services.
- All internet access must go through Cloudflare edge (TLS + policy).

### 8.2 Cloudflare Access Policies (Recommended Defaults)

For each hostname/app:
- Require authentication (email/SSO/OTP)
- Restrict to your email domain or allowlist of users
- Optionally restrict by country/ASN/IP

For API-like endpoints:
- Prefer service tokens (machine-to-machine) vs human login.

### 8.3 Internal Firewall Rules (Recommended)

- Allow required VLANs → Pi-hole (UDP/TCP 53)
- Optionally block IoT VLAN from reaching external DNS servers directly (force through Pi-hole)
- Keep management interfaces (Proxmox UI, PBS UI) **not** exposed via tunnel unless absolutely required, and if exposed, require strong Access policies.

---

## 9. Reliability + DR

### 9.1 Single Points of Failure

- If cloudflared is down: external access fails (internal still works).
- If Pi-hole is down: lab DNS fails (family unaffected).

### 9.2 Planned Upgrades (Optional, later)

- Add second Pi-hole for lab HA (primary/secondary DNS in lab VLAN)
- Add second cloudflared connector (Cloudflare supports multiple connectors per tunnel) for redundancy if needed
- Keep a VPN (WireGuard) as break-glass admin access

---

## 10. Operational Standards (Colossus-style)

- All “edge services” should be:
  - VM-defined by script (qm)
  - configured via Butane/Ignition (for CoreOS standardization, if chosen)
  - container lifecycle controlled by systemd (Quadlet preferred)
- Store runbooks and configs in a `docs/edge/` directory in your repo or homelab configuration repo.
- Avoid click-ops: document UI-only steps where unavoidable (Cloudflare dashboard), but capture them as checklist steps.

---

## 11. Acceptance Criteria

This design is complete when:

1. Proxmox cluster remains stable (no hostname changes).
2. Family VLAN internet works even if Pi-hole is offline.
3. Lab VLAN uses Pi-hole for DNS and resolves internal service names.
4. A chosen external hostname (e.g., `grafana.<domain>`) is reachable from the internet via Cloudflare Tunnel and protected by Cloudflare Access.
5. The same hostname resolves internally via split-horizon override to the internal IP (no hairpin; direct LAN).
6. A documented rollback path exists (disable tunnel + revert DNS override).

---

## 12. Appendices

### 12.1 Suggested Naming Conventions (Services)

- Use public domain for services: `service.<domain>`
- Use environment prefixes only if needed:
  - `grafana-dev.<domain>`
  - `grafana-prod.<domain>`

Avoid putting Proxmox node names into these hostnames; keep node identity separate from service identity.

### 12.2 “Do Not Do” List (Proxmox Safety)

- Do not rename Proxmox nodes.
- Do not change `pve-*.local` to another suffix.
- Do not rely on DNS changes for corosync resolution unless already designed for it (typically /etc/hosts is authoritative).
- Treat Proxmox node naming as immutable.
