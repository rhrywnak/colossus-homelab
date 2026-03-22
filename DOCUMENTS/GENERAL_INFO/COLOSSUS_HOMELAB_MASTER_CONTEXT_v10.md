# Colossus Homelab — Master Context & Architecture Reference

**Project Name:** Colossus
**Scope:** On-prem Proxmox homelab for containerized databases, LLM infrastructure, and agentic systems
**Audience:** Primary operator, future collaborators, future self
**Document Type:** Canonical context + architecture reference
**Last Updated:** 2026-03-22 (v10 — pve-3 migration complete, monitoring stack offline for redesign, Alloy agents stopped, Authentik backup gap closed)

---

## 1. Purpose of This Document

This document exists to:

1. Define **why** the Colossus homelab exists
2. Describe **what was designed and built**
3. Record the **current state** of all infrastructure
4. Enumerate **what remains to be done**

This document is **authoritative**. If reality diverges from this document, execution must pause and the document must be updated first.

**What this document is NOT:** a task tracker, session log, or execution checklist. Those belong in session transition documents and project-specific trackers.

---

## 2. Objectives

### 2.1 Primary Objectives

The Colossus homelab is designed to:

- Provide a **reproducible, deterministic infrastructure** for databases (PostgreSQL, Neo4j, Qdrant), vector search, knowledge graphs, and LLM inference
- Support **parallel environments** (DEV → PROD) without in-place mutation
- Enable **safe rebuilds** instead of fragile upgrades
- Make infrastructure **boring, inspectable, and scriptable**
- Allow long pauses in work without loss of understanding

### 2.2 Explicit Non-Goals

The homelab is **not** intended to be Kubernetes-based, click-ops driven, tuned for maximum density, a high-availability enterprise cluster, or continuously modified in place. Correctness, recoverability, and clarity are prioritized over performance.

---

## 3. Design Principles (Hard Rules)

1. **Rebuild > mutate**
2. **Data lives outside the VM** (the golden rule — no persistent data inside containers or VMs)
3. **VMs are disposable; datasets are not**
4. **systemd controls lifecycle, not humans**
5. **Everything important must be scriptable**
6. **Parallel validation before cutover**
7. **No silent assumptions**
8. **Production must be reproducible from DEV artifacts**
9. **"We never do the quick path. It always comes back to bite us."**

---

## 4. High-Level Architecture

### 4.1 Physical Layer

| Node | Hardware | Role |
|------|----------|------|
| pve-1 | Ultra 9 285HX | Production workloads |
| pve-2 | Ryzen 7 5700U | Development workloads |
| pve-3 | Minisforum MS-01 (replaced Dell 7810, March 2026) | Infrastructure services + PBS |

Roles are **exclusive**. No node serves mixed responsibilities.

### 4.2 Virtualization Layer

- Proxmox VE cluster (`colossus`), 3 nodes, quorum 3/3
- VM lifecycle controlled via `qm` CLI — no UI-only configuration considered authoritative
- **Machine type `q35` is required** for VMs using virtiofs

### 4.3 Operating System Standard

**Fedora CoreOS** is the only supported OS for service VMs. Reasons: immutable base, Ignition-driven provisioning, deterministic startup, container-native lifecycle.

All configuration is expressed via Butane → Ignition, Podman Quadlet (`.container` files), and systemd mount units.

**LXC containers** use Debian and run native services (no Docker/Podman inside LXC).

---

## 5. Storage Architecture

### 5.1 Host-Level Storage (ZFS)

One pool per environment, separate datasets per service:

```
dev-zfs/          (pve-2, Crucial MX500 2TB SATA SSD)
├── postgres      recordsize=16K, compression=zstd
├── neo4j         recordsize=1M, compression=zstd
├── qdrant        recordsize=128K, compression=zstd
├── legal-docs    compression=zstd (PDFs + prompt files)
└── models        compression=zstd (ONNX model cache)

prod-zfs/         (pve-1, Crucial T500 2TB NVMe)
├── postgres      recordsize=16K, compression=zstd
├── neo4j         recordsize=1M, compression=zstd
├── qdrant        recordsize=128K, compression=zstd
├── legal-docs    compression=zstd (PDFs + prompt files)
└── models        compression=zstd (ONNX model cache)

pbs-zfs/          (pve-3, local SSD)
├── services/authentik/postgres    Authentik PostgreSQL database
├── services/authentik/media       Authentik media files
├── services/authentik/templates   Authentik email templates
├── services/semaphore/data        Semaphore database + config
└── datastore/                     PBS backup staging area
```

