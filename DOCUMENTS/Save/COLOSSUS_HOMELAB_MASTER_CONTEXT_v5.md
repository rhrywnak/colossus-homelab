# Colossus Homelab — Master Context, Architecture, and Execution Plan

**Project Name:** Colossus  
**Scope:** On-prem Proxmox homelab for containerized databases, LLM infrastructure, and agentic systems  
**Audience:** Primary operator (authoritative), future collaborators, future self  
**Document Type:** Canonical context + execution reference  
**Status:** Living document with phase locks  
**Last Updated:** 2026-02-14 (Phase 5B-1 Ansible foundation complete, UniFi IPS exclusions configured)

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
- Support **parallel environments** (DEV → PROD) without in-place mutation
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
- Butane → Ignition
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
├── postgres      recordsize=16K, compression=zstd
├── neo4j         recordsize=1M, compression=zstd
└── qdrant        recordsize=128K, compression=zstd

prod-zfs/         (pve-1, Crucial T500 2TB NVMe)
├── postgres      recordsize=16K, compression=zstd
├── neo4j         recordsize=1M, compression=zstd
└── qdrant        recordsize=128K, compression=zstd
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


### 5.4 TrueNAS Storage (Secondary Backup + Shared Library)

TrueNAS appliance (TerraMaster F4-423) integrated as secondary backup target and shared storage.

**Hardware:** 4x 4TB HDD, 2x mirror vdevs (RAID10), 7.13 TiB usable, IP 10.10.0.38

**Dataset layout:**

```
Pool-1/
├── backups/
│   └── pbs-sync/          PBS backup replication target (NFS → PBS)
├── iso/                   Proxmox ISO library (NFS → all nodes)
├── templates/             VM templates, container images (NFS → all nodes)
├── cold/                  Future: staging area for cold backup to USB
└── scratch/               General workspace, experiments
```

**NFS shares (NFSv4):**
- `/mnt/Pool-1/backups/pbs-sync` → mounted in PBS VM-900 at `/mnt/truenas-pbs`
- `/mnt/Pool-1/iso` → Proxmox cluster storage `truenas-iso` (all nodes)
- `/mnt/Pool-1/templates` → Proxmox cluster storage `truenas-templates` (all nodes)

**ZFS snapshot tasks (TrueNAS-managed, independent of PBS):**
- pbs-sync: every 6 hours, 1 week retention (ransomware protection)
- iso: daily, 30 day retention
- templates: daily, 30 day retention

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
- All configuration delivered via Butane → Ignition on first boot
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

### 8.1 Phase 1 — Backups & PBS

- Proxmox Backup Server configured (VM-900 on pve-3)
- Database backups created and verified
- Off-host copies confirmed

**Status:** 🔒 Locked

---

### 8.2 Phase 2 — Preparation

- Migration strategy defined
- Guardrails written
- Execution checklist authored
- Butane + virtiofs model validated

**Status:** 🔒 Locked

---

### 8.3 Phase 2 — Execution (DEV)

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

**Status:** 🔒 Locked

---

### 8.4 Phase 3 — Execution (PROD)

Completed:
- ZFS pool `prod-zfs` created on pve-1 (Crucial T500 2TB NVMe)
- Datasets created and tuned: postgres, neo4j, qdrant (identical to DEV)
- Proxmox directory resource mappings created (prod-db-postgres, prod-db-neo4j, prod-db-qdrant)
- VM-110 (`colossus-prod-db1`) created via scripted `qm` commands adapted from DEV
- Static IP 10.10.100.110 configured via Butane/Ignition
- All three containers auto-start on boot
- Data restored from DEV-validated backups
- DEV/PROD parity confirmed: PostgreSQL (25 tables), Neo4j (207 nodes), Qdrant (287 points)
- Reboot test passed — mounts and containers survived restart
- CoreOS auto-update survived (42.20250929.3.0 → 43.20260119.3.1)
- First PBS backup completed (32 seconds, 50 GiB)
- Scheduled daily PBS backup job created (`backup-prod-db`)
- Phase 3 Completion Report authored

