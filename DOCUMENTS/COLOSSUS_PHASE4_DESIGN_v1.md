# Colossus Phase 4 — Application Deployment & Edge Services Design

**Version:** v1.0  
**Date:** 2026-02-09  
**Status:** DRAFT — ready for operator review  
**Authoritative Context:** `COLOSSUS_HOMELAB_MASTER_CONTEXT_v2.md`

---

## 0. Executive Summary

Phase 4 builds on the completed database infrastructure (Phases 1–3) to deploy
the first application workload and establish external access. It consists of
two independent workstreams:

**Phase 4A — Application Deployment:** Deploy the Colossus-Legal web application
(Rust backend + React frontend) to dedicated CoreOS VMs on both DEV and PROD,
following established Colossus patterns (Quadlet, virtiofs, Ignition).

**Phase 4B — Edge Services & DNS:** Deploy Pi-hole for lab DNS, Cloudflare
Tunnel for external access, and split-horizon DNS for internal optimization.

These workstreams are independent. Phase 4A can be completed without 4B —
the application works on the internal network without external access. Phase 4B
can proceed in parallel if desired.

---

## 1. Scope and Non-Goals

### 1.1 In Scope

- Dedicated application VMs (DEV + PROD) using CoreOS + Quadlet
- Container image build and deployment workflow
- Legal document storage via ZFS + virtiofs
- Domain registration and Cloudflare DNS
- Pi-hole for lab VLAN DNS
- Cloudflare Tunnel for external access
- Split-horizon DNS (same hostname works inside and outside)
- Cloudflare Access policies for authentication

### 1.2 Non-Goals

- Kubernetes or orchestration beyond systemd
- Container registry (images transferred as tar files)
- CI/CD pipeline (manual build and deploy)
- Multi-tenant authentication within the application
- Performance tuning or load testing
- Database schema changes or migrations

---

## 2. Decision Record

These decisions resolve all open questions from the input documents.
Each is final unless explicitly revised.

### D1. App VMs Are Separate from DB VMs

The application gets its own VMs, not co-located on DB VMs. This follows
the Colossus principle of role separation and keeps the blast radius small.

### D2. VMID Convention

| Range | Node | Purpose |
|-------|------|---------|
| 1xx | pve-1 | PROD workloads |
| 2xx | pve-2 | DEV workloads |
| 3xx | pve-3 | Infrastructure services |
| 900 | pve-3 | PBS (existing) |

Assigned VMIDs:

| VMID | Name | Node | Role |
|------|------|------|------|
| 110 | `colossus-prod-db1` | pve-1 | PROD DB (exists) |
| 120 | `colossus-prod-app1` | pve-1 | PROD App (new) |
| 200 | `colossus-db1-dev` | pve-2 | Frozen DEV reference (exists) |
| 210 | `colossus-dev-db1` | pve-2 | DEV DB (exists) |
| 220 | `colossus-dev-app1` | pve-2 | DEV App (new) |
| 310 | `colossus-edge1` | pve-3 | Edge services — cloudflared (new) |
| 900 | PBS | pve-3 | Backup server (exists) |

### D3. IP Assignments

| VM | IP | Method | Rationale |
|----|-----|--------|-----------|
| VM-110 | 10.10.100.110 | Static (Ignition) | PROD DB — exists |
| VM-120 | 10.10.100.120 | Static (Ignition) | PROD App — predictable for DNS/CORS |
| VM-210 | 10.10.100.200 | DHCP | DEV DB — exists |
| VM-220 | 10.10.100.220 | Static (Ignition) | DEV App — predictable for API URL builds |
| VM-310 | 10.10.100.30 | Static (Ignition) | Edge services — must be stable for tunnel |
| Pi-hole | 10.10.100.53 | Static | DNS server — easy to remember |

### D4. Document Storage Uses virtiofs

