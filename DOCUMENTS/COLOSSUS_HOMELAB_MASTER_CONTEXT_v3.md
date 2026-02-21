# Colossus Homelab â€” Master Context, Architecture, and Execution Plan

**Project Name:** Colossus  
**Scope:** On-prem Proxmox homelab for containerized databases, LLM infrastructure, and agentic systems  
**Audience:** Primary operator (authoritative), future collaborators, future self  
**Document Type:** Canonical context + execution reference  
**Status:** Living document with phase locks  
**Last Updated:** 2026-02-12 (Phase 5A complete — Traefik reverse proxy)

---

## 1. Purpose of This Document

This document exists to:

1. Define **why** the Colossus homelab exists
2. Describe **what was designed**
3. Record **what has been implemented**
4. Explicitly enumerate **what remains to be done**
5. Ensure **DEV and PROD parity** through repeatable processes

This document is **authoritative**.  
If reality diverges from this document, execution **must pause** and the document must be updated first.

---

## 2. Objectives

### 2.1 Primary Objectives

The Colossus homelab is designed to:

- Provide a **reproducible, deterministic infrastructure** for:
  - Databases (PostgreSQL, Neo4j, Qdrant)
  - Vector search and knowledge graphs
  - LLM inference, experimentation, and agentic systems
- Support **parallel environments** (DEV â†’ PROD) without in-place mutation
- Enable **safe rebuilds** instead of fragile upgrades
- Make infrastructure **boring, inspectable, and scriptable**
- Allow long pauses in work without loss of understanding

---

### 2.2 Explicit Non-Goals

The homelab is **not** intended to be:

- Kubernetes-based
- Click-ops driven
- Tuned for maximum density or micro-optimizations
- A high-availability enterprise cluster
- Continuously modified in place

Correctness, recoverability, and clarity are prioritized over performance.

---

## 3. Design Principles (Hard Rules)

These principles are non-negotiable:

1. **Rebuild > mutate**
2. **Data lives outside the VM**
3. **VMs are disposable; datasets are not**
4. **systemd controls lifecycle, not humans**
5. **Everything important must be scriptable**
6. **Parallel validation before cutover**
7. **No silent assumptions**
8. **Production must be reproducible from DEV artifacts**

---

## 4. High-Level Architecture

### 4.1 Physical Layer

| Node  | Role |
|-------|------|
| pve-1 | Production workloads |
| pve-2 | Development workloads |
| pve-3 | Proxmox Backup Server + infrastructure services |

Roles are **exclusive**. No node serves mixed responsibilities.

---

### 4.2 Virtualization Layer

- Proxmox VE 9.1.5 cluster (`colossus`)
- VM lifecycle controlled via `qm` CLI
- No UI-only configuration considered authoritative
- All important VM configuration must be expressible in scripts
- **Machine type `q35` is required** for VMs using virtiofs

---

### 4.3 Operating System Standard

**Fedora CoreOS** is the only supported OS for service VMs.

Reasons:
- Immutable base
- Ignition-driven provisioning
- Deterministic startup
- Container-native lifecycle

All configuration is expressed via:
- Butane â†’ Ignition
- Podman Quadlet (`.container` files)
- systemd mount units

---

## 5. Storage Architecture (Canonical)

### 5.1 Host-Level Storage

- ZFS pools created on Proxmox hosts
- One pool per environment
- Separate datasets per service

Dataset layout (as-built):

```
dev-zfs/          (pve-2, Crucial MX500 2TB SATA SSD)
â”œâ”€â”€ postgres      recordsize=16K, compression=zstd
â”œâ”€â”€ neo4j         recordsize=1M, compression=zstd
â””â”€â”€ qdrant        recordsize=128K, compression=zstd

prod-zfs/         (pve-1, Crucial T500 2TB NVMe)
â”œâ”€â”€ postgres      recordsize=16K, compression=zstd
â”œâ”€â”€ neo4j         recordsize=1M, compression=zstd
â””â”€â”€ qdrant        recordsize=128K, compression=zstd
```

---