**Status:** 🔒 Locked

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


### 8.8 TrueNAS Integration — Backup Replication & Shared Storage

Completed 2026-02-13:

- TrueNAS appliance (TerraMaster F4-423) integrated into Colossus infrastructure
- Stale datasets and shares cleaned; fresh dataset layout created (6 datasets)
- NFS shares created for pbs-sync, iso, and templates with NFSv4
- ZFS snapshot tasks configured (6hr for backups, daily for iso/templates)
- NFS storage added to Proxmox cluster: `truenas-iso` and `truenas-templates` (all nodes)
- ISO library verified with write access across nodes
- NFS mounted in PBS VM-900 via fstab (`hard,nfsvers=4`)
- `truenas-sync` datastore added to PBS (second datastore on NFS)
- PBS sync job created: `pbs-to-truenas`, daily 02:00
- First sync completed: 17.7 GiB, 7 groups, 21 MiB/s average throughput
- All 8 VMs/CTs scheduled for daily PBS backup (previously only VM-110)
- `pbs-zfs` storage definition restricted to pve-3 only

**Key lessons:**
- PBS chunk store creation (65,536 directories) is extremely slow over NFS — create locally on TrueNAS, then fix ownership to UID 34 (backup user)
- `proxmox-backup-manager datastore create` refuses to use pre-existing `.chunks` directory (EEXIST error) — bypass by adding config to `/etc/proxmox-backup/datastore.cfg` directly
- TrueNAS CE 25.04 dataset quotas are set via Dataset Space Management (post-creation), not in the creation wizard
- TrueNAS SSH is disabled by default; use web shell (System → Shell) for admin tasks
- PBS VM-900 has no QEMU guest agent installed
- PBS datastore is named `pbs-zfs` (not `pbs-1` as some design docs assumed)

**Status:** ✅ Complete

---

### 8.9 Phase 5B-1 — Ansible Foundation

Completed 2026-02-14:

- Ansible 2.16.3 installed on workstation (proxima-centauri) as control node
- SSH key-based authentication deployed to all 11 hosts (3 Proxmox, 4 CoreOS VMs, 3 LXCs, 1 PBS)
- SSH enabled on LXC containers CT-311/312/313 via `pct exec` (openssh-server install + key deployment)
- Python3 installed on CoreOS VMs via `rpm-ostree install python3 libselinux-python3 --apply-live`
- Ansible project created: `~/colossus-ansible/` with inventory, group_vars, vault, playbooks
- Ansible Vault initialized with encrypted secrets (Neo4j passwords, Cloudflare tokens)
- SSH connection multiplexing configured for all homelab hosts (`~/.ssh/config`)
- UniFi UDM SE IPS detection exclusions added for internal subnets (root cause of SSH timeouts)
- `gather-facts.yml` validation playbook succeeds against all 11 hosts (10 managed + cloudflared)
- Idempotent execution confirmed (changed=0 on second run, forks=10)

**Key lessons:**
- CoreOS Python: `rpm-ostree install python3 libselinux-python3 --apply-live` is the canonical approach for Ansible on Fedora CoreOS — uses overlayfs, no reboot required
- `libselinux-python3` is required for Ansible to manage files on SELinux-enforcing systems
- Podman EnvironmentFile treats quotes as literal characters — Ansible Vault must store unquoted values
- UniFi IPS in "Notify and Block" mode flags legitimate cross-VLAN traffic as intrusion attempts
- SSH multiplexing (`ControlMaster auto`, `ControlPersist 120s`) is essential for Ansible stability with concurrent connections
- Ansible `group_vars/` directory must live inside the `inventory/` directory when using a directory-based inventory
- LXC containers need SSH enabled explicitly — Proxmox creates them without SSH server by default