Legal documents follow the Colossus pattern: ZFS dataset on the host,
virtiofs-mounted into the app VM, volume-mounted into the container.

| Environment | ZFS Dataset | Host Path | VM Mount | Container Mount |
|-------------|-------------|-----------|----------|-----------------|
| DEV | `dev-zfs/legal-docs` | `/dev-zfs/legal-docs` | `/var/mnt/data/legal-docs` | `/data/documents:ro` |
| PROD | `prod-zfs/legal-docs` | `/prod-zfs/legal-docs` | `/var/mnt/data/legal-docs` | `/data/documents:ro` |

Documents are read-only from the container's perspective. Updates are
performed by copying files to the ZFS dataset on the host.

### D5. Container Model Is Quadlet (Not Compose)

All containers use Podman Quadlet `.container` files delivered via
Butane/Ignition, consistent with the database VMs. No `podman-compose`.

### D6. Container Images Are Built on Workstation, Transferred as Tar

No container registry. Workflow:
1. Build on workstation (`podman build`)
2. Save as tar (`podman save | gzip`)
3. Transfer to VM (`scp`)
4. Load on VM (`podman load`)

Images use the `:latest` tag. Quadlet files reference `:latest` so they
never need modification between deployments. Version tracking is handled
by the release package naming.

### D7. CORS Must Be Environment-Variable Driven

The backend must read allowed CORS origins from an environment variable
(`CORS_ORIGINS`) so the same image works in DEV and PROD. This is an
application code change that must happen before first deployment.

### D8. Frontend API URL Remains Build-Time (With Future Path)

`VITE_API_URL` is baked into the JavaScript bundle at build time. This
means separate frontend image builds for DEV and PROD. This is acceptable
for now.

**Future improvement:** Inject API URL at runtime via nginx `sub_filter`
or a `/config.js` endpoint served by the backend. This would allow a
single frontend image across environments.

### D9. Internal TLS Is Deferred

Internal clients access services via HTTP. TLS is handled at the
Cloudflare edge for external access. A local reverse proxy with TLS
is a future enhancement, not a Phase 4 requirement.

### D10. Pi-hole Runs as LXC on pve-3