### 5.2 VM-Level Access (virtiofs)

virtiofs mounts host ZFS datasets into CoreOS VMs. VM root filesystems never contain authoritative data. All persistent state resides on the Proxmox host.

Requirements: Proxmox **directory resource mappings** (`pvesh create /cluster/mapping/dir`), **q35 machine type**, VM reboot after adding new virtiofs shares (not hot-pluggable).

### 5.3 SELinux and virtiofs (Critical)

Fedora CoreOS runs SELinux in **enforcing mode**. virtiofs mounts appear with context `virtiofs_t`, which containers (`container_t`) cannot access.

**Required fix:** All virtiofs systemd mount units must include:
```ini
Options=context="system_u:object_r:container_file_t:s0"
```

What does NOT work on virtiofs: `:z` or `:Z` volume flags, `chcon` / `restorecon` (no xattr passthrough). For one-shot admin containers (e.g., neo4j-admin restore), use `--security-opt label=disable`.

### 5.4 App VM Document Storage

Application VMs (VM-120, VM-220) mount externalized document storage via virtiofs:

- ZFS datasets: `dev-zfs/legal-docs` (pve-2), `prod-zfs/legal-docs` (pve-1)
- Proxmox directory mappings: `dev-legal-docs`, `prod-legal-docs`
- Guest mount point: `/var/mnt/data/legal-docs` (systemd mount unit in Butane)
- Podman volume: `/mnt/data/legal-docs:/data/documents:rw` (Ansible-managed Quadlet)
- SELinux: `context="system_u:object_r:container_file_t:s0"` on mount unit

**VM CPU requirement:** All app VMs running colossus-legal **must** use `--cpu host` due to ONNX Runtime requiring AVX2 instructions.

### 5.5 TrueNAS Storage

TrueNAS appliance (TerraMaster F4-423): 4x 4TB HDD, 2x mirror vdevs (RAID10), 7.13 TiB usable, IP 10.10.0.38.

```
Pool-1/
├── backups/
│   ├── pbs-sync/          PBS backup replication target (NFS → PBS)
│   └── zfs-replica/       ZFS snapshot replication target (all 3 hosts)
├── iso/                   Proxmox ISO library (NFS → all nodes)
├── templates/             VM templates, container images (NFS → all nodes)
├── cold/                  Future: staging area for cold backup to USB
└── scratch/               General workspace
```

### 5.6 Path Conventions (CoreOS)

On CoreOS, `/mnt` is a symlink to `/var/mnt`. systemd mount units MUST use `/var/mnt/data/{service}` (canonical path). Container volume mounts and SSH commands can use `/mnt/data/{service}`.

---

## 6. Container Model

- **Runtime:** Podman (rootful), managed via Podman Quadlet (`.container` files in `/etc/containers/systemd/`)
- **Lifecycle:** Containers are disposable, images are replaceable, data is external and persistent
- **Configuration:** Quadlet files declare image/ports/volumes/dependencies; environment files in `/etc/colossus/env/`; systemd mount units wire virtiofs; all delivered via Butane → Ignition on first boot
- **Rule:** No ad-hoc `podman run` usage. Ansible manages Quadlet files for application deployments.

---

## 7. Databases

| Service | Image | Ports | UID:GID | DEV Dataset | PROD Dataset |
|---------|-------|-------|---------|-------------|--------------|
| PostgreSQL 17 | `docker.io/library/postgres:17` | 5432 | 999:999 | `dev-zfs/postgres` | `prod-zfs/postgres` |
| Neo4j 5 | `docker.io/library/neo4j:5` | 7474, 7687 | 7474:7474 | `dev-zfs/neo4j` | `prod-zfs/neo4j` |
| Qdrant | `docker.io/qdrant/qdrant:latest` | 6333, 6334 | 1000:1000 | `dev-zfs/qdrant` | `prod-zfs/qdrant` |

