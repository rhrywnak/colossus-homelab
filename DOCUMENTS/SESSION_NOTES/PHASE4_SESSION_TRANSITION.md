# PHASE 4 — Application Deployment & Edge Services: Session Transition Document

**Date:** Tuesday, Feb 11, 2026
**Phase:** Phase 4A (App Deployment) + Phase 4B (Edge Services)
**Status:** Both phases COMPLETE with outstanding follow-up items
**Domain:** cogmai.com (Cognitive Memory AI)

---

## 1. What Was Accomplished Today

### 1.1 Git Branch Management

- Merged `feature/containerization` branch to `main`
- Created `feature/cors-env-config` branch for CORS changes
- Applied CORS fix, tested locally, rebuilt images, pushed to ghcr.io
- Merged `feature/cors-env-config` to `main`

### 1.2 CORS Environment Variable Fix (backend/src/main.rs)

**Problem:** CORS allowed origins were hardcoded to `localhost:5473`, `localhost:3403`, and `10.10.0.99:5473`. Containerized deployments on different IPs would get CORS errors.

**Solution:** Replaced hardcoded `HeaderValue::from_static()` calls with dynamic `CORS_ALLOWED_ORIGINS` environment variable (comma-separated). Falls back to localhost defaults when unset, so local development is unchanged.

**Key Rust detail:** Had to use `HeaderValue::from_str()` (runtime strings) instead of `HeaderValue::from_static()` (compile-time literals) because values come from an env var.

**Files changed:** `backend/src/main.rs` only

**Rebuild:** Backend image rebuilt and pushed to ghcr.io as `v0.1.0` and `latest`

### 1.3 DEV Application VM (VM-220) Deployment

**Created:** VM-220 (`colossus-dev-app1`) on pve-2

| Property | Value |
|----------|-------|
| VMID | 220 |
| Node | pve-2 |
| IP | 10.10.100.220 (static via NetworkManager in Ignition) |
| Cores | 2 |
| Memory | 4096 MiB |
| Disk | base + 20G |
| OS | Fedora CoreOS 42 |
| Backend | ghcr.io/rhrywnak/colossus-backend:v0.1.0 → port 3403 |
| Frontend | ghcr.io/rhrywnak/colossus-frontend:v0.1.0 → port 5473 |
| DB target | 10.10.100.200 (DEV Neo4j on VM-210) |

**Artifacts used:**
- `colossus-dev-app1.bu` — Butane config (transpiled to Ignition)
- `create-vm-220.sh` — VM creation script run on pve-2

**Issues encountered and resolved:**

1. **Neo4j authentication failure:** Password in `backend.env` was wrapped in single quotes (`NEO4J_PASSWORD='password$'`). Podman `EnvironmentFile` reads values literally — quotes become part of the value. Fix: remove quotes. The `$` at end of line is safe without quotes in Podman env files (no shell expansion).

2. **Service naming confusion:** User renamed container names to include "legal" (e.g., `colossus-legal-backend`) but the systemd service names come from the `.container` filename (e.g., `colossus-backend.service`), not the `ContainerName` directive. Must use `sudo systemctl restart colossus-backend`, not `colossus-legal-backend`.

3. **Port not reachable from workstation:** Backend container was running (`podman ps` showed it) but `curl` from workstation failed. Root cause was the Neo4j auth failure — the Rust backend panics on startup if Neo4j connection fails, so the container was crash-looping. Once password was fixed, port 3403 became reachable.

### 1.4 PROD Application VM (VM-120) Deployment

**Created:** VM-120 (`colossus-prod-app1`) on pve-1

| Property | Value |
|----------|-------|
| VMID | 120 |
| Node | pve-1 |
| IP | 10.10.100.120 (static) |
| Cores | 2 |
| Memory | 4096 MiB |
| Backend | ghcr.io/rhrywnak/colossus-backend:v0.1.0 → port 3403 |
| Frontend | ghcr.io/rhrywnak/colossus-frontend:v0.1.0 → port 5473 |
| DB target | 10.10.100.110 (PROD Neo4j on VM-110) |
| RUST_LOG | warn |