**Status:** ✅ Complete

---

## 9. Repeatability & Parity Requirement

From this point forward:

- No VM creation is considered valid unless it is scriptable
- Manual steps are allowed only to discover correct parameters
- All validated steps must be codified

**DEV artifacts are the source of truth for PROD.**

This principle was validated in Phase 3: PROD was deployed mechanically from adapted DEV artifacts with zero new design decisions.

---

## 10. Phase 2 Work — DEV Execution (COMPLETE)

All items completed 2026-02-08:

1. ~~Formalize VM creation script (`qm`-based)~~ ✅
2. ~~Create new DEV CoreOS VM from script~~ ✅ (VM-210)
3. ~~Attach virtiofs datasets~~ ✅ (via directory mappings)
4. ~~Apply Ignition configuration~~ ✅ (via cloud-init vendor snippet)
5. ~~Bring up empty containers~~ ✅ (Quadlet auto-start)
6. ~~Restore PostgreSQL data~~ ✅
7. ~~Restore Neo4j data~~ ✅
8. ~~Restore Qdrant snapshot~~ ✅
9. ~~Run parallel validation vs VM-200~~ ✅ (all checks passed)
10. ~~Phase 2 exit gate~~ ✅

---

## 11. Phase 3 Work — PROD Execution (COMPLETE)

All items completed 2026-02-08/09:

1. ~~Create PROD automation package from DEV artifacts~~ ✅
2. ~~Create ZFS pool `prod-zfs` on pve-1~~ ✅
3. ~~Create directory mappings (prod-db-*)~~ ✅
4. ~~Create and start VM-110~~ ✅
5. ~~Restore PostgreSQL data~~ ✅
6. ~~Restore Neo4j data~~ ✅
7. ~~Restore Qdrant snapshot~~ ✅
8. ~~DEV vs PROD validation~~ ✅ (all metrics match)
9. ~~Reboot test~~ ✅
10. ~~PBS backup + scheduled job~~ ✅
11. ~~Phase 3 exit gate~~ ✅

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


## 13.5 TrueNAS Integration Work (COMPLETE)

All items completed 2026-02-13:

1. ~~Clean stale TrueNAS config (datasets, shares, tasks)~~ ✅
2. ~~Create 6 datasets with proper ZFS properties~~ ✅
3. ~~Create 3 NFS shares (pbs-sync, iso, templates)~~ ✅
4. ~~Create 3 ZFS snapshot tasks~~ ✅
5. ~~Add NFS storage to Proxmox cluster (truenas-iso, truenas-templates)~~ ✅
6. ~~Verify ISO library write access~~ ✅
7. ~~Mount NFS in PBS VM-900~~ ✅
8. ~~Add truenas-sync datastore to PBS~~ ✅
9. ~~Create PBS sync job (pbs-to-truenas, daily 02:00)~~ ✅
10. ~~Run first sync — 17.7 GiB, 7 groups, TASK OK~~ ✅
11. ~~Schedule all remaining VM/CT backups to PBS (8 jobs total)~~ ✅

---

## 14. Phase 5B-1 Work — Ansible Foundation (COMPLETE)

All items completed 2026-02-14:

1. ~~Install Ansible on workstation (proxima-centauri)~~ ✅
2. ~~Deploy SSH keys to all Proxmox hosts (pve-1, pve-2, pve-3)~~ ✅
3. ~~Deploy SSH keys to PBS (10.10.100.242)~~ ✅
4. ~~Enable SSH on LXC containers (CT-311, CT-312, CT-313)~~ ✅
5. ~~Deploy SSH keys to all CoreOS VMs (VM-110, VM-210, VM-120, VM-220)~~ ✅
6. ~~Install Python3 on CoreOS VMs (rpm-ostree --apply-live)~~ ✅
7. ~~Create Ansible project structure (~/colossus-ansible/)~~ ✅
8. ~~Create inventory with all hosts and group_vars~~ ✅
9. ~~Initialize Ansible Vault with encrypted secrets~~ ✅
10. ~~Configure SSH multiplexing for homelab hosts~~ ✅
11. ~~Diagnose and fix UniFi IPS blocking internal traffic~~ ✅
12. ~~Validate with gather-facts.yml (11/11 hosts, forks=10)~~ ✅
13. ~~Confirm idempotent execution (changed=0 on second run)~~ ✅