### 5.2 VM-Level Access

- **virtiofs** is used to mount host ZFS datasets into CoreOS VMs
- VM root filesystem never contains authoritative data
- All persistent state resides on the Proxmox host
- virtiofs requires Proxmox **directory resource mappings** (`pvesh create /cluster/mapping/dir`)
- virtiofs requires **q35 machine type** on the VM

This enables:
- Fast rebuilds
- Safe restores
- Clear failure boundaries

### 5.3 SELinux and virtiofs (Critical)

Fedora CoreOS runs SELinux in **enforcing mode**. virtiofs mounts from a non-SELinux host (Proxmox/Debian) appear with context `virtiofs_t`, which containers (`container_t`) cannot access.

**Required fix:** All virtiofs systemd mount units must include:

```ini
Options=context="system_u:object_r:container_file_t:s0"
```

This assigns `container_file_t` at the VFS level without requiring xattr support from the host.

**What does NOT work on virtiofs:**
- `:z` or `:Z` volume flags (no xattr passthrough)
- `chcon` / `restorecon` (same limitation)

**For one-shot admin containers** (e.g., neo4j-admin restore), use `--security-opt label=disable`.

---

## 6. Container Model

### 6.1 Runtime

- Podman (rootful)
- Containers managed via **Podman Quadlet** (`.container` files in `/etc/containers/systemd/`)
- systemd generator creates `.service` units automatically on boot

### 6.2 Lifecycle Rules

- Containers are disposable
- Container images are replaceable
- Data is external and persistent
- Containers may be destroyed and recreated at any time

### 6.3 Configuration Model

- Quadlet `.container` files declare image, ports, volumes, dependencies
- Environment files in `/etc/colossus/env/` (credentials)
- systemd mount units wire virtiofs mounts with SELinux context
- All configuration delivered via Butane â†’ Ignition on first boot
- No ad-hoc `podman run` usage

### 6.4 Path Convention

On CoreOS, `/mnt` is a symlink to `/var/mnt`. This matters for systemd:

| Context | Path to use |
|---------|------------|
| systemd mount unit `Where=` and filenames | `/var/mnt/data/{service}` |
| Container volume mounts, SSH commands, scripts | `/mnt/data/{service}` |

Both resolve to the same location. Only systemd units require the canonical form.

---

## 7. Databases in Scope

| Service | Image | Ports | DEV Persistence | PROD Persistence |
|---------|-------|-------|-----------------|------------------|
| PostgreSQL 17 | `docker.io/library/postgres:17` | 5432 | `dev-zfs/postgres` | `prod-zfs/postgres` |
| Neo4j 5 | `docker.io/library/neo4j:5` | 7474, 7687 | `dev-zfs/neo4j` | `prod-zfs/neo4j` |
| Qdrant | `docker.io/qdrant/qdrant:latest` | 6333, 6334 | `dev-zfs/qdrant` | `prod-zfs/qdrant` |

Container UIDs (must be set guest-side, no host-side UID mapping on virtiofs):

| Container | UID:GID |
|-----------|---------|
| PostgreSQL | 999:999 |
| Neo4j | 7474:7474 |
| Qdrant | 1000:1000 |

All follow the same lifecycle:
1. External storage mounted (virtiofs with SELinux context)
2. Empty container started
3. Data restored from verified backups
4. Validated against reference
5. Put into service

---

## 8. Current State

### 8.1 Phase 1 â€” Backups & PBS

- Proxmox Backup Server configured (VM-900 on pve-3)
- Database backups created and verified
- Off-host copies confirmed

**Status:** ðŸ”’ Locked

---

### 8.2 Phase 2 â€” Preparation

- Migration strategy defined
- Guardrails written
- Execution checklist authored
- Butane + virtiofs model validated

**Status:** ðŸ”’ Locked

---

### 8.3 Phase 2 â€” Execution (DEV)