**Artifacts used:**
- `colossus-prod-app1.bu` — Butane config
- `create-vm-120.sh` — VM creation script run on pve-1

**Prerequisites verified:**
- CoreOS QCOW2 image was already on pve-1 from Phase 3
- Snippets directory existed from Phase 3

**Result:** Clean deployment, both curl health checks passed, web app functional in browser. Performance identical to local desktop development.

### 1.5 Container Images Made Public

Both ghcr.io images changed from private to public visibility:
- `ghcr.io/rhrywnak/colossus-backend`
- `ghcr.io/rhrywnak/colossus-frontend`

**Rationale:** Images contain compiled binaries (Rust binary, minified JS), not source code. No secrets embedded — those come from env vars at runtime. Making public avoids the need for registry auth credentials in Ignition configs.

### 1.6 Pi-hole Local DNS Configuration

**Added cogmai.com DNS records** in Pi-hole v6 (CT-311 on pve-3):

| Hostname | IP |
|----------|-----|
| colossus-legal.cogmai.com | 10.10.100.120 |
| colossus-legal-dev.cogmai.com | 10.10.100.220 |
| colossus-legal-api.cogmai.com | 10.10.100.120 |
| pve-1.cogmai.com | 10.10.100.3 |
| pve-2.cogmai.com | 10.10.100.2 |
| pve-3.cogmai.com | 10.10.100.5 |
| colossus-prod-db1.cogmai.com | 10.10.100.110 |
| colossus-dev-db1.cogmai.com | 10.10.100.200 |
| pihole.cogmai.com | 10.10.100.53 |

**Method:** Used Pi-hole v6 web UI → Settings → All Settings → `dns.hosts` section for bulk entry. The old `custom.list` file method no longer works in v6.

**Bonus:** Short name resolution also works: `dig @10.10.100.53 pve-1 +short` returns `10.10.100.3`

**Pi-hole v6 CLI changes discovered:**
- `pihole restartdns` no longer exists in v6
- Correct command: `systemctl restart pihole-FTL`
- Full path required from `pct exec`: `/usr/local/bin/pihole` (PATH not set in non-login shells)

### 1.7 Cloudflare Tunnel Deployment (CT-312)

**Created:** CT-312 (`cloudflared`) LXC on pve-3

| Property | Value |
|----------|-------|
| CTID | 312 |
| Node | pve-3 |
| IP | 10.10.100.54 |
| Memory | 256 MB |
| Disk | 4 GB |
| OS | Debian 12 |
| Service | cloudflared (systemd managed) |

**Cloudflare dashboard setup:**
1. Zero Trust dashboard → Networks → Connectors → Cloudflare Tunnels
2. Created tunnel named "Colossus"
3. Selected Cloudflared connector type
4. Copied tunnel token (starts with `ey...`)
5. Added public hostname routes (see below)

**Navigation note:** Cloudflare restructured their UI in late 2025. Tunnels are NOT under the main dashboard. Path: Zero Trust → Networks → Connectors (tab: Cloudflare Tunnels). Adding routes is done via "Published application routes" tab on the tunnel detail page.

**Tunnel routes configured:**

| Public hostname | Service | Purpose |
|----------------|---------|---------|
| colossus-legal.cogmai.com | http://10.10.100.120:5473 | Frontend (React/nginx) |
| colossus-legal-api.cogmai.com | http://10.10.100.120:3403 | Backend API (Rust/Axum) |

**Installation:** Two scripts — `01-create-cloudflared-lxc.sh` (creates LXC) and `02-install-cloudflared.sh` (installs cloudflared, prompts for token, configures systemd service).

**Result:** Tunnel status "Healthy" in Cloudflare dashboard.

### 1.8 External Access Fix (API URL)

**Problem:** App loaded via `colossus-legal.cogmai.com` on phone, but showed "Load failed" error. The frontend JavaScript was trying to reach the backend at `http://10.10.100.120:3403` — an internal IP unreachable from cellular.

