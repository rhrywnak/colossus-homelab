# Phase 5A — Traefik Reverse Proxy Execution Runbook v1.0

**Date:** February 12, 2026  
**Companion:** `COLOSSUS_TRAEFIK_DESIGN_v1.md`  
**Estimated time:** 45–60 minutes

---

## PRE-FLIGHT (MUST ALL BE TRUE)

- [ ] Phase 4 complete (app deployed, Cloudflare Access configured, PBS backups done)
- [ ] Cloudflare dashboard access available
- [ ] Proxmox web UI accessible on pve-3 (`https://10.10.100.5:8006`)
- [ ] Pi-hole admin accessible (`http://10.10.100.53/admin`)
- [ ] SSH access to CT-312 (cloudflared) working
- [ ] Colossus-Legal PROD currently functional at `https://colossus-legal.cogmai.com`

---

## STEP 1 — Create Cloudflare API Token

**Where:** Cloudflare Dashboard (browser)

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Click **Create Token**
3. Find **Edit zone DNS** template → click **Use template**
4. Configure:
   - **Token name:** `Traefik ACME - cogmai.com`
   - **Permissions:** Zone → DNS → Edit (should be pre-filled)
   - **Zone Resources:** Include → Specific zone → `cogmai.com`
5. Click **Continue to summary** → **Create Token**
6. **Copy the token immediately** — you won't see it again
7. Save it somewhere secure (Bitwarden, etc.)

**Validation:**
- [ ] Token created and saved
- [ ] Token scoped to cogmai.com DNS only

---

## STEP 2 — Create CT-313 LXC on pve-3

**Where:** Proxmox web UI → pve-3

### 2a. Download Debian 12 template (if not already present)

1. pve-3 → local (storage) → CT Templates → Templates
2. Search for `debian-12-standard`
3. Download if not present

### 2b. Create LXC container

1. pve-3 → **Create CT** (top right button)
2. **General tab:**
   - CT ID: `313`
   - Hostname: `traefik`
   - Password: set a root password
   - Unprivileged: ✅ Yes
3. **Template tab:**
   - Storage: `local`
   - Template: `debian-12-standard`
4. **Disks tab:**
   - Storage: `local-zfs`
   - Disk size: `4` GB
5. **CPU tab:**
   - Cores: `1`
6. **Memory tab:**
   - Memory: `256` MB
   - Swap: `256` MB
7. **Network tab:**
   - Name: `eth0`
   - Bridge: `vmbr0`
   - IPv4: Static
   - IPv4/CIDR: `10.10.100.55/24`
   - Gateway: `10.10.100.1`
8. **DNS tab:**
   - DNS domain: (leave default)
   - DNS server: `10.10.100.53` (Pi-hole)
9. Click **Finish**

### 2c. Configure start on boot

1. Select CT-313 → Options → Start at boot → Edit → ✅ Yes

### 2d. Start the container

1. Select CT-313 → Start

**Validation:**
- [ ] CT-313 created and running
- [ ] `ping 10.10.100.55` from workstation succeeds
- [ ] `ping 10.10.100.1` from CT-313 console succeeds (gateway reachable)
- [ ] `ping 1.1.1.1` from CT-313 console succeeds (internet reachable)

---

## STEP 3 — Install Traefik in CT-313

**Where:** CT-313 shell (Proxmox console or SSH)

### 3a. System update and prerequisites

```bash
apt update && apt upgrade -y
apt install -y curl wget gnupg2 ca-certificates
```

### 3b. Install Traefik v3 binary

```bash
# Check latest v3 release at https://github.com/traefik/traefik/releases
# Substitute version as needed
TRAEFIK_VERSION="v3.3.3"

wget -q "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_${TRAEFIK_VERSION}_linux_amd64.tar.gz" \
  -O /tmp/traefik.tar.gz

tar -xzf /tmp/traefik.tar.gz -C /usr/local/bin/ traefik
chmod +x /usr/local/bin/traefik
rm /tmp/traefik.tar.gz

# Verify
traefik version
```

### 3c. Create directory structure

```bash
mkdir -p /etc/traefik/dynamic
mkdir -p /var/log/traefik

# Create empty acme.json with strict permissions
touch /etc/traefik/acme.json
chmod 600 /etc/traefik/acme.json
```

### 3d. Create Cloudflare token environment file

```bash
cat > /etc/traefik/cloudflare.env << 'EOF'
CF_DNS_API_TOKEN=PASTE_YOUR_TOKEN_HERE
EOF

chmod 600 /etc/traefik/cloudflare.env
```