Completed:
- ZFS pool `dev-zfs` created on pve-2 (Crucial MX500 2TB)
- Datasets created and tuned: postgres, neo4j, qdrant
- Proxmox directory resource mappings created (db-postgres, db-neo4j, db-qdrant)
- VM-210 (`colossus-dev-db1`) created via scripted `qm` commands
- Butane config authored with SELinux context fix, Quadlet containers, virtiofs mounts
- Ignition deployed via cloud-init vendor snippet
- All three containers auto-start on boot
- Data restored from Phase 1 backups
- Parallel validation passed against VM-200
- VM-200 remains untouched as frozen reference
- SELinux + virtiofs interaction discovered and documented
- Backup/restore runbook created
- Phase 2 Completion Report authored

**Status:** ðŸ”’ Locked

---

### 8.4 Phase 3 â€” Execution (PROD)

Completed:
- ZFS pool `prod-zfs` created on pve-1 (Crucial T500 2TB NVMe)
- Datasets created and tuned: postgres, neo4j, qdrant (identical to DEV)
- Proxmox directory resource mappings created (prod-db-postgres, prod-db-neo4j, prod-db-qdrant)
- VM-110 (`colossus-prod-db1`) created via scripted `qm` commands adapted from DEV
- Static IP 10.10.100.110 configured via Butane/Ignition
- All three containers auto-start on boot
- Data restored from DEV-validated backups
- DEV/PROD parity confirmed: PostgreSQL (25 tables), Neo4j (207 nodes), Qdrant (287 points)
- Reboot test passed â€” mounts and containers survived restart
- CoreOS auto-update survived (42.20250929.3.0 â†’ 43.20260119.3.1)
- First PBS backup completed (32 seconds, 50 GiB)
- Scheduled daily PBS backup job created (`backup-prod-db`)
- Phase 3 Completion Report authored

**Status:** ðŸ”’ Locked

---


### 8.5 Phase 4A — Application Deployment

Completed:
- Colossus-Legal application containerized (Rust/Axum backend + React/nginx frontend)
- Container images published to ghcr.io (public): `colossus-backend:v0.1.0`, `colossus-frontend:v0.1.0`
- CORS origins externalized via `CORS_ALLOWED_ORIGINS` environment variable
- VM-220 (`colossus-dev-app1`) deployed on pve-2 via Butane/Ignition + Quadlet
- VM-120 (`colossus-prod-app1`) deployed on pve-1 via Butane/Ignition + Quadlet
- Both VMs use same container images, differentiated by environment files
- Git branch workflow: `feature/containerization` → `feature/cors-env-config` → `main`

**Key lessons:**
- Podman EnvironmentFile is literal: quotes in env files become part of the value
- Quadlet service names derive from `.container` filenames, not `ContainerName` directives
- Rust backend panics on Neo4j auth failure → crash-loop looks like port-unreachable

**Status:** 🔒 Locked

---

### 8.6 Phase 4B — Edge Services

Completed:
- Domain `cogmai.com` registered (Cognitive Memory AI)
- CT-311 (`pihole`) deployed on pve-3 — Pi-hole v6 for local DNS
- CT-312 (`cloudflared`) deployed on pve-3 — Cloudflare Tunnel connector
- Cloudflare Tunnel "Colossus" created with two routes:
  - `colossus-legal.cogmai.com` → PROD frontend
  - `colossus-legal-api.cogmai.com` → PROD API
- Split-horizon DNS configured: LAN traffic stays local, external traffic via tunnel
- LXC containers deployed via two-script pattern: `01-create-*.sh` + `02-install-*.sh`

**Key lessons:**
- Pi-hole v6 removed `pihole restartdns`; use `systemctl restart pihole-FTL`
- Pi-hole v6 DNS records managed via web UI → Settings → All Settings → `dns.hosts`, not `custom.list`
- Cloudflare dashboard restructured (late 2025): Tunnels under Zero Trust → Networks → Connectors
- SPA + API = two tunnel routes (frontend JS makes API calls from the browser)

**Status:** 🔒 Locked

---

### 8.7 Phase 5A — Traefik Reverse Proxy

