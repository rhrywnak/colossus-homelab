# Colossus Homelab — Traefik Reverse Proxy Design v1.0

**Date:** February 12, 2026  
**Phase:** 5A — Internal Reverse Proxy & TLS  
**Status:** Design — Pending Execution  
**Author:** Claude + Roman

---

## 1. Problem Statement

The Colossus homelab currently routes internal traffic by direct IP and port:

```
Browser → http://10.10.100.120:5473   (frontend)
Browser → http://10.10.100.120:3403   (backend API)
```

This creates three problems that worsen as more applications are added:

1. **No internal TLS** — All LAN traffic is plaintext HTTP. The PROD frontend fetches from `https://colossus-legal-api.cogmai.com` (via Cloudflare Tunnel) even on LAN because there is no local HTTPS endpoint. Pi-hole split-horizon DNS resolves to the internal IP, but the browser still expects HTTPS.

2. **Port proliferation** — Each new application means new ports to memorize and new Pi-hole records. At 5+ apps, this becomes unmanageable.

3. **No unified entry point** — External traffic goes through Cloudflare Tunnel → CT-312, but internal traffic hits VMs directly. There is no single place to enforce routing policy, TLS, or access control for LAN users.

---

## 2. Solution: Traefik as Internal Reverse Proxy

Traefik v3 deployed as an LXC container on pve-3, providing:

- **Wildcard TLS** for `*.cogmai.com` via Let's Encrypt + Cloudflare DNS challenge
- **Hostname-based routing** — all services accessed by name (e.g., `colossus-legal.cogmai.com`)
- **Single HTTPS entry point** on ports 80/443
- **File provider** for routing to services on remote VMs (no Docker socket needed)
- **Dashboard** for operational visibility

### 2.1 Architecture Overview

```
                        ┌─────────────────────────────┐
                        │       INTERNET               │
                        └──────────┬──────────────────┘
                                   │
                        ┌──────────▼──────────────────┐
                        │  Cloudflare Edge (CDN/WAF)   │
                        │  + Cloudflare Access (OTP)   │
                        └──────────┬──────────────────┘
                                   │ Tunnel
                        ┌──────────▼──────────────────┐
                        │  CT-312 cloudflared          │
                        │  10.10.100.54                │
                        └──────────┬──────────────────┘
                                   │ HTTP forward
          ┌────────────────────────▼─────────────────────────┐
          │              CT-313 Traefik (NEW)                 │
          │              10.10.100.55                         │
          │                                                   │
          │  :443 (HTTPS) ← LAN clients                      │
          │  :80  (HTTP)  ← redirect to HTTPS                │
          │  :80  (HTTP)  ← cloudflared forwards here        │
          │  :8080        ← Dashboard (LAN only)             │
          │                                                   │
          │  TLS: *.cogmai.com (Let's Encrypt wildcard)      │
          │  Provider: File (dynamic/services.yml)            │
          └───┬─────────────┬──────────────┬─────────────────┘
              │             │              │
    ┌─────────▼───┐  ┌─────▼─────┐  ┌─────▼──────┐
    │  VM-120     │  │  VM-220   │  │  Future    │
    │  PROD App   │  │  DEV App  │  │  Services  │
    │  pve-1      │  │  pve-2    │  │  ...       │
    └─────────────┘  └───────────┘  └────────────┘
```

### 2.2 Traffic Flow — External (Phone/Remote)

```
Phone → colossus-legal.cogmai.com
  → Cloudflare Edge (Access OTP check)
  → Cloudflare Tunnel → CT-312 (cloudflared)
  → CT-313 Traefik :80 (HTTP from tunnel)
  → Route: Host(`colossus-legal.cogmai.com`) → http://10.10.100.120:5473
```

### 2.3 Traffic Flow — Internal (Workstation/LAN)

```
Workstation → https://colossus-legal.cogmai.com
  → Pi-hole DNS → 10.10.100.55 (Traefik)
  → CT-313 Traefik :443 (HTTPS, valid LE wildcard cert)
  → Route: Host(`colossus-legal.cogmai.com`) → http://10.10.100.120:5473
```