⚠️ **Replace `PASTE_YOUR_TOKEN_HERE` with the actual token from Step 1.**

**Validation:**
- [ ] `traefik version` shows v3.x.x
- [ ] `/etc/traefik/acme.json` exists with permissions `600`
- [ ] `/etc/traefik/cloudflare.env` exists with permissions `600` and contains your token
- [ ] `/etc/traefik/dynamic/` directory exists
- [ ] `/var/log/traefik/` directory exists

---

## STEP 4 — Create Traefik Configuration Files

**Where:** CT-313 shell

### 4a. Static configuration

```bash
cat > /etc/traefik/traefik.yml << 'EOF'
api:
  dashboard: true
  insecure: true

entryPoints:
  http:
    address: ":80"
  https:
    address: ":443"
    http:
      tls: {}

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: "Roman.hrywnak@gmail.com"
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
EOF
```

> **Note on email:** Replace with your actual email if different. Let's Encrypt uses this for expiration warnings (they email you if auto-renewal fails).

> **Note on HTTP redirect:** We are NOT enabling the global HTTP→HTTPS redirect in static config. Reason: cloudflared forwards to Traefik on HTTP. If we redirect all HTTP, tunnel traffic gets a redirect loop. Instead, we handle the redirect per-router in the dynamic config (LAN-facing routers only). See Step 4c.

### 4b. Dynamic TLS configuration

```bash
cat > /etc/traefik/dynamic/tls.yml << 'EOF'
tls:
  options:
    default:
      minVersion: VersionTLS12
EOF
```

### 4c. Dynamic services configuration

```bash
cat > /etc/traefik/dynamic/services.yml << 'EOF'
http:
  # ============================================================
  # MIDDLEWARES
  # ============================================================
  middlewares:
    # Redirect HTTP to HTTPS (applied to LAN-facing routers only)
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true

  # ============================================================
  # ROUTERS
  # ============================================================
  routers:

    # --- HTTP catch-all: redirect LAN browsers to HTTPS ---
    http-catchall:
      rule: "HostRegexp(`.+`)"
      entryPoints:
        - http
      middlewares:
        - redirect-to-https
      service: noop@internal
      priority: 1

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

    # --- Traefik Dashboard (HTTPS via LAN) ---
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

  # ============================================================
  # SERVICES (backend targets)
  # ============================================================
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
EOF
```

### 4d. Verify config file syntax

```bash
# Quick YAML syntax check — Traefik will also validate on startup
traefik healthcheck --configFile=/etc/traefik/traefik.yml 2>&1 || echo "Will validate on first start"
```

**Validation:**
- [ ] `/etc/traefik/traefik.yml` created
- [ ] `/etc/traefik/dynamic/tls.yml` created
- [ ] `/etc/traefik/dynamic/services.yml` created
- [ ] All three files have correct content (review with `cat`)

---

## STEP 5 — Create Systemd Service and Start Traefik

**Where:** CT-313 shell

### 5a. Create systemd unit

```bash
cat > /etc/systemd/system/traefik.service << 'EOF'
[Unit]
Description=Traefik Reverse Proxy
Documentation=https://doc.traefik.io/traefik/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=/etc/traefik/cloudflare.env
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/traefik/acme.json /var/log/traefik

[Install]
WantedBy=multi-user.target
EOF
```

### 5b. Enable and start

```bash
systemctl daemon-reload
systemctl enable traefik
systemctl start traefik
```

### 5c. Check status and logs

```bash
# Service status
systemctl status traefik

# Check for errors (certificate request takes 10-30 seconds)
journalctl -u traefik -f --no-pager
```

**What to look for in logs:**
- `"Configuration loaded from file"` — static config loaded
- `"Starting provider *file.Provider"` — file provider active
- `"legolog: [INFO] [*.cogmai.com] acme: Obtaining bundled SAN certificate"` — cert request started
- `"legolog: [INFO] [*.cogmai.com] The server validated our request"` — DNS challenge passed
- `"legolog: [INFO] [*.cogmai.com] Server responded with a certificate"` — cert issued ✅

**If you see DNS challenge errors:** Double-check the token in `/etc/traefik/cloudflare.env` and ensure it has DNS Edit permission for the cogmai.com zone.

### 5d. Verify certificate was obtained

```bash
# Check acme.json is populated (should be >1KB after cert issuance)
ls -la /etc/traefik/acme.json

# Test TLS locally (will fail name resolution but confirms cert exists)
curl -k https://127.0.0.1 -H "Host: colossus-legal.cogmai.com" -v 2>&1 | grep "subject:"
```