Completed:
- CT-313 (`traefik`) deployed on pve-3 — Traefik v3.3.3 reverse proxy
- Let's Encrypt wildcard certificate for `*.cogmai.com` via DNS-01 challenge (Cloudflare)
- TLS termination for all internal and external HTTPS traffic
- Pi-hole DNS records updated: all `*.cogmai.com` hostnames → 10.10.100.55 (Traefik)
- Cloudflare Tunnel routes updated: traffic → Traefik HTTP port 80 → backend services
- HTTP catch-all redirect (priority 1) for LAN browsers → HTTPS
- Explicit HTTP routers (priority 10) for tunnel hostnames to prevent redirect loops
- DEV environment updated: frontend uses `https://colossus-legal-api-dev.cogmai.com`
- PROD environment confirmed working: internal (LAN) and external (cellular) access
- Butane source files updated to match live configuration for both DEV and PROD
- Deployed via same two-script pattern as CT-311/CT-312

**Routers configured (all with TLS):**
- `colossus-legal.cogmai.com` → http://10.10.100.120:5473 (PROD frontend)
- `colossus-legal-api.cogmai.com` → http://10.10.100.120:3403 (PROD API)
- `colossus-legal-dev.cogmai.com` → http://10.10.100.220:5473 (DEV frontend)
- `colossus-legal-api-dev.cogmai.com` → http://10.10.100.220:3403 (DEV API)
- `traefik.cogmai.com` → Traefik dashboard

**Status:** 🔒 Locked

---

## 9. Repeatability & Parity Requirement

From this point forward:

- No VM creation is considered valid unless it is scriptable
- Manual steps are allowed only to discover correct parameters
- All validated steps must be codified

**DEV artifacts are the source of truth for PROD.**

This principle was validated in Phase 3: PROD was deployed mechanically from adapted DEV artifacts with zero new design decisions.

---

## 10. Phase 2 Work â€” DEV Execution (COMPLETE)

All items completed 2026-02-08:

1. ~~Formalize VM creation script (`qm`-based)~~ âœ…
2. ~~Create new DEV CoreOS VM from script~~ âœ… (VM-210)
3. ~~Attach virtiofs datasets~~ âœ… (via directory mappings)
4. ~~Apply Ignition configuration~~ âœ… (via cloud-init vendor snippet)
5. ~~Bring up empty containers~~ âœ… (Quadlet auto-start)
6. ~~Restore PostgreSQL data~~ âœ…
7. ~~Restore Neo4j data~~ âœ…
8. ~~Restore Qdrant snapshot~~ âœ…
9. ~~Run parallel validation vs VM-200~~ âœ… (all checks passed)
10. ~~Phase 2 exit gate~~ âœ…

---

## 11. Phase 3 Work â€” PROD Execution (COMPLETE)

All items completed 2026-02-08/09:

1. ~~Create PROD automation package from DEV artifacts~~ âœ…
2. ~~Create ZFS pool `prod-zfs` on pve-1~~ âœ…
3. ~~Create directory mappings (prod-db-*)~~ âœ…
4. ~~Create and start VM-110~~ âœ…
5. ~~Restore PostgreSQL data~~ âœ…
6. ~~Restore Neo4j data~~ âœ…
7. ~~Restore Qdrant snapshot~~ âœ…
8. ~~DEV vs PROD validation~~ âœ… (all metrics match)
9. ~~Reboot test~~ âœ…
10. ~~PBS backup + scheduled job~~ âœ…
11. ~~Phase 3 exit gate~~ âœ…

---

## 12. Phase 4 Work — App Deployment & Edge Services (COMPLETE)

All items completed 2026-02-11:

**Phase 4A — Application Deployment:**
1. ~~Containerize Colossus-Legal (backend + frontend)~~ ✅
2. ~~Push images to ghcr.io~~ ✅
3. ~~Externalize CORS via environment variable~~ ✅
4. ~~Deploy VM-220 (DEV App) on pve-2~~ ✅
5. ~~Deploy VM-120 (PROD App) on pve-1~~ ✅
6. ~~Verify end-to-end (browser + API)~~ ✅