**Key improvement:** LAN browsers now get a valid HTTPS certificate for `*.cogmai.com`. No more mixed-content warnings, no more needing the Cloudflare Tunnel for LAN access.

---

## 3. Container Specification

### 3.1 CT-313 — Traefik

| Property | Value |
|----------|-------|
| **CTID** | 313 |
| **Hostname** | traefik |
| **Node** | pve-3 |
| **IP** | 10.10.100.55/24 |
| **Gateway** | 10.10.100.1 |
| **Template** | debian-12-standard (from pve-3 local) |
| **Disk** | 4 GB (on local-zfs) |
| **RAM** | 256 MB |
| **Swap** | 256 MB |
| **CPU** | 1 core |
| **Network** | vmbr0, VLAN-aware |
| **Unprivileged** | Yes |
| **Nesting** | No |
| **Start on boot** | Yes |

### 3.2 Resource Justification

Traefik is a single Go binary (~50MB). In steady state with file provider (no Docker socket), memory usage is typically 30–80MB. The 256MB allocation provides generous headroom for certificate operations and log buffering.

---

## 4. TLS Certificate Strategy

### 4.1 Wildcard Certificate via Let's Encrypt

Traefik will request a wildcard certificate for `*.cogmai.com` plus the apex `cogmai.com` using the ACME DNS-01 challenge with Cloudflare as the DNS provider.

**How DNS-01 challenge works:**

1. Traefik asks Let's Encrypt: "I want a cert for *.cogmai.com"
2. Let's Encrypt says: "Prove you own cogmai.com — create a TXT record `_acme-challenge.cogmai.com` with this value"
3. Traefik uses the Cloudflare API to create the TXT record
4. Let's Encrypt verifies the record and issues the certificate
5. Traefik stores the cert in `acme.json` and serves it for all `*.cogmai.com` requests
6. Traefik auto-renews when <30 days remain (certs are valid 90 days)

**Why DNS-01 (not HTTP-01):**
- HTTP-01 requires Let's Encrypt to reach your server on port 80 from the internet — not possible behind Cloudflare Tunnel without extra plumbing
- DNS-01 works entirely via API — no inbound connections needed
- DNS-01 is the *only* method that supports wildcard certs

### 4.2 Cloudflare API Token

A scoped API token is needed with:
- **Permission:** Zone → DNS → Edit
- **Zone resource:** Include → Specific zone → cogmai.com

This token can ONLY modify DNS records for cogmai.com. It cannot modify firewall rules, tunnel configs, or any other Cloudflare settings.

**Create at:** Cloudflare Dashboard → My Profile → API Tokens → Create Token → "Edit zone DNS" template

---

## 5. Traefik Configuration

### 5.1 Static Configuration (traefik.yml)

The static configuration defines entry points, providers, and certificate resolvers. It is read once at startup.

```yaml
# /etc/traefik/traefik.yml

api:
  dashboard: true
  insecure: true       # Dashboard on :8080 without TLS (LAN-only access)

entryPoints:
  http:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: https
          scheme: https
  https:
    address: ":443"
    http:
      tls: {}

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true         # Hot-reload when files change

certificatesResolvers:
  letsencrypt:
    acme:
      email: "Roman.hrywnak@gmail.com"   # CHANGEME: your actual email
      storage: /etc/traefik/acme.json
      caServer: "https://acme-v02.api.letsencrypt.org/directory"
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"

log:
  level: INFO
  filePath: /var/log/traefik/traefik.log

accessLog:
  filePath: /var/log/traefik/access.log
```

**Important notes:**

- The `http` entry point auto-redirects to `https`. This ensures LAN clients always use TLS.
- The exception: cloudflared forwards traffic on HTTP (since the tunnel already encrypted it). We handle this with a dedicated entrypoint or by having cloudflared target Traefik's HTTP port before the redirect fires. See Section 6 for the Cloudflare Tunnel integration details.
- `watch: true` on the file provider means adding a new service is as simple as editing a YAML file — no Traefik restart needed.

### 5.2 Dynamic Configuration — TLS (dynamic/tls.yml)