Lifecycle: external storage mounted → empty container started → data restored from backups → validated → put into service.

---

## 8. VM/CT Inventory

| ID | Name | Type | Node | IP | Role | Status |
|----|------|------|------|----|------|--------|
| 110 | colossus-prod-db1 | VM | pve-1 | 10.10.100.110 | PROD DB (Neo4j, Postgres, Qdrant) | Running |
| 120 | colossus-prod-app1 | VM | pve-1 | 10.10.100.120 | PROD App (backend + frontend) | Running |
| 210 | colossus-dev-db1 | VM | pve-2 | 10.10.100.200 | DEV DB (Neo4j, Postgres, Qdrant) | Running |
| 220 | colossus-dev-app1 | VM | pve-2 | 10.10.100.220 | DEV App (backend + frontend) | Running |
| 311 | pihole | CT | pve-3 | 10.10.100.53 | Pi-hole v6 DNS | Running |
| 312 | cloudflared | CT | pve-3 | 10.10.100.54 | Cloudflare Tunnel connector | Running |
| 313 | traefik | CT | pve-3 | 10.10.100.55 | Traefik v3 reverse proxy | Running |
| 314 | monitoring | VM | pve-3 | 10.10.100.56 | Monitoring (offline — redesign pending) | Stopped |
| 315 | semaphore | CT | pve-3 | 10.10.100.57 | Semaphore UI runbook automation | Running |
| 316 | authentik | VM | pve-3 | 10.10.100.58 | Authentik identity provider (SSO) | Running |
| 900 | PBS | VM | pve-3 | 10.10.100.242 | Proxmox Backup Server | Running |
| — | truenas | Appliance | Standalone | 10.10.0.38 | NAS / backup secondary | Running |

```
pve-1 (PROD)              pve-2 (DEV)               pve-3 (Infra/Services)
├── VM-110 PROD DB         ├── VM-210 DEV DB          ├── VM-900 PBS
└── VM-120 PROD App        └── VM-220 DEV App         ├── VM-314 Monitoring (stopped)
                                                      ├── VM-316 Authentik
                                                      ├── CT-311 Pi-hole
                                                      ├── CT-312 cloudflared
                                                      ├── CT-313 Traefik
                                                      └── CT-315 Semaphore
```

### 8.1 Container Images (colossus-legal)

| Image | Tag | Base | Notes |
|-------|-----|------|-------|
| `ghcr.io/rhrywnak/colossus-backend` | v0.7.5, latest | Ubuntu 24.04, Rust 1.88, ONNX Runtime (AVX2) | `cargo build --locked`, `--no-cache` |
| `ghcr.io/rhrywnak/colossus-frontend` | v0.7.5, latest | React/nginx, runtime config.js via Ansible | |

---

## 9. Network

### 9.1 IP Assignments

| ID | Name | IP | Method |
|----|------|----|--------|
| — | pve-1 | 10.10.100.3 | Static |
| — | pve-2 | 10.10.100.2 | Static |
| — | pve-3 | 10.10.100.5 | Static |
| VM-110 | colossus-prod-db1 | 10.10.100.110 | Static (Ignition) |
| VM-120 | colossus-prod-app1 | 10.10.100.120 | Static (Ignition) |
| VM-210 | colossus-dev-db1 | 10.10.100.200 | DHCP |
| VM-220 | colossus-dev-app1 | 10.10.100.220 | Static (Ignition) |
| CT-311 | pihole | 10.10.100.53 | Static (LXC config) |
| CT-312 | cloudflared | 10.10.100.54 | Static (LXC config) |
| CT-313 | traefik | 10.10.100.55 | Static (LXC config) |
| VM-314 | monitoring | 10.10.100.56 | Static (Ignition) |
| CT-315 | semaphore | 10.10.100.57 | Static (LXC config) |
| VM-316 | authentik | 10.10.100.58 | Static (Ignition) |
| VM-900 | PBS | 10.10.100.242 | Static |
| — | TrueNAS | 10.10.0.38 | Static (LAN subnet) |
| — | proxima-centauri | 10.10.0.99 | DHCP reservation |

### 9.2 DNS (Pi-hole Split-Horizon)