**Phase 4B — Edge Services:**
1. ~~Deploy CT-311 (Pi-hole) on pve-3~~ ✅
2. ~~Configure local DNS records for cogmai.com~~ ✅
3. ~~Deploy CT-312 (cloudflared) on pve-3~~ ✅
4. ~~Create Cloudflare Tunnel with routes~~ ✅
5. ~~Configure split-horizon DNS~~ ✅
6. ~~Verify external access (cellular)~~ ✅

---

## 13. Phase 5A Work — Traefik Reverse Proxy (COMPLETE)

All items completed 2026-02-12:

1. ~~Create Cloudflare API token (DNS edit)~~ ✅
2. ~~Deploy CT-313 (Traefik) on pve-3~~ ✅
3. ~~Install Traefik v3, configure LE wildcard cert~~ ✅
4. ~~Update Pi-hole DNS → Traefik (10.10.100.55)~~ ✅
5. ~~Test internal HTTPS access~~ ✅
6. ~~Update Cloudflare Tunnel routes → Traefik~~ ✅
7. ~~Fix HTTP redirect loop for tunnel traffic~~ ✅
8. ~~Update DEV environment variables~~ ✅
9. ~~PBS backup of CT-313~~ ✅
10. ~~Update Butane source files (DEV + PROD)~~ ✅

---


## 14. Known Issues

### 14.1 pve-1 igc NIC Instability

The Intel i225/i226 NIC on pve-1 (igc driver) exhibits intermittent SSH stalls under burst traffic. This does not affect normal operation or database services â€” only rapid sequential SSH connections.

**Workaround:** SSH connection multiplexing on the workstation (`~/.ssh/config` with ControlMaster/ControlPath/ControlPersist).

**Future investigation:**
- Make ethtool offload changes persistent (`post-up` in `/etc/network/interfaces`)
- Test with newer Proxmox kernel
- Evaluate using ice NIC (Intel E800 10G/25G) instead of igc
- BIOS PCIe lane allocation

### 14.2 CoreOS Auto-Updates

Zincati auto-updates are enabled by default and will reboot VMs without warning. This was validated to be non-destructive (Phase 3 survived it), but for production stability, consider configuring maintenance windows.

---

## 15. Future Work

These are independent workstreams that can be prioritized based on operational need:

### Completed (moved from future)
- ~~Edge services~~ — **Done (Phase 4B + 5A):** Domain, DNS, Cloudflare Tunnel, Pi-hole, Traefik
- ~~Application deployment~~ — **Done (Phase 4A):** Colossus-Legal containerized and deployed
- ~~Reverse proxy~~ — **Done (Phase 5A):** Traefik with Let's Encrypt wildcard cert

### Active / Upcoming
- **Phase 5B — Ansible** — Configuration management, playbooks for VM/CT provisioning, Ansible Vault for secrets
- **Cloudflare Access policies** — Authentication for `*.cogmai.com` (currently publicly accessible)
- **Scheduled backups for all VMs/CTs** — Currently only VM-110 has automated PBS backups
- **Store deployment artifacts in Git** — Butane files, LXC scripts, Traefik configs (no secrets)

### Deferred
- **pve-1 NIC investigation** — permanent offload fix, alternative NIC evaluation
- **CoreOS update strategy** — Zincati maintenance window configuration for PROD
- **Monitoring/logging** — Centralized log aggregation and alerting
- **Authentication gateway** — Authentik or similar identity provider

## 16. Authoritative Artifacts

### 16.1 Configuration (Butane/Ignition)

| Artifact | Location | Purpose |
|----------|----------|---------|
| `colossus-dev-db1.bu` | Workstation: `~/colossus-phase2/butane/` | DEV DB VM configuration source |
| `colossus-dev-db1.ign` | pve-2: `/var/coreos/snippets/` | Compiled Ignition for VM-210 |
| `colossus-prod-db1.bu` | Workstation: `~/colossus-phase3/butane/` | PROD DB VM configuration source |
| `colossus-prod-db1.ign` | pve-1: `/var/coreos/snippets/` | Compiled Ignition for VM-110 |
| `colossus-dev-app1.bu` | Workstation | DEV App VM configuration source |
| `colossus-dev-app1.ign` | pve-2: `/var/coreos/snippets/` | Compiled Ignition for VM-220 |
| `colossus-prod-app1.bu` | Workstation | PROD App VM configuration source |
| `colossus-prod-app1.ign` | pve-1: `/var/coreos/snippets/` | Compiled Ignition for VM-120 |