Pi-hole is deployed as a lightweight LXC container, not a CoreOS VM.
This follows the Colossus cluster design recommendation ("Pattern A —
LXC — best for mgmt services like Pi-hole, reverse proxy, small apps").
Pi-hole is an appliance service that doesn't benefit from the Ignition/
Quadlet model.

### D11. Edge VM Uses CoreOS + Quadlet

The cloudflared tunnel connector runs as a Quadlet-managed container on
a CoreOS VM (`colossus-edge1` on pve-3). This is consistent with the
service VM standard and makes the edge VM disposable/rebuildable.

---

## 3. Corrected Database References

The input documents contained incorrect IP references. Canonical values:

| Environment | Database VM | IP | Neo4j Bolt | PostgreSQL | Qdrant |
|-------------|------------|-----|------------|------------|--------|
| DEV | VM-210 | 10.10.100.200 | `bolt://10.10.100.200:7687` | `postgresql://10.10.100.200:5432/colossus` | `http://10.10.100.200:6333` |
| PROD | VM-110 | 10.10.100.110 | `bolt://10.10.100.110:7687` | `postgresql://10.10.100.110:5432/colossus` | `http://10.10.100.110:6333` |

**VM-200 (10.10.100.50) is a frozen reference and must NOT be used as a
database target for any deployed application.**

---

## 4. Phase 4A — Application Deployment Design

### 4.1 Architecture

```
Workstation (build)              pve-2 (DEV)                    pve-1 (PROD)
──────────────────              ────────────                    ────────────

Source code                     VM-220 (colossus-dev-app1)     VM-120 (colossus-prod-app1)
  │                             ┌─────────────────────┐        ┌─────────────────────┐
  ├── cargo build ──────────►   │ colossus-backend    │        │ colossus-backend    │
  │   podman build              │ :3403               │        │ :3403               │
  │   podman save               │                     │        │                     │
  │   scp ──────────────────►   │ colossus-frontend   │        │ colossus-frontend   │
  │                             │ :5473               │        │ :5473               │
  │                             │                     │        │                     │
  │                             │ /mnt/data/legal-docs│        │ /mnt/data/legal-docs│
  │                             │ (virtiofs, ro)      │        │ (virtiofs, ro)      │
  │                             └────────┬────────────┘        └────────┬────────────┘
  │                                      │ bolt://                      │ bolt://
  │                             ┌────────▼────────────┐        ┌────────▼────────────┐
  │                             │ VM-210 (DEV DB)     │        │ VM-110 (PROD DB)    │
  │                             │ 10.10.100.200       │        │ 10.10.100.110       │
  │                             │ Neo4j :7687         │        │ Neo4j :7687         │
  │                             └─────────────────────┘        └─────────────────────┘
```

### 4.2 App VM Specification

| Parameter | DEV (VM-220) | PROD (VM-120) |
|-----------|-------------|---------------|
| VMID | 220 | 120 |
| Name | `colossus-dev-app1` | `colossus-prod-app1` |
| Node | pve-2 | pve-1 |
| Machine type | q35 | q35 |
| CPU | 2 cores | 2 cores |
| Memory | 4096 MiB | 4096 MiB |
| Disk | local-lvm + 20G | local-lvm + 20G |
| Network | virtio, bridge=vmbr0 | virtio, bridge=vmbr0 |
| IP | 10.10.100.220 (static) | 10.10.100.120 (static) |
| OS | Fedora CoreOS | Fedora CoreOS |

App VMs are smaller than DB VMs (2 cores / 4GB vs 4 cores / 16GB)
because the application is lightweight and stateless.

### 4.3 ZFS Datasets for Documents

**DEV (pve-2):**
```bash
zfs create dev-zfs/legal-docs
# No special recordsize needed — read-only PDFs, default 128K is fine
```

**PROD (pve-1):**
```bash
zfs create prod-zfs/legal-docs
```

Proxmox directory mappings:

| Mapping ID | Node | Path |
|------------|------|------|
| `dev-legal-docs` | pve-2 | `/dev-zfs/legal-docs` |
| `prod-legal-docs` | pve-1 | `/prod-zfs/legal-docs` |

### 4.4 Butane Configuration (App VM)

The Butane config for the app VM follows the same structure as the DB VMs:

```
Butane config (colossus-dev-app1.bu)
├── Hostname
├── Static IP configuration (NetworkManager keyfile)
├── virtiofs mount unit (1x — legal-docs)
│   └── SELinux context= option
├── Quadlet container definitions (2x .container files)
│   ├── colossus-backend.container
│   └── colossus-frontend.container
├── Environment file (/etc/colossus/env/backend.env)
├── nginx.conf (/etc/colossus/nginx/nginx.conf)
├── Directory structure
├── SSH authorized key
└── systemd unit enablement (mount unit only)
```

**Key differences from DB VM Butane:**
- Only one virtiofs mount (legal-docs) instead of three (postgres/neo4j/qdrant)
- Container images are custom-built, not pulled from Docker Hub
- Backend container needs network access to the DB VM (cross-VM)
- Frontend container serves static files via nginx

### 4.5 Quadlet Container Definitions

**colossus-backend.container:**
```ini
[Unit]
Description=Colossus Legal Backend
After=var-mnt-data-legal\x2ddocs.mount
Requires=var-mnt-data-legal\x2ddocs.mount

[Container]
Image=localhost/colossus-backend:latest
ContainerName=colossus-backend
PublishPort=3403:3403
EnvironmentFile=/etc/colossus/env/backend.env
Volume=/mnt/data/legal-docs:/data/documents:ro

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

**colossus-frontend.container:**
```ini
[Unit]
Description=Colossus Legal Frontend
After=network-online.target

[Container]
Image=localhost/colossus-frontend:latest
ContainerName=colossus-frontend
PublishPort=5473:5473
Volume=/etc/colossus/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

### 4.6 Environment Files

**DEV** (`/etc/colossus/env/backend.env`):
```bash
NEO4J_URI=bolt://10.10.100.200:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=<dev-password>
DOCUMENT_STORAGE_PATH=/data/documents
CORS_ORIGINS=http://10.10.100.220:5473,http://localhost:5473
RUST_LOG=debug
BIND_ADDRESS=0.0.0.0:3403
```

**PROD** (`/etc/colossus/env/backend.env`):
```bash
NEO4J_URI=bolt://10.10.100.110:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=<prod-password>
DOCUMENT_STORAGE_PATH=/data/documents
CORS_ORIGINS=http://10.10.100.120:5473,http://localhost:5473
RUST_LOG=warn
BIND_ADDRESS=0.0.0.0:3403
```

### 4.7 Container Image Build Process

**On workstation:**

```bash
# Backend
cd ~/Projects/colossus-legal
podman build -f deploy/docker/Dockerfile.backend \
    -t colossus-backend:latest .
podman save colossus-backend:latest | gzip > colossus-backend-latest.tar.gz

# Frontend (DEV)
podman build -f deploy/docker/Dockerfile.frontend \
    --build-arg VITE_API_URL=http://10.10.100.220:3403 \
    -t colossus-frontend:latest .
podman save colossus-frontend:latest | gzip > colossus-frontend-dev-latest.tar.gz

# Frontend (PROD)
podman build -f deploy/docker/Dockerfile.frontend \
    --build-arg VITE_API_URL=http://10.10.100.120:3403 \
    -t colossus-frontend:latest .
podman save colossus-frontend:latest | gzip > colossus-frontend-prod-latest.tar.gz
```

### 4.8 Deployment Workflow

**First deployment (VM creation):**
1. Create ZFS dataset for legal-docs on host
2. Create Proxmox directory mapping
3. Copy legal document PDFs to ZFS dataset
4. Transpile Butane → Ignition
5. Create VM via `qm` script
6. Start VM — containers will fail (no images yet)
7. Transfer and load container images
8. Restart container services
9. Validate

**Subsequent deployments (app updates):**
1. Build new container images on workstation
2. Transfer tar files to VM via scp
3. Load images (`podman load`)
4. Restart services (`sudo systemctl restart colossus-backend colossus-frontend`)
5. Validate

**Document updates:**
1. Copy new PDFs to the ZFS dataset on the Proxmox host
2. No container restart needed (read on access)

### 4.9 App Deployment Validation

```bash
#!/bin/bash
HOST=$1
echo "== Colossus-Legal Validation =="

echo -n "Backend health... "
curl -sf http://${HOST}:3403/health && echo "✓" || echo "✗ FAILED"

echo -n "Case endpoint... "
curl -sf http://${HOST}:3403/case | grep -q "awad-v-cfs" && echo "✓" || echo "✗ FAILED"

echo -n "Schema endpoint... "
curl -sf http://${HOST}:3403/schema | grep -q "count" && echo "✓" || echo "✗ FAILED"

echo -n "Frontend serves... "
curl -sf http://${HOST}:5473/ | grep -q "Colossus" && echo "✓" || echo "✗ FAILED"

echo "== Done =="
```

### 4.10 Application Prerequisites (Must Complete Before Deployment)

These items require application code changes:

| Item | Status | Owner | Notes |
|------|--------|-------|-------|
| Implement `GET /health` endpoint | ❌ Not done | App team | Returns 200/503 based on DB connectivity |
| Make CORS origins configurable via `CORS_ORIGINS` env var | ❌ Not done | App team | Currently hardcoded |
| Create `Dockerfile.backend` | ❌ Not done | App team | Multi-stage: rust builder + debian-slim runtime |
| Create `Dockerfile.frontend` | ❌ Not done | App team | Multi-stage: node builder + nginx runtime |
| Create `nginx.conf` for frontend | ❌ Not done | App team | SPA routing, port 5473, cache headers |
| Test container builds locally | ❌ Not done | App team | `podman build` + `podman run` on workstation |

**None of these require infrastructure work.** They can be completed
independently before the VM creation session.

---

## 5. Phase 4B — Edge Services & DNS Design

### 5.1 Architecture Overview

```
Internet                  Cloudflare Edge              Homelab
────────                  ──────────────              ───────

User's phone     ──►     Cloudflare DNS
                          │
                          ▼
                         Cloudflare Tunnel
                          │ (outbound from homelab)
                          │
                          │              pve-3 (VM-310: colossus-edge1)
                          │              ┌─────────────────────┐
                          └──────────────┤  cloudflared        │
                                         │  (Quadlet container)│
                                         └────────┬────────────┘
                                                   │ routes to internal IPs
                                                   │
                     ┌─────────────────────────────┼─────────────────────┐
                     ▼                             ▼                     ▼
              VM-120 :5473/:3403           VM-110 :7474           (other services)
              (PROD App)                   (PROD DB — Neo4j UI)


Internal (lab VLAN)       pve-3 (LXC: Pi-hole)
────────────────          ┌─────────────────────┐
                          │  Pi-hole             │
Lab device DNS ──────────►│  10.10.100.53        │
                          │  Local DNS overrides │
                          │  Ad blocking         │
                          └──────────────────────┘

Internal (family VLAN)
──────────────────────
Family device DNS ────►  UDM (1.1.1.1 / ISP)    ◄── NOT Pi-hole
```

### 5.2 DNS Three-Layer Model

**Layer 1 — Infrastructure (DO NOT TOUCH):**
- `pve-1.local`, `pve-2.local`, `pve-3.local`
- Managed by `/etc/hosts` and corosync
- Never rename, never redirect

**Layer 2 — Internal service DNS (Pi-hole overrides):**
- `legal.<domain>` → 10.10.100.120 (PROD app frontend)
- `neo4j.<domain>` → 10.10.100.110 (PROD Neo4j browser)
- `grafana.<domain>` → (future)
- Lab VLAN clients resolve via Pi-hole, get direct internal IPs

**Layer 3 — Public DNS (Cloudflare):**
- Same hostnames as Layer 2
- `legal.<domain>` → Cloudflare Tunnel → 10.10.100.120:5473
- External clients resolve via Cloudflare, traffic goes through tunnel

**Result:** `legal.<domain>` works from both inside and outside the network.
Inside goes direct (fast), outside goes through Cloudflare (secure).

### 5.3 VLAN DNS Assignment

| VLAN | Purpose | DNS Server | Rationale |
|------|---------|------------|-----------|
| Family/Trusted | Household devices | UDM default (1.1.1.1 or ISP) | Must work if Pi-hole is down |
| Servers/Lab | Proxmox, VMs, workstation | Pi-hole (10.10.100.53) | Lab control, logging, overrides |
| IoT (optional) | Smart devices | Pi-hole (10.10.100.53) | Blocking, visibility |
| Guest | Visitors | UDM default | No lab access |

**Invariant:** Family VLAN internet must work even if Pi-hole is offline.

### 5.4 Pi-hole Specification

| Property | Value |
|----------|-------|
| Runtime | LXC container on pve-3 |
| CTID | 311 |
| OS template | Debian 12 (or Ubuntu 22.04) |
| IP | 10.10.100.53 (static) |
| Resources | 1 vCPU, 512MB RAM, 4GB disk |
| Upstream DNS | 1.1.1.1, 8.8.8.8 (or Unbound later) |

Pi-hole is an appliance — LXC is the appropriate runtime. It does not
need the CoreOS/Quadlet/Ignition model.

**Backup:** PBS can back up LXC containers. Add to scheduled backup job.

### 5.5 Edge VM Specification

| Property | Value |
|----------|-------|
| VMID | 310 |
| Name | `colossus-edge1` |
| Node | pve-3 |
| Machine type | q35 |
| CPU | 2 cores |
| Memory | 2048 MiB |
| Disk | local-lvm + 10G |
| IP | 10.10.100.30 (static) |
| OS | Fedora CoreOS |

**Persistence:** Minimal — cloudflared config and tunnel credentials only.
No ZFS dataset needed. Config delivered via Ignition, credentials stored
securely and injected at deployment time.

### 5.6 Cloudflare Tunnel Configuration

**cloudflared Quadlet container:**
```ini
[Unit]
Description=Cloudflare Tunnel
After=network-online.target

[Container]
Image=docker.io/cloudflare/cloudflared:latest
ContainerName=cloudflared
Exec=tunnel run
EnvironmentFile=/etc/colossus/env/cloudflared.env
Volume=/etc/colossus/cloudflared:/etc/cloudflared:ro

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

**config.yml (initial):**
```yaml
tunnel: <tunnel-id>
credentials-file: /etc/cloudflared/<tunnel-id>.json

ingress:
  - hostname: legal.<domain>
    service: http://10.10.100.120:5473
  - hostname: legal-api.<domain>
    service: http://10.10.100.120:3403
  - hostname: neo4j.<domain>
    service: http://10.10.100.110:7474
  - service: http_status:404
```

### 5.7 Cloudflare Access Policies

| Hostname | Policy | Auth Method |
|----------|--------|-------------|
| `legal.<domain>` | Require authentication | Email OTP or Google SSO |
| `legal-api.<domain>` | Require authentication | Same as above |
| `neo4j.<domain>` | Require authentication + restrict to admin | Email OTP |

**Principle:** Nothing is anonymously accessible unless explicitly intended.
Proxmox UI and PBS UI should NOT be exposed through the tunnel.

### 5.8 Edge Services Prerequisites

| Item | Status | Notes |
|------|--------|-------|
| Choose and register domain | ❌ Not done | Stable name for years; avoid `.local` |
| Create Cloudflare account + 2FA | ❌ Not done | |
| Identify VLAN IDs on UDM | ❌ Not done | Needed for DNS split configuration |
| Decide tunnel hostnames | ❌ Not done | Proposed above, needs confirmation |

---

## 6. Execution Order

### 6.1 Recommended Sequence

```
Phase 4A (Application)                   Phase 4B (Edge Services)
─────────────────────                   ────────────────────────

4A.1  Application code prerequisites     4B.1  Register domain
      (health endpoint, CORS,                  Cloudflare account setup
       Dockerfiles)
          │                                        │
4A.2  Create DEV app VM (VM-220)         4B.2  Deploy Pi-hole (LXC on pve-3)
      Deploy to DEV                            Configure UDM VLAN DNS
      Validate                                 Validate family stability
          │                                        │
4A.3  Create PROD app VM (VM-120)        4B.3  Deploy Edge VM (VM-310)
      Deploy to PROD                           Configure Cloudflare Tunnel
      Validate                                 Validate external access
          │                                        │
4A.4  PBS backups for app VMs            4B.4  Split-horizon DNS
                                               Cloudflare Access policies
                                               Full validation
          │                                        │
          └──────────── Both complete ─────────────┘
                            │
                    Update Master Context
                    Phase 4 closeout
```

### 6.2 Dependencies

- 4A.1 blocks everything in 4A (can't deploy without Dockerfiles)
- 4A.2 must complete before 4A.3 (DEV validates before PROD)
- 4B.1 blocks everything in 4B (need a domain)
- 4B.2 and 4B.3 are independent of each other
- 4B.4 requires both 4B.2 and 4B.3
- 4A and 4B have no cross-dependencies until tunnel ingress references app IPs

---

## 7. Automation Scripts (Phase 4A)

Following the Phase 2/3 pattern, each step should be scripted:

**DEV (pve-2):**

| Script | Runs on | Purpose |
|--------|---------|---------|
| `01-create-dev-app-zfs.sh` | pve-2 | Create `dev-zfs/legal-docs` dataset |
| `02-setup-dev-app-mappings.sh` | pve-2 | Create directory mapping `dev-legal-docs` |
| `03-create-vm-220.sh` | pve-2 | Create app VM with q35, virtiofs, Ignition |
| `04-copy-legal-docs.sh` | Workstation | scp documents to ZFS dataset |
| `05-deploy-app-images.sh` | Workstation | Transfer + load container images |
| `06-validate-dev-app.sh` | Workstation | Health + endpoint validation |

**PROD (pve-1):**

Identical structure with PROD-specific parameters (adapted from DEV,
same as Phase 2 → Phase 3 pattern).

---

## 8. Backup Strategy (Phase 4A)

| VM | Backup Target | Schedule |
|----|---------------|----------|
| VM-120 (PROD App) | pbs-1 | Daily |
| VM-220 (DEV App) | pbs-1 | Manual as needed |

App VMs are stateless — they can be rebuilt from Ignition + image load.
PBS backup is belt-and-suspenders, not the primary recovery path.

Legal documents on ZFS datasets are backed up as part of the host-level
PBS backup (same as database datasets).

---

## 9. Relationship to Existing Documents

### 9.1 Superseded

| Document | Status | Reason |
|----------|--------|--------|
| `APPLICATION_DEPLOYMENT_REQUIREMENTS.md` | **Superseded by this doc** | Errors corrected, decisions made, aligned to Colossus patterns |
| `DEPLOYMENT.md` | **Superseded by this doc** | Wrong tooling (compose), wrong IPs, wrong deployment model |

These documents remain as historical reference but are NOT authoritative
for Phase 4 execution.

### 9.2 Incorporated

| Document | How Used |
|----------|----------|
| `COLOSSUS_EDGE_DNS_CLOUDFLARE_TECHNICAL_DESIGN_v1.0.md` | Architecture incorporated; decisions on Pi-hole runtime and IP planning added |
| `COLOSSUS_EDGE_DNS_CLOUDFLARE_EXECUTION_TASK_TRACKER_v1.0.md` | Task structure incorporated into Section 6; will be updated with concrete parameters |

### 9.3 Referenced

| Document | Relationship |
|----------|-------------|
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v2.md` | Authoritative source for all infrastructure state |
| `COLOSSUS_COREOS_VM_CREATION_RUNBOOK_v1.md` | Procedure reference for app VM creation |
| `COLOSSUS_DEV_BACKUP_RESTORE_RUNBOOK_v1.md` | Backup patterns (PBS, retention) |

---

## 10. Open Items Requiring Operator Input

Before execution begins, confirm:

1. **Domain name choice** — needed for all Cloudflare and DNS work
2. **UDM VLAN inventory** — which VLAN IDs exist and their current DNS settings
3. **Application code readiness** — are the prerequisites in Section 4.10 complete?
4. **Timeline preference** — start with 4A (app deployment) or 4B (edge), or parallel?

---

## 11. Success Criteria

Phase 4 is complete when:

- Colossus-Legal is accessible at `http://10.10.100.120:5473` (PROD, internal)
- Colossus-Legal is accessible at `https://legal.<domain>` (external, authenticated)
- Same URL works inside (direct) and outside (tunnel) the network
- Lab VLAN uses Pi-hole for DNS
- Family VLAN is unaffected by any lab DNS changes
- Application can be rebuilt and redeployed in under 30 minutes
- All VMs are backed up to PBS
- Documentation is updated

---

*End of Phase 4 Design v1.0*