**Solution:**
1. Added second tunnel route: `colossus-legal-api.cogmai.com` → `http://10.10.100.120:3403`
2. Updated PROD VM-120 `frontend.env`: `COLOSSUS_API_URL=https://colossus-legal-api.cogmai.com`
3. Updated PROD VM-120 `backend.env` CORS: `CORS_ALLOWED_ORIGINS=http://10.10.100.120:5473,http://localhost:5473,https://colossus-legal.cogmai.com`
4. Added Pi-hole split-horizon record: `colossus-legal-api.cogmai.com` → `10.10.100.120`
5. Restarted both services on VM-120

**Split-horizon DNS result:**
- External (phone/cellular): `colossus-legal-api.cogmai.com` → Cloudflare Tunnel → `10.10.100.120:3403`
- Internal (LAN): `colossus-legal-api.cogmai.com` → Pi-hole → `10.10.100.120` (direct, no tunnel)

**Verified:** App works from both cellular and local network.

---

## 2. Current Infrastructure Inventory

| VMID | Name | Node | IP | Role | Status |
|------|------|------|----|------|--------|
| 110 | colossus-prod-db1 | pve-1 | 10.10.100.110 | PROD DB (Neo4j, Postgres, Qdrant) | ✅ Running |
| 120 | colossus-prod-app1 | pve-1 | 10.10.100.120 | PROD App (backend + frontend) | ✅ Running |
| 200 | colossus-db1-dev | pve-2 | 10.10.100.50 | Frozen DEV reference | Running |
| 210 | colossus-dev-db1 | pve-2 | 10.10.100.200 | DEV DB (Neo4j, Postgres, Qdrant) | ✅ Running |
| 220 | colossus-dev-app1 | pve-2 | 10.10.100.220 | DEV App (backend + frontend) | ✅ Running |
| 311 | pihole | pve-3 | 10.10.100.53 | Pi-hole DNS (LXC) | ✅ Running |
| 312 | cloudflared | pve-3 | 10.10.100.54 | Cloudflare Tunnel (LXC) | ✅ Running |
| 900 | PBS | pve-3 | — | Proxmox Backup Server | Running |

**External access:**
- `https://colossus-legal.cogmai.com` → PROD frontend (via Cloudflare Tunnel)
- `https://colossus-legal-api.cogmai.com` → PROD backend API (via Cloudflare Tunnel)

---

## 3. Current File/Configuration State

### 3.1 Files on VM-120 (PROD) — Patched Live

These files were manually edited on the VM after initial deployment. The Butane source files do NOT yet reflect these changes.

**`/var/home/core/colossus/frontend.env`** (current):
```
COLOSSUS_API_URL=https://colossus-legal-api.cogmai.com
```

**`/var/home/core/colossus/backend.env`** (current):
```
NEO4J_URI=bolt://10.10.100.110:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=<actual-password-no-quotes>
DOCUMENT_STORAGE_PATH=/data/documents
RUST_LOG=warn
BACKEND_PORT=3403
CORS_ALLOWED_ORIGINS=http://10.10.100.120:5473,http://localhost:5473,https://colossus-legal.cogmai.com
```

### 3.2 Files on VM-220 (DEV) — Original Ignition Values

DEV has NOT been updated with public API URLs. Currently uses internal IPs only. This is fine if DEV is only accessed from LAN.

**`/var/home/core/colossus/frontend.env`** (current):
```
COLOSSUS_API_URL=http://10.10.100.220:3403
```

### 3.3 Butane Source Files — Need Updating

The `.bu` files used to create the VMs still have the original values. If a VM is rebuilt from these files, the live-patched URLs will be lost.

**Files that need updating:**
- `colossus-prod-app1.bu` — Update frontend.env and backend.env to match live PROD values
- `colossus-dev-app1.bu` — Remove quotes from NEO4J_PASSWORD if still present; decide on DEV URL strategy

### 3.4 ghcr.io Images

| Image | Tag | Status |
|-------|-----|--------|
| ghcr.io/rhrywnak/colossus-backend | v0.1.0, latest | Public, includes CORS env var fix |
| ghcr.io/rhrywnak/colossus-frontend | v0.1.0, latest | Public, includes runtime config injection |

---

## 4. Outstanding Tasks (Priority Order)