### 16.2 Automation Scripts

**DEV (pve-2 / VM-210):**

| Script | Runs on | Purpose |
|--------|---------|---------|
| `01-verify-dev-zfs.sh` | pve-2 | Validate ZFS datasets |
| `02-setup-directory-mappings.sh` | pve-2 | Create Proxmox directory resource mappings |
| `03-create-vm-210.sh` | pve-2 | Create VM with q35, virtiofs, Ignition |
| `04-restore-postgres.sh` | Workstation | Restore PostgreSQL from SQL dump |
| `05-restore-neo4j.sh` | Workstation | Restore Neo4j from dump file |
| `06-restore-qdrant.sh` | Workstation | Restore Qdrant from snapshot |
| `07-validate-parity.sh` | Workstation | Side-by-side validation |

**PROD (pve-1 / VM-110):**

| Script | Runs on | Purpose |
|--------|---------|---------|
| `01-create-prod-zfs.sh` | pve-1 | Create ZFS pool + datasets |
| `02-setup-prod-directory-mappings.sh` | pve-1 | Create PROD directory mappings |
| `03-create-vm-110.sh` | pve-1 | Create VM with q35, virtiofs, Ignition |
| `04-restore-postgres.sh` | Workstation | Restore PostgreSQL from SQL dump |
| `05-restore-neo4j.sh` | Workstation | Restore Neo4j from dump file |
| `06-restore-qdrant.sh` | Workstation | Restore Qdrant from snapshot |
| `07-validate-prod.sh` | Workstation | Full validation + DEV comparison |

**App VMs (VM-120, VM-220):**

| Script | Runs on | Purpose |
|--------|---------|---------|
| `create-vm-120.sh` | pve-1 | Create PROD App VM |
| `create-vm-220.sh` | pve-2 | Create DEV App VM |

**Infrastructure LXCs (pve-3):**

| Script | Runs on | Purpose |
|--------|---------|---------|
| `01-create-pihole-lxc.sh` | pve-3 | Create CT-311 Pi-hole LXC |
| `02-install-pihole.sh` | CT-311 | Install and configure Pi-hole v6 |
| `01-create-cloudflared-lxc.sh` | pve-3 | Create CT-312 cloudflared LXC |
| `02-install-cloudflared.sh` | CT-312 | Install cloudflared, configure tunnel |
| `01-create-traefik-lxc.sh` | pve-3 | Create CT-313 Traefik LXC |
| `02-install-traefik.sh` | CT-313 | Install Traefik, write configs, obtain LE cert |

### 16.3 Traefik Configuration (CT-313)

| File | Hot-reload? | Purpose |
|------|-------------|---------|
| `/etc/traefik/traefik.yml` | No (restart) | Static config: entrypoints, ACME, providers |
| `/etc/traefik/dynamic/services.yml` | Yes | Routers, services, middlewares |
| `/etc/traefik/dynamic/tls.yml` | Yes | TLS options (min version) |
| `/etc/traefik/cloudflare.env` | No (restart) | Cloudflare API token for DNS-01 |
| `/etc/traefik/acme.json` | — | Let's Encrypt certificate storage |

### 16.4 Documentation