```yaml
# /etc/traefik/dynamic/tls.yml

tls:
  stores:
    default:
      defaultCertificate: {}   # Uses the ACME cert as default

  options:
    default:
      minVersion: VersionTLS12
      snatCertificates: false
```

### 5.3 Dynamic Configuration — Services (dynamic/services.yml)

This is where backend services are defined. Each service maps a hostname to a backend IP:port. Adding a new app = adding a new router+service block here.

```yaml
# /etc/traefik/dynamic/services.yml

http:
  routers:
    # --- Colossus-Legal Frontend (PROD) ---
    colossus-legal-frontend:
      rule: "Host(`colossus-legal.cogmai.com`)"
      entryPoints:
        - https
      service: colossus-legal-frontend
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

    # --- Colossus-Legal API (PROD) ---
    colossus-legal-api:
      rule: "Host(`colossus-legal-api.cogmai.com`)"
      entryPoints:
        - https
      service: colossus-legal-api
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

    # --- Colossus-Legal Frontend (DEV) ---
    colossus-legal-dev:
      rule: "Host(`colossus-legal-dev.cogmai.com`)"
      entryPoints:
        - https
      service: colossus-legal-dev
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

    # --- Colossus-Legal API (DEV) ---
    colossus-legal-api-dev:
      rule: "Host(`colossus-legal-api-dev.cogmai.com`)"
      entryPoints:
        - https
      service: colossus-legal-api-dev
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

    # --- Traefik Dashboard ---
    traefik-dashboard:
      rule: "Host(`traefik.cogmai.com`)"
      entryPoints:
        - https
      service: api@internal
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

  services:
    colossus-legal-frontend:
      loadBalancer:
        servers:
          - url: "http://10.10.100.120:5473"

    colossus-legal-api:
      loadBalancer:
        servers:
          - url: "http://10.10.100.120:3403"

    colossus-legal-dev:
      loadBalancer:
        servers:
          - url: "http://10.10.100.220:5473"

    colossus-legal-api-dev:
      loadBalancer:
        servers:
          - url: "http://10.10.100.220:3403"
```

### 5.4 Adding a New Application

When you deploy a new app, you only need to:

1. Add a router + service block to `dynamic/services.yml`
2. Add a Pi-hole DNS CNAME or A record pointing `newapp.cogmai.com` → `10.10.100.55`
3. (Optional) Add a Cloudflare Tunnel route if external access is needed

Traefik picks up the config change automatically (file watch). No restart, no certificate provisioning — the wildcard cert already covers `*.cogmai.com`.

---

## 6. Cloudflare Tunnel Integration

### 6.1 Current Architecture

Today, CT-312 (cloudflared) points directly at the backend services:

```
colossus-legal.cogmai.com     → http://10.10.100.120:5473
colossus-legal-api.cogmai.com → http://10.10.100.120:3403
```

### 6.2 Updated Architecture

After Traefik deployment, cloudflared should route through Traefik instead:

```
colossus-legal.cogmai.com     → http://10.10.100.55:80
colossus-legal-api.cogmai.com → http://10.10.100.55:80
```

Traefik receives the request, inspects the `Host` header, and forwards to the correct backend. This means:

- **One target for all tunnel routes** — cloudflared always forwards to Traefik
- **Routing logic lives in one place** — Traefik's dynamic config
- **Adding new external services** requires only a Cloudflare Tunnel route + Traefik router (no cloudflared config change if using catch-all)

### 6.3 HTTP Redirect Exception

The static config redirects all HTTP → HTTPS. But cloudflared sends requests as HTTP (the Cloudflare edge already handles external TLS). We need to prevent the redirect loop for tunnel traffic.

**Solution:** cloudflared should target Traefik's HTTPS port with TLS verification disabled, OR we configure a separate HTTP entrypoint for tunnel traffic. The simplest approach:

- Update cloudflared tunnel config to point to `https://10.10.100.55:443` with `noTLSVerify: true` (or `originServerName: colossus-legal.cogmai.com` for cert validation)
- Traefik serves the Let's Encrypt wildcard cert
- No redirect loop — traffic arrives on HTTPS directly

Alternatively, keep HTTP targets and add a `X-Forwarded-Proto` trust rule so Traefik doesn't redirect already-tunneled traffic. The HTTPS approach is cleaner.