### 4.1 IMMEDIATE — Update Butane Source Files

**Why:** If VM-120 or VM-220 needs rebuilding, the current Butane files will produce VMs with wrong URLs.

**PROD (`colossus-prod-app1.bu`):**
- `frontend.env`: Change `COLOSSUS_API_URL=http://10.10.100.120:3403` → `COLOSSUS_API_URL=https://colossus-legal-api.cogmai.com`
- `backend.env`: Change `CORS_ALLOWED_ORIGINS` to include `https://colossus-legal.cogmai.com`
- `backend.env`: Ensure NEO4J_PASSWORD has no quotes
- Re-transpile to `.ign` and copy to pve-1 `/var/coreos/snippets/`

**DEV (`colossus-dev-app1.bu`):**
- `backend.env`: Ensure NEO4J_PASSWORD has no quotes
- Decide: Should DEV get tunnel routes too? (Probably not needed — DEV is LAN-only)

### 4.2 IMPORTANT — Cloudflare Access Policies

**Why:** Currently `colossus-legal.cogmai.com` is accessible to ANYONE on the internet with no authentication.

**Steps:**
1. In Cloudflare Zero Trust dashboard → Access Controls
2. Create an Access Application for `colossus-legal.cogmai.com`
3. Configure authentication (email OTP is simplest — Cloudflare sends a code to allowed email addresses)
4. Add policy: Allow only your email address
5. Repeat for `colossus-legal-api.cogmai.com` (or use a wildcard policy for `*.cogmai.com`)
6. Test from phone: should see Cloudflare login screen before reaching app

### 4.3 IMPORTANT — PBS Backups for New VMs/CTs

**VMs/CTs not yet backed up:**
- VM-120 (colossus-prod-app1) — stateless, but config is valuable
- VM-220 (colossus-dev-app1) — stateless, but config is valuable
- CT-311 (pihole) — DNS config, gravity lists
- CT-312 (cloudflared) — tunnel token and service config

**Steps:**
- Add backup jobs in PBS for each
- These are lightweight — small disk footprint, quick backups

### 4.4 MODERATE — DEV Environment URL Decision

**Question:** Should DEV app (VM-220) use internal IPs or get its own tunnel routes?

**Options:**
- **A) LAN-only (current):** Frontend points to `http://10.10.100.220:3403`. Only accessible from inside network. Simpler.
- **B) Tunneled:** Add `colossus-legal-dev.cogmai.com` route. Accessible from anywhere. More complex.

**Recommendation:** Keep DEV as LAN-only. No reason to expose a dev environment externally.

### 4.5 MODERATE — Ansible Playbooks for Deployment

**Goal:** Codify today's manual deployment into repeatable Ansible playbooks.

**Playbooks to create:**
1. `deploy-app.yml` — Pull latest images, update env files, restart services on app VMs
2. `create-app-vm.yml` — Full VM creation from scratch (transpile Butane, create VM, wait for boot)

**Key variables to parameterize:**
- Environment (dev/prod)
- Neo4j password (Ansible Vault)
- API URLs
- CORS origins
- Image tags

### 4.6 LOW — Store Deployment Artifacts in Git

**What to commit:**
- Butane files (`.bu`) for all VMs — source of truth for rebuilds
- LXC creation scripts for Pi-hole and cloudflared
- Verification scripts
- Deployment instructions

**What NOT to commit:**
- `.ign` files (contain passwords — transpile from .bu as needed)
- Tunnel tokens
- Neo4j passwords

---

## 5. Key Lessons Learned

1. **Podman EnvironmentFile is literal:** Quotes in env files become part of the value. `FOO='bar'` sets FOO to `'bar'` (with quotes). No shell expansion, no quote stripping. Dollar signs at end of line are safe without quoting.

2. **Quadlet service names come from filenames:** The `.container` filename (e.g., `colossus-backend.container`) determines the systemd service name (`colossus-backend.service`), NOT the `ContainerName` directive inside the file.

3. **Pi-hole v6 broke many CLI commands:** `pihole restartdns` removed. Use `systemctl restart pihole-FTL`. DNS records now managed via web UI → Settings → All Settings → `dns.hosts`, not `custom.list`.