---


## 15. Known Issues

### 15.1 pve-1 igc NIC Instability

The Intel i225/i226 NIC on pve-1 (igc driver) exhibits intermittent SSH stalls under burst traffic. This does not affect normal operation or database services — only rapid sequential SSH connections.

**Workaround:** SSH connection multiplexing on the workstation (`~/.ssh/config` with ControlMaster/ControlPath/ControlPersist).

**Note:** The broader SSH timeout issue affecting *all* hosts (not just pve-1) was traced to UniFi IPS in Phase 5B-1. See 15.3 below. The pve-1 igc-specific stalls remain a separate, lower-priority concern.

**Future investigation:**
- Make ethtool offload changes persistent (`post-up` in `/etc/network/interfaces`)
- Test with newer Proxmox kernel
- Evaluate using ice NIC (Intel E800 10G/25G) instead of igc
- BIOS PCIe lane allocation

### 15.2 CoreOS Auto-Updates

Zincati auto-updates are enabled by default and will reboot VMs without warning. This was validated to be non-destructive (Phase 3 survived it), but for production stability, consider configuring maintenance windows.

### 15.3 UniFi IPS Internal Traffic Blocking (RESOLVED)

**Problem:** Random SSH connection failures and timeouts affecting all hosts on VLAN 100 (10.10.100.0/24). Ansible playbook runs failed on different hosts each attempt. `ansible all -m ping` sometimes succeeded but `ansible-playbook` with higher forks would fail randomly.

**Root cause:** UniFi UDM SE Intrusion Prevention System (IPS) in "Notify and Block" mode was flagging legitimate cross-VLAN and intra-VLAN traffic as intrusion attempts. Security Detection logs showed hundreds of blocks every 15 minutes:
- Proxmox hosts → TrueNAS (NFS/PBS sync traffic)
- Workstation → Pi-hole (DNS queries)
- Workstation → CoreOS VMs (SSH connections)

**Resolution (2026-02-14):** Added Detection Exclusions in UniFi Controller:
- CyberSecure → Protection → Detection Exclusions
- Excluded `10.10.100.0/24` (homelab VLAN) and `10.10.0.0/24` (main/NAS network)
- This tells the IPS engine to skip inspection for traffic within these subnets

**Verification:** `ansible-playbook gather-facts.yml --forks 10` succeeds 11/11 hosts consistently after exclusion.

**Status:** ✅ Resolved — exclusions are persistent in UniFi controller config

---

## 16. Future Work

These are independent workstreams that can be prioritized based on operational need:

### Completed (moved from future)
- ~~Edge services~~ — **Done (Phase 4B + 5A):** Domain, DNS, Cloudflare Tunnel, Pi-hole, Traefik
- ~~Application deployment~~ — **Done (Phase 4A):** Colossus-Legal containerized and deployed
- ~~Reverse proxy~~ — **Done (Phase 5A):** Traefik with Let's Encrypt wildcard cert
- ~~Scheduled backups for all VMs/CTs~~ — **Done (2026-02-13):** All 8 VMs/CTs on daily PBS schedule
- ~~TrueNAS integration~~ — **Done (2026-02-13):** PBS replication, ISO library, ZFS snapshots
- ~~Cloudflare Access policies~~ — **Done:** "Allow Roman" policy active on `*.cogmai.com`
- ~~Phase 5B-1 Ansible foundation~~ — **Done (2026-02-14):** SSH keys, inventory, vault, validation playbook