| Document | Status | Purpose |
|----------|--------|---------|
| This document (Master Context v3) | **ACTIVE** | Canonical project reference |
| `COLOSSUS_PROXMOX_CLUSTER_DESIGN_v1.2.md` | **ACTIVE** | Cluster architecture |
| `COLOSSUS_COREOS_VM_CREATION_RUNBOOK_v1.md` | **ACTIVE** | Repeatable VM creation procedure |
| `COLOSSUS_DEV_BACKUP_RESTORE_RUNBOOK_v1.md` | **ACTIVE** | Backup/restore procedures for all 3 DBs |
| `COLOSSUS_EDGE_DNS_CLOUDFLARE_TECHNICAL_DESIGN_v1.0.md` | **ACTIVE** | Edge services technical design |
| `COLOSSUS_TRAEFIK_EXECUTION_RUNBOOK_v1.md` | **ACTIVE** | Traefik deployment procedure |
| `APPLICATION_DEPLOYMENT_REQUIREMENTS.md` | **ACTIVE** | App containerization requirements |
| `DEPLOYMENT.md` | **ACTIVE** | Deployment procedures |
| `PHASE4_SESSION_TRANSITION.md` | **REFERENCE** | Phase 4 implementation record |
| `PHASE5_AUTOMATION_TOOLING_SESSION_TRANSITION.md` | **REFERENCE** | Phase 5 tooling research |
| `colossus_transition_execution_plan_v_1.md` | **REFERENCE** | Original Phase 1–6 strategy |

### 16.5 Retired Documents

| Document | Reason |
|----------|--------|
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v2.md` | Superseded by v3 |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT.md` | Superseded by v3 |
| `VM200_EXTERNALIZATION_RUNBOOK_v1.2.md` | Described in-place migration; we did parallel rebuild |
| `COLOSSUS_EDGE_DNS_CLOUDFLARE_EXECUTION_TASK_TRACKER_v1.0.md` | Edge services execution complete |
| `PHASE-2-EXECUTION-CHECKLIST.md` | All items checked off |
| `PHASE_2_SESSION_TRANSITION.md` | Phase 2 complete |
| `PHASE_3_SESSION_TRANSITION.md` | Phase 3 complete |

### 16.6 Credentials & Secrets Reference

| Secret | Location | Notes |
|--------|----------|-------|
| Neo4j password (DEV) | VM-220 `/var/home/core/colossus/backend.env` | Contains `$` — no quotes |
| Neo4j password (PROD) | VM-120 `/var/home/core/colossus/backend.env` | Contains `$` — no quotes |
| Cloudflare Tunnel token | CT-312 (embedded via `cloudflared service install`) | Managed by Cloudflare |
| Cloudflare DNS API token | CT-313 `/etc/traefik/cloudflare.env` | DNS-01 challenge for LE certs |
| ghcr.io access | Public — no auth needed | Images are public |
| SSH key | `ssh-ed25519 AAAAC3...mUpD6 roman@proxima-centauri` | Used for all CoreOS VMs |

---


## 17. VM/CT Inventory

| ID | Name | Type | Node | IP | Role | Status |
|----|------|------|------|----|------|--------|
| 110 | `colossus-prod-db1` | VM | pve-1 | 10.10.100.110 | PROD DB (Neo4j, Postgres, Qdrant) | Running |
| 120 | `colossus-prod-app1` | VM | pve-1 | 10.10.100.120 | PROD App (backend + frontend) | Running |
| 200 | `colossus-db1-dev` | VM | pve-2 | 10.10.100.50 | Frozen DEV reference | Running (do not modify) |
| 210 | `colossus-dev-db1` | VM | pve-2 | 10.10.100.200 | Active DEV DB host | Running |
| 220 | `colossus-dev-app1` | VM | pve-2 | 10.10.100.220 | DEV App (backend + frontend) | Running |
| 311 | `pihole` | CT | pve-3 | 10.10.100.53 | Pi-hole v6 DNS | Running |
| 312 | `cloudflared` | CT | pve-3 | 10.10.100.54 | Cloudflare Tunnel connector | Running |
| 313 | `traefik` | CT | pve-3 | 10.10.100.55 | Traefik v3 reverse proxy | Running |
| 900 | PBS | VM | pve-3 | — | Proxmox Backup Server | Running |

### 17.1 Node Role Summary