**Validation:**
- [ ] `systemctl status traefik` shows `active (running)`
- [ ] No errors in `journalctl -u traefik`
- [ ] Certificate obtained (acme.json > 1KB)
- [ ] Dashboard accessible: `curl -s http://127.0.0.1:8080/api/overview | head`

---

## STEP 6 — Update Pi-hole DNS Records

**Where:** Pi-hole admin UI (`http://10.10.100.53/admin`)

### 6a. Update existing records

Go to **Local DNS → DNS Records**

**Change these existing records** (delete old, add new):

| Domain | Old IP | New IP |
|--------|--------|--------|
| `colossus-legal.cogmai.com` | `10.10.100.120` | `10.10.100.55` |
| `colossus-legal-api.cogmai.com` | `10.10.100.120` | `10.10.100.55` |

### 6b. Add new records

| Domain | IP | Purpose |
|--------|------|---------|
| `colossus-legal-dev.cogmai.com` | `10.10.100.55` | DEV frontend via Traefik |
| `colossus-legal-api-dev.cogmai.com` | `10.10.100.55` | DEV API via Traefik |
| `traefik.cogmai.com` | `10.10.100.55` | Traefik dashboard |

### 6c. Flush DNS on workstation

```bash
# Linux
sudo resolvectl flush-caches

# Or restart network
sudo systemctl restart NetworkManager
```

**Validation:**
- [ ] `nslookup colossus-legal.cogmai.com 10.10.100.53` returns `10.10.100.55`
- [ ] `nslookup colossus-legal-api.cogmai.com 10.10.100.53` returns `10.10.100.55`
- [ ] `nslookup colossus-legal-dev.cogmai.com 10.10.100.53` returns `10.10.100.55`
- [ ] `nslookup traefik.cogmai.com 10.10.100.53` returns `10.10.100.55`

---

## STEP 7 — Test Internal (LAN) Access

**Where:** Workstation browser

### 7a. Test PROD frontend