4. **Cloudflare dashboard restructured (late 2025):** Tunnels moved to Zero Trust → Networks → Connectors → Cloudflare Tunnels tab. Route management under "Published application routes" tab on tunnel detail page.

5. **Split-horizon DNS is essential for tunneled apps:** Frontend served via tunnel uses public API URL. Without split-horizon, LAN clients would hairpin through Cloudflare unnecessarily. Pi-hole records ensure LAN traffic stays local.

6. **SPA + API tunnel = two routes:** A single-page app with a separate backend API requires two tunnel routes — one for the frontend hostname, one for the API hostname. The frontend's JavaScript makes API calls from the browser, which must be routable from wherever the browser is.

---

## 6. Architecture Reference

### 6.1 External Access Flow (Phone/Cellular)

```
Phone browser
  → https://colossus-legal.cogmai.com
  → Cloudflare Edge (TLS termination)
  → Cloudflare Tunnel
  → CT-312 cloudflared (10.10.100.54)
  → http://10.10.100.120:5473 (PROD frontend)

Frontend JS (API calls)
  → https://colossus-legal-api.cogmai.com
  → Cloudflare Edge
  → Cloudflare Tunnel
  → CT-312 cloudflared
  → http://10.10.100.120:3403 (PROD backend)

Backend
  → bolt://10.10.100.110:7687 (PROD Neo4j)
```

### 6.2 Internal Access Flow (LAN Workstation)

```
Browser
  → http://colossus-legal.cogmai.com (or http://10.10.100.120:5473)
  → Pi-hole resolves to 10.10.100.120
  → Direct to PROD frontend (no tunnel)

Frontend JS (API calls)
  → https://colossus-legal-api.cogmai.com
  → Pi-hole resolves to 10.10.100.120
  → Direct to PROD backend (no tunnel)
  → NOTE: HTTPS to HTTP mismatch — browser may warn or block
```

**⚠️ POTENTIAL ISSUE:** The frontend env now uses `https://colossus-legal-api.cogmai.com` as the API URL. When accessing from LAN, Pi-hole resolves this to `10.10.100.120`, but the request uses HTTPS. The backend only serves HTTP on port 3403. This works currently because the browser makes the API call to the hostname which, from LAN, goes direct — but the HTTPS/HTTP mismatch may cause mixed content warnings in some browsers. Monitor this. If issues arise, options include:
- Adding a local reverse proxy with TLS
- Using HTTP internally and HTTPS only through the tunnel
- Configuring the frontend to detect internal vs external access

### 6.3 Node Role Summary

```
pve-1 (PROD)          pve-2 (DEV)           pve-3 (Infra/Services)
├── VM-110 PROD DB    ├── VM-200 Frozen ref  ├── VM-900 PBS
├── VM-120 PROD App   ├── VM-210 DEV DB      ├── CT-311 Pi-hole
                      ├── VM-220 DEV App     ├── CT-312 cloudflared
```

---

## 7. Credentials & Secrets Reference

| Secret | Location | Notes |
|--------|----------|-------|
| Neo4j password (DEV) | VM-220 `/var/home/core/colossus/backend.env` | Same as PROD |
| Neo4j password (PROD) | VM-120 `/var/home/core/colossus/backend.env` | Contains `$` — no quotes |
| Cloudflare Tunnel token | CT-312 (installed via `cloudflared service install`) | Stored by cloudflared internally |
| ghcr.io access | Public — no auth needed | Changed to public today |
| SSH key | `ssh-ed25519 AAAAC3...mUpD6 roman@proxima-centauri` | Used for all CoreOS VMs |

---

## 8. Session Continuity Notes

- All work today was done interactively with manual steps on the live systems
- Butane files are the source of truth for VM rebuilds but are currently STALE for PROD
- The tunnel token is sensitive — Roman has it saved separately
- Cloudflare Access is NOT yet configured — the app is publicly accessible
- DEV environment (VM-220) was not updated with public URLs — still uses internal IPs
- The `feature/cors-env-config` branch has been merged to main
- All container images on ghcr.io are at v0.1.0