All `*.cogmai.com` hostnames resolve to Traefik (10.10.100.55) internally via Pi-hole. External resolution via Cloudflare DNS points to Cloudflare's edge (tunnel).

| Hostname | Internal | External |
|----------|----------|----------|
| colossus-legal.cogmai.com | 10.10.100.55 | Cloudflare Tunnel → Traefik |
| colossus-legal-api.cogmai.com | 10.10.100.55 | Cloudflare Tunnel → Traefik |
| colossus-legal-dev.cogmai.com | 10.10.100.55 | LAN only |
| colossus-legal-api-dev.cogmai.com | 10.10.100.55 | LAN only |
| auth.cogmai.com | 10.10.100.55 | Cloudflare Tunnel → Traefik |
| traefik.cogmai.com | 10.10.100.55 | LAN only |
| grafana.cogmai.com | 10.10.100.55 | LAN only |
| semaphore.cogmai.com | 10.10.100.55 | LAN only |

### 9.3 Traffic Flow

**External (phone/cellular):** Browser → Cloudflare Edge (TLS) → Tunnel → CT-312 → CT-313 Traefik (HTTP:80) → backend VM

**Internal (LAN):** Browser → Pi-hole DNS → CT-313 Traefik (HTTPS:443, LE wildcard cert) → backend VM

**Authentication:** Traefik ForwardAuth middleware → VM-316 Authentik (:9000) → if no session, redirect to auth.cogmai.com; if valid session, inject `X-authentik-*` headers and forward to backend.

All Cloudflare Tunnel routes point to Traefik at `http://10.10.100.55:80` — never directly to app VMs.

### 9.4 Traefik Routers

| Host | Backend | Auth |
|------|---------|------|
| colossus-legal.cogmai.com | http://10.10.100.120:5473 | Authentik ForwardAuth |
| colossus-legal-api.cogmai.com | http://10.10.100.120:3403 | Authentik ForwardAuth |
| colossus-legal-dev.cogmai.com | http://10.10.100.220:5473 | Authentik ForwardAuth |
| colossus-legal-api-dev.cogmai.com | http://10.10.100.220:3403 | Authentik ForwardAuth |
| auth.cogmai.com | http://10.10.100.58:9000 | None (is the auth provider) |
| grafana.cogmai.com | http://10.10.100.56:3000 | Cloudflare Access |
| semaphore.cogmai.com | http://10.10.100.57:3000 | Cloudflare Access |
| traefik.cogmai.com | Traefik dashboard | Cloudflare Access |

### 9.5 Management Infrastructure

**Control nodes:** proxima-centauri (10.10.0.99, workstation) and CT-315 Semaphore (10.10.100.57, automation).

**SSH keys:**

| Key | Auth | Purpose |
|-----|------|---------|
| `id_ed25519` | Passphrase-protected | Interactive use from workstation |
| `semaphore_infra_key` | Passphrase-free | Semaphore automation (all 13 hosts) |
| `semaphore_deploy_key` | Passphrase-free | GitHub repo read-only access |

**SSH access:** root on Proxmox/LXC/PBS hosts, core on CoreOS VMs. TrueNAS SSH is disabled (web shell only). SSH multiplexing configured (`ControlMaster auto`, `ControlPersist 120s`).

### 9.6 UniFi Network Security

UniFi UDM SE with IPS in "Notify and Block" mode. Detection exclusions for `10.10.100.0/24` (homelab VLAN) and `10.10.0.0/24` (main/NAS network) prevent false positives on legitimate internal traffic.

---

## 10. Automation (Ansible + Semaphore)

### 10.1 Repository

`colossus-ansible` (GitHub, private). Control node: `~/Projects/colossus-ansible/` on proxima-centauri. Vault secrets in `inventory/group_vars/all/vault.yml` (single source of truth).

**Critical rule:** Always run `git show HEAD:<path> | cat` before editing any Ansible file. Git is the only source of truth.

### 10.2 Inventory Groups