### Active / Upcoming
- **Phase 5B-2 — Codify existing infrastructure** — Ansible roles: traefik-route, pihole-dns, coreos-app, pbs-backup, proxmox-vm, proxmox-lxc
- **Phase 5B-3 — Application deployment playbook** — Define apps as YAML variable files consumed by reusable Ansible playbooks
- **Store deployment artifacts in Git** — Butane files, LXC scripts, Traefik configs (no secrets)

### Deferred
- **NAS VLAN (10.10.40.0/24)** — Dedicated storage VLAN for TrueNAS traffic isolation (VLAN tagging approach under consideration)
- **Cold/offline backup** — USB drive + ZFS send/recv for air-gapped 3-2-1 compliance
- **pve-1 NIC investigation** — permanent offload fix, alternative NIC evaluation
- **CoreOS update strategy** — Zincati maintenance window configuration for PROD
- **Monitoring/logging** — Centralized log aggregation and alerting
- **Authentication gateway** — Authentik or similar identity provider

## 17. Authoritative Artifacts

### 17.1 Configuration (Butane/Ignition)

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

### 17.2 Automation Scripts

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

### 17.3 Traefik Configuration (CT-313)

| File | Hot-reload? | Purpose |
|------|-------------|---------|
| `/etc/traefik/traefik.yml` | No (restart) | Static config: entrypoints, ACME, providers |
| `/etc/traefik/dynamic/services.yml` | Yes | Routers, services, middlewares |
| `/etc/traefik/dynamic/tls.yml` | Yes | TLS options (min version) |
| `/etc/traefik/cloudflare.env` | No (restart) | Cloudflare API token for DNS-01 |
| `/etc/traefik/acme.json` | — | Let's Encrypt certificate storage |

### 17.4 Ansible Configuration (Workstation)

| File/Directory | Purpose |
|----------------|---------|
| `~/colossus-ansible/ansible.cfg` | Ansible configuration (inventory path, vault, SSH settings, forks=10) |
| `~/colossus-ansible/inventory/hosts.yml` | All 11 hosts with connection parameters |
| `~/colossus-ansible/inventory/group_vars/all.yml` | Global vars (domain, IPs, default ansible_user: root) |
| `~/colossus-ansible/inventory/group_vars/coreos_vms.yml` | CoreOS-specific vars (ansible_user: core) |
| `~/colossus-ansible/inventory/group_vars/infrastructure.yml` | LXC container vars (ansible_user: root) |
| `~/colossus-ansible/secrets/vault.yml` | Ansible Vault encrypted secrets |
| `~/colossus-ansible/playbooks/gather-facts.yml` | Validation playbook (all hosts) |
| `~/.vault_pass` | Vault password file (chmod 600) |
| `~/.ssh/config` | SSH multiplexing config for 10.10.100.* |

**Ansible inventory groups:**
- `proxmox`: pve-1, pve-2, pve-3
- `coreos_vms`: colossus-prod-db1, colossus-dev-db1, colossus-prod-app1, colossus-dev-app1
- `infrastructure`: pihole, cloudflared, traefik
- `backup`: pbs
- `storage`: truenas (SSH disabled, unmanaged)


### 17.5 Documentation

| Document | Status | Purpose |
|----------|--------|---------|
| This document (Master Context v5) | **ACTIVE** | Canonical project reference |
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
| `COLOSSUS_TRUENAS_PBS_RUNBOOK_v1.md` | **ACTIVE** | TrueNAS/PBS integration operational procedures |
| `COLOSSUS_TRUENAS_INTEGRATION_DESIGN_v1.md` | **ACTIVE** | TrueNAS integration architecture and design |
| `COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md` | **ACTIVE** | Phase 5B Ansible automation design |
| `PHASE5B_TRUENAS_SESSION_TRANSITION.md` | **REFERENCE** | TrueNAS integration session record |
| `COLOSSUS_ANSIBLE_FOUNDATION_RUNBOOK_v1.md` | **ACTIVE** | Ansible SSH, Python, inventory, vault procedures |
| `PHASE5B1_SESSION_TRANSITION.md` | **REFERENCE** | Phase 5B-1 Ansible foundation session record |