```
pve-1 (PROD)              pve-2 (DEV)               pve-3 (Infra/Services)
├── VM-110 PROD DB         ├── VM-200 Frozen ref      ├── VM-900 PBS
├── VM-120 PROD App        ├── VM-210 DEV DB          ├── CT-311 Pi-hole
                           ├── VM-220 DEV App         ├── CT-312 cloudflared
                                                      ├── CT-313 Traefik
```

### 17.2 Container Images

| Image | Tag | Visibility | Notes |
|-------|-----|------------|-------|
| `ghcr.io/rhrywnak/colossus-backend` | v0.1.0, latest | Public | Rust/Axum, CORS env var |
| `ghcr.io/rhrywnak/colossus-frontend` | v0.1.0, latest | Public | React/nginx, runtime config |

---

## 18. Network

### 18.1 IP Assignments

| ID | Name | IP | Method |
|----|------|----|--------|
| VM-110 | colossus-prod-db1 | 10.10.100.110 | Static (Ignition) |
| VM-120 | colossus-prod-app1 | 10.10.100.120 | Static (Ignition) |
| VM-200 | colossus-db1-dev | 10.10.100.50 | Existing |
| VM-210 | colossus-dev-db1 | 10.10.100.200 | DHCP |
| VM-220 | colossus-dev-app1 | 10.10.100.220 | Static (Ignition) |
| CT-311 | pihole | 10.10.100.53 | Static (LXC config) |
| CT-312 | cloudflared | 10.10.100.54 | Static (LXC config) |
| CT-313 | traefik | 10.10.100.55 | Static (LXC config) |

### 18.2 DNS (Pi-hole Split-Horizon)

All `*.cogmai.com` hostnames resolve to Traefik (10.10.100.55) internally via Pi-hole.
External resolution via Cloudflare DNS points to Cloudflare's edge (tunnel).

| Hostname | Internal (Pi-hole) | External (Cloudflare) |
|----------|-------------------|----------------------|
| colossus-legal.cogmai.com | 10.10.100.55 | Cloudflare Tunnel → Traefik |
| colossus-legal-api.cogmai.com | 10.10.100.55 | Cloudflare Tunnel → Traefik |
| colossus-legal-dev.cogmai.com | 10.10.100.55 | N/A (LAN only) |
| colossus-legal-api-dev.cogmai.com | 10.10.100.55 | N/A (LAN only) |
| traefik.cogmai.com | 10.10.100.55 | N/A (LAN only) |
| pihole.cogmai.com | 10.10.100.53 | N/A (LAN only) |

### 18.3 Traffic Flow

**External (phone/cellular):**
```
Browser → Cloudflare Edge (TLS) → Tunnel → CT-312 → CT-313 Traefik (HTTP:80) → VM-120
```

**Internal (LAN workstation):**
```
Browser → Pi-hole DNS → CT-313 Traefik (HTTPS:443, LE cert) → VM-120/VM-220
```

---

## 19. Backup Configuration

| ID | Name | Backup Target | Schedule | Status |
|----|------|---------------|----------|--------|
| VM-110 | colossus-prod-db1 | pbs-zfs | Daily (automatic) | Active |
| VM-120 | colossus-prod-app1 | pbs-zfs | — | Manual |
| VM-210 | colossus-dev-db1 | pbs-zfs | — | Manual as needed |
| VM-220 | colossus-dev-app1 | pbs-zfs | — | Manual |
| CT-311 | pihole | pbs-zfs | — | Manual |
| CT-312 | cloudflared | pbs-zfs | — | Manual |
| CT-313 | traefik | pbs-zfs | — | Phase 5A initial backup taken |

PBS retention policy: daily 14, weekly 8, monthly 12.
---

## 20. Success Criteria

The Colossus homelab is successful if:

- Any DB VM can be rebuilt from scratch in under an hour
- Data restoration is documented and boring
- No step relies on memory
- Long pauses do not cause relearning
- DEV â†’ PROD parity is mechanical, not conceptual

**Phase 3 validates all five criteria.** PROD was deployed mechanically from DEV artifacts in two sessions.

---

## 21. Final Rule

> If execution deviates from this document, stop and update the document â€” not the system.