```
@all
├── @proxmox          (pve-1, pve-2, pve-3)
├── @coreos_vms
│   ├── @db_vms       (colossus-prod-db1, colossus-dev-db1)
│   ├── @app_vms      (colossus-prod-app1, colossus-dev-app1)
│   └── @auth_vms     (authentik)
├── @infrastructure   (pihole, cloudflared, traefik, semaphore)
├── @backup           (pbs)
├── @storage          (truenas — SSH disabled, unmanaged)
├── @dev              (colossus-dev-db1, colossus-dev-app1)
└── @prod             (colossus-prod-db1, colossus-prod-app1)
```

### 10.3 Roles

| Role | Target | Purpose |
|------|--------|---------|
| deploy-app | App VMs | Generic app deployment (pull image, update Quadlet, restart) |
| colossus-legal | App VMs | App-specific config (Quadlet files, env, config.js) |
| alloy-agent | All managed hosts | Grafana Alloy monitoring agent (currently stopped fleet-wide) |
| semaphore | CT-315 | Semaphore UI deployment |
| pihole-dns | CT-311 | Pi-hole DNS record management |
| pihole | CT-311 | Pi-hole installation and configuration |
| traefik-route | CT-313 | Traefik dynamic routing configuration |
| traefik | CT-313 | Traefik binary installation and static config |
| cloudflared | CT-312 | cloudflared installation and tunnel registration |
| pbs-backup | Proxmox | PBS backup job management (/etc/pve/jobs.cfg) |
| pbs | VM-900 | PBS server installation and datastore configuration |
| proxmox-vm | Proxmox | CoreOS VM creation (qm commands) |
| proxmox-lxc | Proxmox | LXC container creation |
| zfs-replicate | Proxmox | ZFS snapshot replication to TrueNAS |

### 10.4 Key Playbooks

| Playbook | Purpose |
|----------|---------|
| deploy-app.yml | Deploy any app version to DEV or PROD |
| rollback-app.yml | Rollback to previous version |
| validate-all.yml | Fleet health check (daily 06:00 via Semaphore) |
| verify-backups.yml | PBS backup verification (daily 08:00) |
| drift-detect.yml | Config drift detection (weekly Sun 03:00) |
| manage-pbs-backups.yml | Template /etc/pve/jobs.cfg from inventory |
| manage-pihole.yml | Sync Pi-hole DNS records from inventory |
| manage-traefik.yml | Sync Traefik routes from inventory |
| deploy-zfs-replicate.yml | Deploy ZFS replication configs + timers |
| neo4j-sync-full.yml | Full Neo4j DEV→PROD sync |
| postgres-sync.yml | PostgreSQL DEV→PROD sync |
| qdrant-sync.yml | Qdrant DEV→PROD sync |
| stop-alloy.yml | Stop/disable all Alloy agents fleet-wide |
| provision-pihole.yml | Full Pi-hole CT provisioning |
| provision-cloudflared.yml | Full cloudflared CT provisioning |
| provision-traefik.yml | Full Traefik CT provisioning |
| create-vm.yml | Create CoreOS VM from vars file |
| create-pbs-vm.yml | Create PBS VM (post-ISO-install config) |

### 10.5 Semaphore Templates

16+ templates configured in Semaphore UI at `semaphore.cogmai.com`. Includes deploy templates (DEV + PROD), all 3 database sync operations, Neo4j multi-phase sync (7 stages + rollback), and 3 scheduled recurring jobs (health check, backup verify, drift detect).

Application deployments go exclusively through Semaphore UI.

---

## 11. Backup Configuration

### 11.1 PBS Backup Jobs

All VMs/CTs backed up daily to PBS datastore `pbs-staging` (virtiofs-mounted ZFS on pve-3). Configured in `/etc/pve/jobs.cfg` (cluster-wide), managed by `manage-pbs-backups.yml`.

| Job ID | VMID | Name | Status |
|--------|------|------|--------|
| backup-prod-db | 110 | colossus-prod-db1 | Active |
| backup-prod-app | 120 | colossus-prod-app1 | Active |
| backup-dev-db | 210 | colossus-dev-db1 | Active |
| backup-dev-app | 220 | colossus-dev-app1 | Active |
| backup-pihole | 311 | pihole | Active |
| backup-cloudflared | 312 | cloudflared | Active |
| backup-traefik | 313 | traefik | Active |
| backup-monitoring | 314 | monitoring | Active |
| backup-semaphore | 315 | semaphore | Active |
| backup-authentik | 316 | authentik | Active |