### 17.6 Retired Documents

| Document | Reason |
|----------|--------|
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v2.md` | Superseded by v3 |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v3.md` | Superseded by v4 |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v4.md` | Superseded by v5 |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT.md` | Superseded by v3 |
| `VM200_EXTERNALIZATION_RUNBOOK_v1.2.md` | Described in-place migration; we did parallel rebuild |
| `COLOSSUS_EDGE_DNS_CLOUDFLARE_EXECUTION_TASK_TRACKER_v1.0.md` | Edge services execution complete |
| `PHASE-2-EXECUTION-CHECKLIST.md` | All items checked off |
| `PHASE_2_SESSION_TRANSITION.md` | Phase 2 complete |
| `PHASE_3_SESSION_TRANSITION.md` | Phase 3 complete |

### 17.7 Credentials & Secrets Reference

| Secret | Location | Notes |
|--------|----------|-------|
| Neo4j password (DEV) | VM-220 `/var/home/core/colossus/backend.env` | Contains `$` — no quotes |
| Neo4j password (PROD) | VM-120 `/var/home/core/colossus/backend.env` | Contains `$` — no quotes |
| Cloudflare Tunnel token | CT-312 (embedded via `cloudflared service install`) | Managed by Cloudflare |
| Cloudflare DNS API token | CT-313 `/etc/traefik/cloudflare.env` | DNS-01 challenge for LE certs |
| ghcr.io access | Public — no auth needed | Images are public |
| SSH key | `ssh-ed25519 AAAAC3...mUpD6 roman@proxima-centauri` | Used for all CoreOS VMs + LXCs + Proxmox |
| Ansible Vault | `~/colossus-ansible/secrets/vault.yml` | Encrypted with `~/.vault_pass` |
| Ansible Vault password | `~/.vault_pass` (chmod 600) | Referenced by `ansible.cfg` |

---


## 18. VM/CT Inventory

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
| — | `truenas` | Appliance | Standalone | 10.10.0.38 | NAS / backup secondary | Running |

### 18.1 Node Role Summary

```
pve-1 (PROD)              pve-2 (DEV)               pve-3 (Infra/Services)
├── VM-110 PROD DB         ├── VM-200 Frozen ref      ├── VM-900 PBS
├── VM-120 PROD App        ├── VM-210 DEV DB          ├── CT-311 Pi-hole
                           ├── VM-220 DEV App         ├── CT-312 cloudflared
                                                      ├── CT-313 Traefik
```

### 18.2 Container Images

| Image | Tag | Visibility | Notes |
|-------|-----|------------|-------|
| `ghcr.io/rhrywnak/colossus-backend` | v0.1.0, latest | Public | Rust/Axum, CORS env var |
| `ghcr.io/rhrywnak/colossus-frontend` | v0.1.0, latest | Public | React/nginx, runtime config |

---

## 19. Network

### 19.1 IP Assignments

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
| VM-900 | PBS | 10.10.100.242 | Static |
| — | TrueNAS | 10.10.0.38 | Static (LAN subnet) |
| — | proxima-centauri (workstation) | 10.10.0.99 | DHCP reservation |

### 19.2 DNS (Pi-hole Split-Horizon)

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

### 19.3 Traffic Flow

**External (phone/cellular):**
```
Browser → Cloudflare Edge (TLS) → Tunnel → CT-312 → CT-313 Traefik (HTTP:80) → VM-120
```

**Internal (LAN workstation):**
```
Browser → Pi-hole DNS → CT-313 Traefik (HTTPS:443, LE cert) → VM-120/VM-220
```