1. Browse to `https://colossus-legal.cogmai.com`
2. Check for valid certificate (padlock icon, no warnings)
3. Click padlock → Certificate → verify issuer is "R11" or "R10" (Let's Encrypt)
4. Verify the app loads and functions normally

### 7b. Test PROD API

```bash
curl -s https://colossus-legal-api.cogmai.com/api/health
```

Should return a response (or connection) without TLS errors.

### 7c. Test DEV frontend

1. Browse to `https://colossus-legal-dev.cogmai.com`
2. Verify valid certificate and app loads

### 7d. Test Dashboard

1. Browse to `https://traefik.cogmai.com`
2. Should show the Traefik dashboard with all routers and services listed
3. Verify all services show green status

**Validation:**
- [ ] PROD frontend loads with valid HTTPS cert
- [ ] PROD API responds via HTTPS
- [ ] DEV frontend loads with valid HTTPS cert
- [ ] Traefik dashboard shows all routers and services

**⚠️ STOP HERE if internal access fails.** Fix before proceeding. External access (Step 8) depends on Traefik routing working correctly.

---

## STEP 8 — Update Cloudflare Tunnel to Route Through Traefik

**Where:** CT-312 shell (SSH to 10.10.100.54)

### 8a. View current tunnel config

```bash
cat /etc/cloudflared/config.yml
```

Current config should show direct routes to VM-120:

```yaml
ingress:
  - hostname: colossus-legal.cogmai.com
    service: http://10.10.100.120:5473
  - hostname: colossus-legal-api.cogmai.com
    service: http://10.10.100.120:3403
  - service: http_status:404
```

### 8b. Update tunnel config to route through Traefik

```bash
cp /etc/cloudflared/config.yml /etc/cloudflared/config.yml.bak

cat > /etc/cloudflared/config.yml << 'EOF'
tunnel: <YOUR_TUNNEL_ID>
credentials-file: /etc/cloudflared/<YOUR_TUNNEL_ID>.json

ingress:
  - hostname: colossus-legal.cogmai.com
    service: http://10.10.100.55:80
  - hostname: colossus-legal-api.cogmai.com
    service: http://10.10.100.55:80
  - service: http_status:404
EOF
```

⚠️ **Replace `<YOUR_TUNNEL_ID>`** with the actual tunnel ID from the backup config.

> **Why HTTP port 80?** Cloudflare already handles external TLS. The tunnel sends plaintext HTTP to our origin. Traefik receives this on the `http` entrypoint, inspects the `Host` header, and routes to the correct backend. The HTTP catch-all redirect middleware uses priority 1 (lowest), so named routes on the `https` entrypoint are preferred. The HTTP-to-HTTPS redirect only fires for direct LAN browser access — tunnel traffic arriving on port 80 with a matching `Host` header will be routed by Traefik before any redirect applies.

> **Important:** If the catch-all redirect interferes with tunnel traffic, we have a fallback: add duplicate routers on the `http` entrypoint for tunnel hostnames without the redirect middleware. We'll test first and adjust if needed.

### 8c. Restart cloudflared

```bash
systemctl restart cloudflared
systemctl status cloudflared
```

### 8d. Test external access

1. **On your phone (cellular, not WiFi):**
   - Browse to `https://colossus-legal.cogmai.com`
   - Cloudflare Access OTP screen should appear
   - Authenticate with your email + PIN
   - App should load normally

**Validation:**
- [ ] cloudflared restarted without errors
- [ ] External access via phone works (OTP + app loads)
- [ ] Internal access still works (re-test from workstation)

**🔄 ROLLBACK if external access breaks:**
```bash
cp /etc/cloudflared/config.yml.bak /etc/cloudflared/config.yml
systemctl restart cloudflared
```

---

## STEP 9 — Handle HTTP Redirect (if needed)

**This step is conditional.** Only needed if Step 8 testing reveals that the HTTP catch-all redirect is interfering with tunnel traffic.

**Symptom:** External access via phone gets a redirect loop or fails to load.

### 9a. Option A — Add HTTP routers for tunnel hostnames (preferred)

Add these routers to `/etc/traefik/dynamic/services.yml` inside the `routers:` section:

```yaml
    # --- Tunnel entrypoints (HTTP, no redirect) ---
    tunnel-colossus-legal-frontend:
      rule: "Host(`colossus-legal.cogmai.com`)"
      entryPoints:
        - http
      service: colossus-legal-frontend
      priority: 10

    tunnel-colossus-legal-api:
      rule: "Host(`colossus-legal-api.cogmai.com`)"
      entryPoints:
        - http
      service: colossus-legal-api
      priority: 10
```

These have higher priority (10) than the catch-all redirect (1), so tunnel traffic matching these hostnames gets routed directly without redirect.

Traefik hot-reloads — no restart needed.

### 9b. Option B — Remove catch-all redirect entirely

If Option A doesn't resolve it, remove the `http-catchall` router and `redirect-to-https` middleware from `services.yml`. LAN browsers will need to explicitly type `https://` but everything else works.

**Validation:**
- [ ] External access works after fix
- [ ] Internal HTTPS access still works

---

## STEP 10 — Update DEV Environment Variables (VM-220)

**Where:** SSH to VM-220 (10.10.100.220)

### 10a. Update frontend.env

```bash
sudo vi /var/home/core/colossus/frontend.env
```

Change:
```
COLOSSUS_API_URL=http://10.10.100.220:3403
```
To:
```
COLOSSUS_API_URL=https://colossus-legal-api-dev.cogmai.com
```

### 10b. Update backend.env

```bash
sudo vi /var/home/core/colossus/backend.env
```

Add `https://colossus-legal-dev.cogmai.com` to the CORS origins:
```
CORS_ALLOWED_ORIGINS=http://10.10.100.220:5473,http://localhost:5473,https://colossus-legal-dev.cogmai.com
```

### 10c. Restart containers

```bash
sudo systemctl restart colossus-frontend.service
sudo systemctl restart colossus-backend.service
```

### 10d. Verify DEV

1. Browse to `https://colossus-legal-dev.cogmai.com`
2. Verify app loads, API calls succeed (check browser Network tab)

**Validation:**
- [ ] DEV frontend loads via HTTPS
- [ ] DEV API calls succeed (no CORS errors in browser console)
- [ ] PROD still working (sanity check)

---

## STEP 11 — PBS Backup

**Where:** Proxmox web UI → pve-3

1. Select CT-313 → Backup → Backup now
2. Settings:
   - Storage: `pbs-zfs`
   - Mode: `Snapshot`
   - Comment: `Phase 5A - Traefik reverse proxy initial`
3. Click **Backup**

**Validation:**
- [ ] Backup of CT-313 completed successfully
- [ ] Verify in PBS dashboard: ct/313 entry present with "All OK"

---

## STEP 12 — Update Butane Source Files

**Where:** Workstation

The DEV Butane file needs to be updated to reflect the environment variable changes from Step 10. PROD Butane was already updated in today's earlier session, so only DEV needs changes.

### 12a. Update colossus-dev-app1.bu

In the `frontend.env` section, change:
```
COLOSSUS_API_URL=http://10.10.100.220:3403
```
To:
```
COLOSSUS_API_URL=https://colossus-legal-api-dev.cogmai.com
```

In the `backend.env` section, add the HTTPS origin to CORS:
```
CORS_ALLOWED_ORIGINS=http://10.10.100.220:5473,http://localhost:5473,https://colossus-legal-dev.cogmai.com
```

### 12b. Transpile (when ready to update snippets)

```bash
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < colossus-dev-app1.bu > colossus-dev-app1.ign

scp colossus-dev-app1.ign root@pve-2:/var/coreos/snippets/
```

**Validation:**
- [ ] DEV Butane file updated with HTTPS URLs
- [ ] (Optional) Transpiled and deployed to pve-2 snippets

---

## COMPLETION GATE

### All must be true:

- [ ] CT-313 (Traefik) running on pve-3 at 10.10.100.55
- [ ] Wildcard Let's Encrypt cert for *.cogmai.com obtained and auto-renewing
- [ ] LAN access via HTTPS working for PROD frontend, API, DEV frontend, API
- [ ] Traefik dashboard accessible at traefik.cogmai.com
- [ ] Cloudflare Tunnel routing through Traefik (external access working)
- [ ] Cloudflare Access OTP still functional
- [ ] Pi-hole DNS updated (all *.cogmai.com → 10.10.100.55)
- [ ] DEV environment variables updated with HTTPS URLs
- [ ] CT-313 backed up to PBS
- [ ] DEV Butane source file updated

### Phase 5A Status: ✅ COMPLETE

---

## ROLLBACK PROCEDURES

### Rollback Traefik (revert to direct access)

If Traefik causes issues and you need to revert:

1. **Pi-hole:** Change DNS records back to direct IPs:
   - `colossus-legal.cogmai.com` → `10.10.100.120`
   - `colossus-legal-api.cogmai.com` → `10.10.100.120`
   - Delete `colossus-legal-dev.cogmai.com`, `colossus-legal-api-dev.cogmai.com`, `traefik.cogmai.com`

2. **Cloudflare Tunnel:** Restore cloudflared config:
   ```bash
   # On CT-312
   cp /etc/cloudflared/config.yml.bak /etc/cloudflared/config.yml
   systemctl restart cloudflared
   ```

3. **DEV env vars:** Revert VM-220 frontend.env back to `http://10.10.100.220:3403`

4. **Stop Traefik:** `systemctl stop traefik && systemctl disable traefik` on CT-313

Everything reverts to pre-Traefik state. CT-313 can remain stopped until issues are resolved.

---

## QUICK REFERENCE — File Locations on CT-313

```
/usr/local/bin/traefik              Traefik binary
/etc/traefik/traefik.yml            Static configuration (restart required to change)
/etc/traefik/dynamic/services.yml   Routers + services (hot-reload, no restart)
/etc/traefik/dynamic/tls.yml        TLS options (hot-reload)
/etc/traefik/acme.json              Let's Encrypt cert storage (chmod 600)
/etc/traefik/cloudflare.env         API token (chmod 600)
/var/log/traefik/traefik.log        Application log
/var/log/traefik/access.log         Access log
/etc/systemd/system/traefik.service Systemd unit
```

## QUICK REFERENCE — Key Commands

```bash
systemctl status traefik            Check service status
systemctl restart traefik           Restart (needed for static config changes)
journalctl -u traefik -f            Follow logs
cat /var/log/traefik/traefik.log    View application log
cat /etc/traefik/acme.json | head   Verify cert storage
```

## QUICK REFERENCE — Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Cert not obtained | Bad CF token or wrong zone scope | Check `/etc/traefik/cloudflare.env`, verify token permissions in CF dashboard |
| 404 on valid hostname | Missing router in services.yml | Add router + service, Traefik auto-reloads |
| 502 Bad Gateway | Backend VM down or wrong port | Check backend is running: `curl http://10.10.100.120:5473` from CT-313 |
| Redirect loop (external) | HTTP catch-all redirecting tunnel traffic | Apply Step 9 fix (add HTTP routers for tunnel hostnames) |
| Cert warnings in browser | DNS still pointing to old IP | Flush DNS cache, verify Pi-hole records |
| Dashboard not loading | Port 8080 not reachable | Verify Traefik running, check firewall if any |