**Not backed up:** VM-900 (PBS) — cannot back up to itself; rebuildable from config + Ansible.

### 11.2 PBS Replication to TrueNAS

Sync job `staging-to-truenas` runs daily at 02:00, replicating all backup data from `pbs-staging` to `truenas-sync` (NFS-mounted TrueNAS RAID10 HDD). TrueNAS ZFS snapshots of the pbs-sync dataset run every 6 hours with 1-week retention (ransomware protection).

### 11.3 ZFS Snapshot Replication

Daily ZFS snapshots replicated to TrueNAS via `roles/zfs-replicate/`. Runs at 03:00 via systemd timers on each Proxmox host, staggered by up to 15 minutes. Local retention: 7 days. Remote retention: 14 days.

Datasets replicated: all database datasets (postgres, neo4j, qdrant) on pve-1 and pve-2, legal-docs and models on both, plus Authentik datasets on pve-3. Total: ~14 datasets across 3 hosts.

### 11.4 Backup Data Flow

```
Proxmox vzdump (10 VMs/CTs) → pbs-staging (SSD) → truenas-sync (HDD)
                                                    ↓
                                            TrueNAS ZFS snapshots (independent)

ZFS datasets (all 3 hosts) → TrueNAS zfs-replica/ (daily incremental)
```

**Important:** PBS vzdump captures VM/CT filesystems only. virtiofs-mounted ZFS datasets (databases, documents, models) require the separate ZFS replication strategy above. Both are needed for complete recovery.

---

## 12. Authentication (Authentik)

Authentik (VM-316) provides SSO via ForwardAuth middleware in Traefik. Proxy cookie set on `.cogmai.com` domain covers all subdomains.

**Users:** akadmin (system admin), Roman (non-expiring), Chuck and Marie (demo users, external access).

**Groups:** admin, legal_editor, legal_viewer, ai_user.

**External access:** Cloudflare Access bypassed for user-facing apps (colossus-legal, auth.cogmai.com), kept active for infrastructure dashboards (Grafana, Semaphore, Traefik).