### 19.4 Management Infrastructure (Ansible)

**Control node:** proxima-centauri (10.10.0.99)

SSH multiplexing configured in `~/.ssh/config` for all homelab hosts:
```
Host 10.10.100.*
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 120s
```

**SSH access method by host type:**

| Host Type | User | Auth | Notes |
|-----------|------|------|-------|
| Proxmox (pve-1/2/3) | root | SSH key | Default authorized_keys |
| CoreOS VMs | core | SSH key | Deployed via Ignition + ssh-copy-id |
| LXC containers | root | SSH key | SSH server installed via `pct exec` |
| PBS (VM-900) | root | SSH key | Standard authorized_keys |
| TrueNAS | — | — | SSH disabled; web shell only |

### 19.5 UniFi Network Security Configuration

**UniFi UDM SE** — IPS enabled in "Notify and Block" mode.

**Detection Exclusions (CyberSecure → Protection):**
- `10.10.100.0/24` — Homelab VLAN (all VMs, CTs, Proxmox hosts)
- `10.10.0.0/24` — Main/NAS network (workstation, TrueNAS)

These exclusions prevent the IPS engine from flagging legitimate internal infrastructure traffic. Without them, cross-VLAN NFS, DNS, and SSH traffic is randomly blocked.

---

## 20. Backup Configuration

### 20.1 PBS Backup Jobs

All VMs/CTs backed up daily to PBS datastore `pbs-zfs` (local SSD on pve-3).
Configured in `/etc/pve/jobs.cfg` (cluster-wide).

| Job ID | VMID | Name | Type | Node | Schedule | Status |
|--------|------|------|------|------|----------|--------|
| backup-prod-db | 110 | colossus-prod-db1 | VM | pve-1 | Daily | Active |
| backup-prod-app | 120 | colossus-prod-app1 | VM | pve-1 | Daily | Active |
| backup-dev-db-frozen | 200 | colossus-db1-dev | VM | pve-2 | Daily | Active |
| backup-dev-db | 210 | colossus-dev-db1 | VM | pve-2 | Daily | Active |
| backup-dev-app | 220 | colossus-dev-app1 | VM | pve-2 | Daily | Active |
| backup-pihole | 311 | pihole | CT | pve-3 | Daily | Active |
| backup-cloudflared | 312 | cloudflared | CT | pve-3 | Daily | Active |
| backup-traefik | 313 | traefik | CT | pve-3 | Daily | Active |

**Not backed up:** VM-900 (PBS) — cannot back up to itself; rebuildable from config.

PBS retention policy (pbs-zfs): daily 14, weekly 8, monthly 12.

### 20.2 Backup Replication to TrueNAS

PBS sync job `pbs-to-truenas` runs daily at 02:00, replicating all backup data from `pbs-zfs` to `truenas-sync` (NFS-mounted TrueNAS RAID10 HDD).

TrueNAS retention policy (truenas-sync): daily 7, weekly 4, monthly 6.

TrueNAS ZFS snapshots of the pbs-sync dataset run every 6 hours with 1-week retention, providing ransomware-independent protection.

### 20.3 Backup Data Flow

```
Proxmox vzdump (8 VMs/CTs) → pbs-zfs (SSD, fast) → truenas-sync (HDD, durable)
                                                      ↓
                                              TrueNAS ZFS snapshots (independent)
```

See `COLOSSUS_TRUENAS_PBS_RUNBOOK_v1.md` for full operational procedures.

---

## 21. Success Criteria

The Colossus homelab is successful if:

- Any DB VM can be rebuilt from scratch in under an hour
- Data restoration is documented and boring
- No step relies on memory
- Long pauses do not cause relearning
- DEV → PROD parity is mechanical, not conceptual

**Phase 3 validates all five criteria.** PROD was deployed mechanically from DEV artifacts in two sessions.

---

## 22. Final Rule

> If execution deviates from this document, stop and update the document — not the system.