---

## 7. Pi-hole DNS Changes

### 7.1 Current Split-Horizon Records

```
colossus-legal.cogmai.com     → 10.10.100.120  (direct to PROD app)
colossus-legal-api.cogmai.com → 10.10.100.120  (direct to PROD API)
```

### 7.2 Updated Records

All `*.cogmai.com` internal traffic should route to Traefik:

```
colossus-legal.cogmai.com      → 10.10.100.55  (Traefik)
colossus-legal-api.cogmai.com  → 10.10.100.55  (Traefik)
colossus-legal-dev.cogmai.com  → 10.10.100.55  (Traefik)
colossus-legal-api-dev.cogmai.com → 10.10.100.55  (Traefik)
traefik.cogmai.com             → 10.10.100.55  (Traefik dashboard)
```

**Future pattern:** Every new app gets a single Pi-hole record pointing to Traefik. Traefik handles the routing from there.

**Alternative:** A single wildcard record in Pi-hole (`*.cogmai.com` → `10.10.100.55`) would route everything to Traefik. However, Pi-hole does not natively support wildcard DNS records in Local DNS. You would need a dnsmasq custom config (`address=/cogmai.com/10.10.100.55`). This is optional — individual records work fine and are more explicit.

---

## 8. Impact on Existing Configuration

### 8.1 Frontend Environment Variable

**Current (VM-120 PROD):**
```
COLOSSUS_API_URL=https://colossus-legal-api.cogmai.com
```

**After Traefik:** No change needed. The frontend already uses the `cogmai.com` hostname. The difference is that internal browsers now resolve this to Traefik (which serves a valid LE cert) instead of going through Cloudflare Tunnel. The URL stays the same.

### 8.2 Backend CORS

**Current (VM-120 PROD):**
```
CORS_ALLOWED_ORIGINS=http://10.10.100.120:5473,http://localhost:5473,https://colossus-legal.cogmai.com
```

**After Traefik:** No change needed. The `https://colossus-legal.cogmai.com` origin is already in the list. Internal users accessing via that hostname will match.

### 8.3 DEV Environment

Currently the DEV environment uses direct IP URLs. After Traefik:

**VM-220 frontend.env:**
```
COLOSSUS_API_URL=https://colossus-legal-api-dev.cogmai.com
```

**VM-220 backend.env:**
```
CORS_ALLOWED_ORIGINS=http://10.10.100.220:5473,http://localhost:5473,https://colossus-legal-dev.cogmai.com
```

This gives DEV the same HTTPS experience as PROD, accessed via `colossus-legal-dev.cogmai.com`.

---

## 9. Security Considerations

### 9.1 Dashboard Access

The Traefik dashboard exposes routing configuration and service health. It should NOT be externally accessible.

- Dashboard runs on `:8080` (insecure mode, no TLS)
- No Cloudflare Tunnel route for `traefik.cogmai.com`
- Accessible only from LAN via Pi-hole DNS
- Optional: add basic auth middleware for additional protection

### 9.2 Cloudflare API Token Scope

The token used for DNS-01 challenge is narrowly scoped:
- Can only edit DNS records for cogmai.com zone
- Cannot modify any other Cloudflare settings
- Stored in `/etc/traefik/cloudflare-token.env` with `chmod 600`

### 9.3 Certificate Storage

`acme.json` contains the private key for the wildcard cert. It must be:
- Owned by root
- Permissions: `600`
- Not exposed to other containers or users

---

## 10. Execution Plan

### Step 1: Create Cloudflare API Token
- Cloudflare Dashboard → My Profile → API Tokens
- Use "Edit zone DNS" template
- Scope to cogmai.com zone only
- Save token securely

### Step 2: Create CT-313 on pve-3
- Download Debian 12 template if not present
- Create unprivileged LXC (4GB disk, 256MB RAM, 1 CPU)
- Configure static IP 10.10.100.55/24