**Known bugs:** Outpost `sign_out` endpoint panics when proxy cookie present (bug #17922). Domain-level proxy cookies not cleaned up on logout (issue #1113). Correct logout: OIDC end-session endpoint at `https://auth.cogmai.com/application/o/colossus-services/end-session/`.

**Self-service:** Locked down (username/email changes disabled). Password change: `https://auth.cogmai.com/if/user/`. Admin: `https://auth.cogmai.com/if/admin/`.

---

## 13. Project History

This section summarizes completed phases. Detailed execution records are in session transition documents.

**Phase 1 — Backups & PBS (2026-02-05).** Proxmox Backup Server configured on VM-900 (pve-3). Database backups created and verified. Foundation for all subsequent work.

**Phase 2 — DEV Environment (2026-02-08).** ZFS pool `dev-zfs` created on pve-2. VM-210 (colossus-dev-db1) deployed via scripted `qm` commands with Butane/Ignition. All three database containers running via Quadlet. SELinux + virtiofs interaction discovered and documented. Key lesson: virtiofs mounts require `context=` option for container access.

**Phase 3 — PROD Environment (2026-02-08–09).** PROD deployed mechanically from adapted DEV artifacts — zero new design decisions. VM-110 on pve-1, all three databases running, DEV/PROD parity confirmed (25 PostgreSQL tables, 207 Neo4j nodes, 287 Qdrant points). Validated that CoreOS auto-updates are non-destructive.

**Phase 4A — Application Deployment (2026-02-11).** Colossus-Legal containerized (Rust/Axum backend + React/nginx frontend). VM-220 (DEV) and VM-120 (PROD) deployed. Key lesson: Podman EnvironmentFile treats quotes as literal characters.

**Phase 4B — Edge Services (2026-02-11).** Domain `cogmai.com` registered. Pi-hole (CT-311), cloudflared (CT-312) deployed. Cloudflare Tunnel with split-horizon DNS. Key lesson: Pi-hole v6 changed DNS management to `dns.hosts` setting.

**Phase 5A — Traefik Reverse Proxy (2026-02-12).** CT-313 deployed. Let's Encrypt wildcard certificate via DNS-01 (Cloudflare). TLS termination for all traffic. HTTP catch-all redirect with explicit tunnel routes to prevent redirect loops.

**Phase 5B-1 — Ansible Foundation (2026-02-14).** Ansible installed on proxima-centauri. SSH keys deployed to all hosts. Inventory, vault, validation playbook. Key lesson: UniFi IPS blocks legitimate cross-VLAN traffic — detection exclusions required.

**TrueNAS Integration (2026-02-13).** TrueNAS integrated as secondary backup target. PBS sync job, ISO library, NFS shares. Key lesson: PBS chunk store creation is extremely slow over NFS.

**Phase 6A — Monitoring Stack (2026-02-13–16).** VM-314 deployed with Prometheus, Grafana, Loki, Alertmanager. Grafana Alloy agents on all 12 managed hosts. 18 Prometheus scrape targets. TrueNAS Graphite metrics. **Note:** Monitoring stack is currently offline pending redesign to OpenObserve + custom Rust agents. Alloy agents stopped fleet-wide (2026-03-22).

**Phase 7A — Semaphore UI (2026-02-18–20).** CT-315 deployed. Neo4j sync playbooks (7 phases + rollback), PostgreSQL and Qdrant sync playbooks, 3 scheduled recurring jobs, 16 templates total. Key lesson: externalize CT storage to ZFS bind mounts; Proxmox resets ownership on `pct start`.

**App Deploy Pipeline (2026-02-21).** build-release.sh rewritten, Ansible deploy-app role, Semaphore deploy templates for DEV + PROD. Key lesson: `cargo build --locked` prevents surprise crate upgrades.

**App VM Document Storage (2026-02-24–26, v0.3.2).** Externalized document storage via virtiofs. Dockerfile migrated to Ubuntu 24.04 / Rust 1.88 for ONNX Runtime compatibility. Key lesson: VM CPU type `kvm64` lacks AVX2 — always use `--cpu host`.

**Authentication Gateway (2026-02-26–03-01).** Authelia evaluated and rejected (no admin UI, no forced password change). Authentik deployed on VM-316 (CoreOS, Podman Quadlet). Ansible `configure-authentik` role (18 files). Key lesson: evaluate operational workflow, not just architecture.

**DR Runbooks (2026-03-01).** All 6 pve-3 infrastructure hosts documented with rebuild procedures. Full pve-3 meltdown priority matrix (~60-75 min total rebuild).

**DEV→PROD Database Sync (2026-03-12, v0.7.5).** All three sync playbooks (Neo4j, PostgreSQL, Qdrant) executed via Semaphore. PROD models virtiofs mount provisioned. v0.7.5 deployed to PROD.

**ZFS Snapshot Replication (2026-03-13).** `roles/zfs-replicate/` deployed to all 3 hosts. 14 datasets replicated daily to TrueNAS via systemd timers.

**External Access & Auth Tuning (2026-03-13).** Cloudflare Access bypass for user-facing apps. Authentik ForwardAuth for external routes. Session and token durations tuned.

**PVE-3 Migration (2026-03-18–19).** Old Dell 7810 replaced with Minisforum MS-01. Full migration: Phase A (hardware validation, ZFS restore), Phase B (cluster cutover), Phase C (4 new Ansible provisioning roles: pihole, cloudflared, traefik, pbs), Phase D (VM creation: Authentik, Monitoring, PBS from ISO), Phase E (Alloy, ZFS replication, 13/13 hosts verified). Vault consolidated to single location. Key lessons: `pvecm add` refuses with existing guests; Pi-hole v6 `dns.listeningMode` defaults to `LOCAL`; PBS 4.1 uses systemd calendar schedule format.

---

## 14. Known Issues

**pve-1 igc NIC instability.** Intel i225/i226 NIC exhibits intermittent SSH stalls under burst traffic. Workaround: SSH connection multiplexing. Low priority — does not affect normal operation.

**CoreOS auto-updates.** Zincati enabled by default, reboots VMs without warning. Non-destructive (validated), but PROD maintenance windows should be configured.

**podman_login module fails with ghcr.io.** Returns 403; manual `podman login` works. deploy-app role has `ignore_errors: true`. No impact — images are public.

**Traefik HTTPS 500 when Authentik is down.** ForwardAuth middleware returns 500 if VM-316 is unreachable. Consider health-check middleware or graceful degradation.

---

## 15. Future Work

### Active / Near-Term

- **Monitoring redesign** — Replace Prometheus/Grafana/Loki/Alloy stack with OpenObserve (single Rust binary) + custom lightweight Rust agents (sysinfo crate, ~5MB per host) + AI analysis layer (Claude API for summaries/alerts). Priority is alerting (disk fail, backup fail, service down), not dashboards.
- **Codify Authentik configuration in Ansible** — currently manual UI setup
- **Store akadmin password in Ansible vault**
- **Header.tsx user profile link** — colossus-legal UI improvement
- **Authentik login branding**
- **Configuration audit** — reconcile live state of CT-311/312/313 with provisioning roles; eliminate drift from manual fixes

### Application Projects

- **colossus-legal** — Active focus. Rust/Axum backend + React frontend. Legal document processing with Neo4j, PostgreSQL, Qdrant.
- **colossus-observe** — Infrastructure monitoring + AI analysis platform. Rust/Axum + React + CLI. Inference provider trait abstraction (Claude API, Ollama, vLLM). Ties into monitoring redesign.
- **colossus-llm-observe** — LLM call tracing, eval benchmarks, prompt versioning, LLM-as-judge. Serves colossus-legal and colossus-ai. Rust/Axum + React + CLI.
- **colossus-ai** — arXiv paper reading, analysis, and tutorial generation (AI/Deep Learning focus). On hold until colossus-legal complete.

### Deferred

- **Remote dev environment VMs** — Per-project build VMs on pve-2 (+ Dell 7810). VS Code Remote SSH. CoreOS + Quadlet + Ignition + Ansible pattern.
- **Identity management decision** — Authelia vs. current Authentik (Authentik may be too heavy for 5-10 users)
- **NAS VLAN (10.10.40.0/24)** — Dedicated storage VLAN for TrueNAS traffic isolation
- **Cold/offline backup** — USB drive + ZFS send/recv for air-gapped 3-2-1 compliance
- **CoreOS update strategy** — Zincati maintenance window configuration for PROD

---

## 16. Key Operational Rules

These are hard-won lessons. Violating them costs hours.

- Always retrieve Ansible files via `git show HEAD:<path> | cat` before editing — never edit from memory
- Run all Ansible from `~/Projects/colossus-ansible/` — never from subdirectories
- `ansible.builtin.command` does not support shell pipes — use `ansible.builtin.shell` for any task with `|`
- virtiofs shares are not hot-pluggable — VM reboot required after adding new shares
- Proxmox resets bind mount ownership to `root:root` on `pct start` — fix in post-start scripts
- PBS vzdump captures VM/CT filesystems only — virtiofs-mounted ZFS datasets need separate backup
- Ignition is first-boot only — must destroy and recreate VMs to apply config changes
- Always `git push` before Semaphore deploys — Semaphore pulls from origin, not local
- Podman EnvironmentFile treats quotes as literal characters — never quote values
- Scripts with `qm` commands must run on Proxmox hosts, not workstation
- New VM/CT deployments must be immediately added to PBS backup schedules and ZFS replication
- `colossus-legal-api-dev.cogmai.com` must always be included alongside `colossus-legal-dev.cogmai.com`
- Qdrant health endpoint returns `"healthz check passed"` not `"ok"`
- Ansible `set_fact` and `vars` blocks do not persist across plays
- PBS installed from ISO (not Debian + apt) — role handles post-install config only
- PBS 4.1 schedule format: `*-*-* 03:00` (systemd calendar), not `daily 03:00`

---

## 17. Success Criteria

The Colossus homelab is successful if:

- Any VM can be rebuilt from scratch in under an hour
- Data restoration is documented and boring
- No step relies on memory
- Long pauses do not cause relearning
- DEV → PROD parity is mechanical, not conceptual

---

## 18. Final Rule

> If execution deviates from this document, stop and update the document — not the system.