### Step 3: Install Traefik in CT-313
- Install Traefik v3 binary (from GitHub releases or apt)
- Create directory structure:
  ```
  /etc/traefik/
  ├── traefik.yml              (static config)
  ├── acme.json                (certificate storage, chmod 600)
  ├── cloudflare-token.env     (API token, chmod 600)
  └── dynamic/
      ├── tls.yml              (TLS options)
      └── services.yml         (routers + services)
  /var/log/traefik/
  ├── traefik.log
  └── access.log
  ```
- Create systemd service for Traefik
- Test: `curl -I https://colossus-legal.cogmai.com` from Traefik container (should get LE cert)

### Step 4: Update Pi-hole DNS
- Change existing records from direct IPs to Traefik IP (10.10.100.55)
- Add new records for DEV and dashboard

### Step 5: Update Cloudflare Tunnel
- Modify cloudflared tunnel routes to target Traefik
- Test external access via phone (cellular)

### Step 6: Test & Validate
- LAN: Browse to `https://colossus-legal.cogmai.com` — verify valid LE cert, no warnings
- LAN: Browse to `https://colossus-legal-dev.cogmai.com` — verify DEV access
- External: Browse from phone — verify Cloudflare Access OTP + app loads
- Dashboard: Browse to `http://traefik.cogmai.com:8080` — verify routing table

### Step 7: Update DEV Environment (VM-220)
- Update `frontend.env` with `https://colossus-legal-api-dev.cogmai.com`
- Update `backend.env` CORS with `https://colossus-legal-dev.cogmai.com`
- Restart containers

### Step 8: PBS Backup
- Back up CT-313 to PBS
- Comment: `Phase 5A - Traefik reverse proxy`

### Step 9: Update Butane Files
- Update PROD and DEV `.bu` files to reflect any environment variable changes

---

## 11. Future-Proofing: Adding New Applications

Once Traefik is running, deploying a new app behind it follows this pattern:

```
1. Deploy app container on target VM (e.g., VM-120 or a new VM)
2. Add router + service to /etc/traefik/dynamic/services.yml:

   routers:
     my-new-app:
       rule: "Host(`newapp.cogmai.com`)"
       entryPoints: [https]
       service: my-new-app
       tls:
         certResolver: letsencrypt
         domains:
           - main: "*.cogmai.com"

   services:
     my-new-app:
       loadBalancer:
         servers:
           - url: "http://10.10.100.xxx:port"

3. Add Pi-hole record: newapp.cogmai.com → 10.10.100.55
4. (Optional) Add Cloudflare Tunnel route for external access
5. (Optional) Add Cloudflare Access policy for authentication
```

Time to add a new service: ~5 minutes. No Traefik restart. No certificate provisioning.

---

## 12. Updated Infrastructure Inventory

| VMID | Name | Node | IP | Role | Status |
|------|------|------|----|------|--------|
| 110 | colossus-prod-db1 | pve-1 | 10.10.100.110 | PROD DB | Running |
| 120 | colossus-prod-app1 | pve-1 | 10.10.100.120 | PROD App | Running |
| 200 | colossus-db1-dev | pve-2 | 10.10.100.50 | Frozen reference | Running |
| 210 | colossus-dev-db1 | pve-2 | 10.10.100.200 | DEV DB | Running |
| 220 | colossus-dev-app1 | pve-2 | 10.10.100.220 | DEV App | Running |
| 311 | pihole | pve-3 | 10.10.100.53 | Pi-hole DNS (LXC) | Running |
| 312 | cloudflared | pve-3 | 10.10.100.54 | Cloudflare Tunnel (LXC) | Running |
| **313** | **traefik** | **pve-3** | **10.10.100.55** | **Reverse Proxy (LXC)** | **Planned** |
| 900 | PBS | pve-3 | — | Proxmox Backup Server | Running |

---

## 13. pve-3 Services Summary

```
pve-3 (Infrastructure / Services Node)
├── VM-900   PBS (Proxmox Backup Server)
├── CT-311   Pi-hole (DNS resolution, split-horizon)
├── CT-312   cloudflared (Cloudflare Tunnel, external access)
└── CT-313   Traefik (reverse proxy, TLS termination, routing)  ← NEW
```

These four services form the infrastructure backbone: backup, DNS, external connectivity, and internal routing. All are lightweight and fit comfortably on pve-3 alongside the other workloads.
