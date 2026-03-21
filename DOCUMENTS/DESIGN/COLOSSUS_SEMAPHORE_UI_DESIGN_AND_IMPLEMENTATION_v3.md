# Colossus Semaphore UI — Design & Implementation Document

**Document Type:** Technical Design & Implementation Plan  
**Version:** v3.0  
**Date:** 2026-02-17  
**Author:** Colossus Infrastructure Team  
**Status:** APPROVED — Ready for Execution  
**Phase:** 7A — Runbook Automation & Orchestration  
**Depends On:** Phase 5B (Ansible Foundation) ✅, Phase 6A (Monitoring Stack) ✅  
**Prerequisite:** PBS backup scheduling must be operational before Neo4j sync playbook execution  

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Research Summary](#2-research-summary)
3. [Tool Selection & Rationale](#3-tool-selection--rationale)
4. [Architecture Design](#4-architecture-design)
5. [Implementation Plan](#5-implementation-plan)
6. [Neo4j Sync — Separate Phase Playbook Architecture](#6-neo4j-sync--separate-phase-playbook-architecture)
7. [Semaphore Project & Template Configuration](#7-semaphore-project--template-configuration)
8. [Monitoring & Observability Integration](#8-monitoring--observability-integration)
9. [Security Considerations](#9-security-considerations)
10. [Backup & Disaster Recovery](#10-backup--disaster-recovery)
11. [Success Metrics](#11-success-metrics)
12. [Risk Assessment](#12-risk-assessment)
13. [Future Expansion](#13-future-expansion)
14. [Decision Log](#14-decision-log)
15. [References](#15-references)

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-02-17 | Initial draft |
| v2.0 | 2026-02-17 | Expanded research, added resource comparison, monitoring section |
| v3.0 | 2026-02-17 | **Major revision** — incorporated peer review findings: corrected GitHub project health data (159 contributors, 12,900+ stars), upgraded target to v2.17 (Feb 15, 2026 release), replaced monolithic pause-based playbook with separate phase playbooks to resolve TTY hang issue (AWX #1897), changed initial database from PostgreSQL to SQLite (zero external dependencies, migrate later), added Ansible role for CT-315 deployment (infrastructure-as-code), promoted Atuin Desktop from "monitor" to "deploy on proxima-centauri" as complementary interactive tool, clarified transfer path through CT-315, added PBS backup fix as hard prerequisite, added inventory cleanup (VM-200 removal) as prerequisite, incorporated v2.17 features (syslog, project export/import CLI, one-time schedules), aligned with official Semaphore documentation patterns |

---

## 1. Problem Statement

### 1.1 The Core Problem

The Colossus homelab has accumulated a library of operational runbooks — documented, tested, multi-step procedures for critical infrastructure tasks. These runbooks exist as markdown documents (e.g., `NEO4J_DEV_TO_PROD_SYNC_RUNBOOK.md`, `COLOSSUS_DEV_BACKUP_RESTORE_RUNBOOK_v1.md`). They are correct and detailed, but they are *documents*, not *executable workflows*.

Every time a runbook is executed, the operator must:

- Open the document and read through each step sequentially
- Copy-paste commands into a terminal, substituting variables by hand
- Eyeball validation output to determine pass/fail
- Manually track which steps have completed
- Hope that no step was skipped, misordered, or mistyped

This is exactly where human error lives. A single missed validation gate, a transposed IP address, or a forgotten backup step can result in data loss or extended downtime.

### 1.2 Specific Triggering Scenario — Neo4j Dev→Prod Sync

The immediate catalyst for this work is the Neo4j Dev→Prod synchronization workflow. This is an 11-section runbook that performs a full database replacement: dumping the Neo4j database from VM-210 (DEV on pve-2), transferring it to VM-110 (PROD on pve-1), and loading it as a destructive replacement. The procedure involves:

- Pre-flight health checks on both environments
- PBS backup of PROD before any destructive operation
- Stopping the Neo4j container on DEV, running `neo4j-admin database dump`
- Transferring the dump file across hosts via SCP
- Stopping the Neo4j container on PROD, running `neo4j-admin database load` (DESTRUCTIVE)
- Restarting services and validating data parity
- Rollback path if validation fails

Each of these phases has dependencies, validation gates, and specific SELinux/virtiofs considerations unique to the CoreOS + Podman + Quadlet architecture. The manual execution risk is not theoretical — it is the kind of procedure where a mistake during the PROD load phase could destroy production data without an immediately available rollback.

### 1.3 Broader Problem Scope

Beyond Neo4j sync, the homelab has a growing catalog of operational procedures that would benefit from orchestrated execution:

- **PBS backup validation** — Verifying all scheduled backups completed successfully across all VMs/CTs
- **Monitoring health checks** — Validating Prometheus targets, Alloy agent connectivity, Grafana datasources
- **New VM/CT deployment checklist** — Ensuring every new resource is integrated into DNS, monitoring, backup, and Traefik routing
- **Database backup rotation** — PostgreSQL `pg_dumpall`, Neo4j `neo4j-admin dump`, Qdrant snapshots across DEV and PROD
- **Infrastructure drift detection** — Running `ansible-playbook --check --diff` to detect configuration drift
- **Certificate renewal verification** — Ensuring Let's Encrypt certificates via Traefik ACME are current
- **Firmware/update coordination** — Rolling updates across Proxmox nodes, CoreOS auto-updates, container image pulls

### 1.4 What We Need

A solution that can:

1. **Encode runbooks as executable workflows** — Turn markdown procedures into automated, repeatable tasks
2. **Provide phase-by-phase control** — Allow operator to review output before triggering next phase
3. **Run validation gates automatically** — Assert expected conditions and halt on failure
4. **Produce an audit trail** — Log what happened, when, and what the outcome was
5. **Offer a web UI** — Visual dashboard for triggering, monitoring, and reviewing executions
6. **Leverage existing infrastructure** — Work with the Ansible foundation (11 hosts), existing SSH keys, and the Podman/CoreOS/LXC architecture already in place
7. **Fit the homelab resource envelope** — Minimal memory/CPU footprint, no new container runtimes, no architectural violations

---

## 2. Research Summary

### 2.1 Research Methodology

A comprehensive internet search was conducted spanning 70+ sources across documentation sites, GitHub repositories, blog posts, community forums, and technical comparison articles. The research covered three categories of solutions: infrastructure-focused runbook automation, general-purpose workflow engines, and emerging executable documentation tools. Project health was verified against primary sources (GitHub repos, official documentation) rather than relying solely on third-party assessments.

### 2.2 Category 1: Infrastructure Runbook Automation (Best Fit)

#### Semaphore UI

- **Repository:** github.com/semaphoreui/semaphore
- **Project Health:** 12,900+ stars, 1,200+ forks, 4,285 commits, **159 contributors**, MIT license
- **Latest Release:** v2.17.0 (February 15, 2026) — active development with frequent releases
- **Architecture:** Single Go binary, distributed as `.deb`/`.rpm` packages or standalone binary. Managed by systemd for native installations. No container runtime required.
- **Database:** PostgreSQL, MySQL, SQLite (BoltDB deprecated, removal planned for v3.0)
- **Supported tools:** Ansible, Terraform/OpenTofu/Terragrunt, PowerShell, Shell/Bash, Python
- **Resource footprint:** ~100–200MB RAM (Go binary only, database is external or embedded SQLite)
- **Deployment time:** Under 15 minutes via `.deb` package + `semaphore setup` wizard
- **Key capabilities:** Project-based organization, centralized inventory management, scheduled/on-demand execution, real-time log streaming, access control, secure credential storage (SSH keys, Ansible vault), cron-like scheduling, one-time scheduled tasks (v2.17), detailed execution history, REST API, syslog forwarding (v2.17), project export/import via CLI (v2.17), database migration rollback (v2.17)
- **Assessment:** Direct fit for existing Ansible infrastructure. Well-maintained project with healthy contributor base.

**v2.17 Features Relevant to Colossus:**

| Feature | Benefit |
|---------|---------|
| **Syslog server support** | Forward Semaphore logs to Alloy/Loki — integrates directly with monitoring stack |
| **Project export/import via CLI** | Backup/restore project configuration, supports disaster recovery |
| **One-time scheduled tasks** | Schedule maintenance tasks for specific change windows |
| **Stop all tasks** | Emergency halt for accidentally triggered destructive playbooks |
| **Database migration rollback** | Safer upgrades with ability to roll back if issues arise |
| **BoltDB→SQLite/Postgres migrator** | Clean migration path when upgrading from SQLite to PostgreSQL later |

#### Rundeck (Open Source)

- **Repository:** github.com/rundeck/rundeck
- **License:** Apache 2.0
- **Architecture:** Java-based (JVM), web console + CLI + REST API
- **Resource footprint:** >4GB RAM for JVM alone, 5–6GB+ total with database
- **Assessment:** Enterprise-grade, substantial overkill for single-operator homelab. The JVM memory overhead alone exceeds the total monitoring stack footprint.

#### StackStorm (ST2)

- **Repository:** github.com/StackStorm/st2 (Linux Foundation)
- **Architecture:** Modular microservices over message bus (RabbitMQ, MongoDB, multiple containers)
- **Assessment:** Massive overkill. The architecture complexity exceeds the infrastructure it would manage.

### 2.3 Category 2: General Workflow Engines

#### Windmill

- **Architecture:** Rust core, visual workflow builder + code support
- **Resource footprint:** ~287MB total (128MB orchestrator + 94MB Postgres + 18MB per worker)
- **Assessment:** Impressively lightweight thanks to Rust core, but focused on internal tools and API workflows rather than SSH-based infrastructure operations.

#### n8n

- **Architecture:** Node.js, 500+ integrations, visual drag-and-drop
- **Resource footprint:** ~516MB, can balloon to 2GB+ with complex workflows
- **Assessment:** Built for SaaS integration and data pipelines, not infrastructure runbook execution.

#### Temporal

- **Architecture:** Go-based distributed orchestration, deterministic replay
- **Resource footprint:** ~832MB minimal setup
- **Assessment:** Gold standard for durable workflow execution, but code-first (no visual builder), complex, and heavy for homelab use.

### 2.4 Category 3: Executable Documentation (Complementary)

#### Atuin Desktop

- **Repository:** github.com/atuinsh/desktop
- **License:** Apache 2.0 (fully open-sourced November 2025)
- **Architecture:** Rust-based desktop application, local-first with CRDT collaboration
- **Recent Development:** Completely redesigned runbook execution engine (v0.2.0), added AI assistant integration, SSH improvements, pause blocks for human-in-the-loop confirmation. Active development with January 2026 devlog.
- **Key capabilities:** "Runbooks that run" — executable markdown combining shell scripts, database queries, HTTP requests, and Prometheus charts. Jinja-style templating, pause blocks for human-in-the-loop confirmation. Runs locally on workstation with full terminal access.
- **Limitation:** Desktop app (not web server), no centralized scheduling or dashboard
- **Assessment:** **Deploy on proxima-centauri** as complementary interactive runbook tool. Perfect for operator-driven procedures (Neo4j sync, database restores, new VM provisioning) where the operator is at the workstation. Clean separation of concerns: Semaphore for scheduled/unattended automation, Atuin Desktop for interactive procedures.

### 2.5 Resource Footprint Comparison

| Tool | Total Memory | Deployment Complexity | Homelab Fit |
|------|-------------|----------------------|-------------|
| **Semaphore UI** | ~100–200MB (binary only) | `.deb` install + systemd | ★★★★★ |
| **Windmill** | ~287MB | Requires dedicated Postgres | ★★★☆☆ |
| **n8n** | ~516MB (grows to 2GB+) | Node.js + Redis + Postgres | ★★☆☆☆ |
| **Temporal** | ~832MB | Complex, distributed | ★☆☆☆☆ |
| **Rundeck** | ~5–6GB+ | Complex, Java dependencies | ★☆☆☆☆ |
| **StackStorm** | Heavy (multiple services) | Complex, microservices | ☆☆☆☆☆ |

---

## 3. Tool Selection & Rationale

### 3.1 Decision: Semaphore UI v2.17 (Open Source, Native Binary)

Semaphore UI is selected as the runbook automation platform for the Colossus homelab, deployed as a native Go binary via `.deb` package on a Debian 12 LXC container, initially using SQLite for zero-dependency startup with a documented migration path to PostgreSQL.

### 3.2 Rationale — Why Semaphore

**Direct integration with existing Ansible infrastructure.** The Colossus homelab already has a fully operational Ansible foundation: 11 managed hosts in inventory, SSH multiplexing configured, Ansible Vault storing encrypted secrets, group variables organizing hosts by type. Semaphore reads the same `hosts.yml` inventory, decrypts the same vault, uses the same SSH keys. Additionally, Semaphore automatically discovers and installs Ansible roles and collections from `requirements.yml` in the repo root during project initialization — no manual pre-installation needed.

**Minimal resource footprint.** The Go binary uses approximately 100–200MB RAM. With SQLite as the initial database, the LXC container needs nothing beyond the binary, Ansible, Git, and Python — all lightweight native packages.

**No container runtime in the LXC.** The Colossus architecture standardizes on two container patterns: Podman + Quadlet on CoreOS VMs for application workloads, and native services in Debian LXC containers for infrastructure (Pi-hole, cloudflared, Traefik). Semaphore as a native binary in an LXC follows the infrastructure services pattern exactly. No Docker, no Podman, no `nesting=1` hack.

**LXC is architecturally correct for this workload.** Unlike the monitoring stack (VM-314), which grew to 8 tightly-coupled containers sharing data, Semaphore is a single Go binary that shells out to Ansible, which shells out to SSH. There's nothing to compose. Even adding Terraform/OpenTofu later is just another binary on the filesystem. This stack won't grow like monitoring did.

**Follows the established LXC deployment pattern.** Infrastructure services on pve-3 are lightweight LXC containers running focused native services, managed by Ansible, fronted by Traefik. CT-311 (Pi-hole), CT-312 (cloudflared), and CT-313 (Traefik) all follow this pattern. CT-315 (Semaphore) is identical.

**Beyond Ansible.** Semaphore also supports Terraform/OpenTofu, Shell/Bash scripts, PowerShell, and Python. Operational scripts that don't warrant a full Ansible playbook can still be triggered, logged, and tracked through the same interface.

**Web UI for audit trail and scheduling.** Every execution is logged with timestamp, initiator, parameters, full output, and pass/fail status. Cron-like scheduling enables recurring operations (daily drift detection, weekly backup verification) without manual intervention.

**Healthy project with active community.** 159 contributors, 12,900+ stars, regular releases (v2.17 released February 15, 2026), comprehensive documentation at docs.semaphoreui.com. Not a single-maintainer risk.

### 3.3 What We Are NOT Choosing (And Why)

| Alternative | Reason for Exclusion |
|-------------|---------------------|
| **Rundeck** | JVM requires 4GB+ RAM. Enterprise team delegation features wasted on single-operator lab. |
| **StackStorm** | Architecture complexity (RabbitMQ, MongoDB, microservices) exceeds the infrastructure it would manage. |
| **Windmill** | Elegant Rust core, but designed for API workflows, not SSH-based infrastructure. |
| **n8n** | SaaS integration focus, Node.js memory bloat, wrong tool for the job. |
| **Temporal** | Bulletproof durability, but code-first, heavy, and unwarranted complexity for homelab. |
| **AWX/Ansible Tower** | Requires Kubernetes, 4–6 containers, 2–4GB RAM. Designed for enterprise scale. |
| **Docker-based Semaphore** | Violates Colossus architecture — no Docker in LXC containers, no `nesting=1`. |

### 3.4 Complementary Tool: Atuin Desktop (Deploy on proxima-centauri)

Atuin Desktop is deployed on the workstation as the interactive companion to Semaphore's server-based automation. The separation of concerns:

| Concern | Tool | Why |
|---------|------|-----|
| Scheduled unattended automation | Semaphore UI | Cron schedules, web UI, audit trail, no operator required |
| Interactive operator-driven procedures | Atuin Desktop | Full terminal access, pause blocks work natively, operator at keyboard |
| Health checks, drift detection, backup verification | Semaphore UI | Run automatically, alert on failure |
| Neo4j sync, database restores, new VM provisioning | Either | Semaphore for repeatable execution; Atuin for first-time walkthroughs |

---

## 4. Architecture Design

### 4.1 Deployment Target

Semaphore will be deployed as LXC container **CT-315** on **pve-3** (infrastructure node), running the native Go binary as a systemd service, initially using embedded SQLite for zero external dependencies.

```
pve-3 (Infra Node — 10.10.100.5)
├── VM-900  PBS (Proxmox Backup Server)        — 10.10.100.242
├── CT-311  Pi-hole (DNS)                       — 10.10.100.53
├── CT-312  cloudflared (Tunnel)                — 10.10.100.54
├── CT-313  Traefik (Reverse Proxy)             — 10.10.100.55
├── VM-314  Monitoring (Prometheus/Grafana/Loki) — 10.10.100.56
└── CT-315  Semaphore UI (Runbook Automation)   — 10.10.100.57  ← NEW
```

### 4.2 Container Specification

| Property | Value |
|----------|-------|
| **CTID** | 315 |
| **Hostname** | semaphore |
| **Template** | Debian 12 (Bookworm) |
| **Node** | pve-3 |
| **IP Address** | 10.10.100.57/24 |
| **Gateway** | 10.10.100.1 |
| **Cores** | 1 |
| **Memory** | 512MB |
| **Swap** | 256MB |
| **Disk** | 4GB (local-lvm) |
| **Network** | vmbr0, VLAN-aware |
| **Start on boot** | Yes |
| **DNS** | 10.10.100.53 (Pi-hole) |
| **Unprivileged** | Yes |

### 4.3 Internal Architecture

```
CT-315 (Debian 12 LXC — Native Services Only)
│
├── /usr/bin/semaphore          ← Go binary (installed via .deb package, v2.17)
│   ├── Listens on :3000 (Web UI + REST API)
│   ├── Reads /etc/semaphore/config.json
│   └── Uses SQLite at /var/lib/semaphore/database.boltdb (initially)
│
├── systemd: semaphore.service  ← Manages lifecycle (start/stop/restart)
│   └── User: semaphore (non-root service account)
│
├── Ansible 2.16+               ← Installed via pip (in semaphore user venv)
│   ├── Reads inventory from cloned Git repo
│   ├── Uses vault password from Semaphore credential store
│   ├── SSH to managed hosts via Semaphore SSH key store
│   └── Galaxy collections auto-installed from repo requirements.yml
│
├── Git                          ← Clones colossus-ansible from GitHub
│
├── Python 3.11+                 ← Required by Ansible
│   └── Virtual environment at /home/semaphore/venv
│
└── /home/semaphore/
    ├── requirements.txt         ← Python/Ansible dependencies
    └── requirements.yml         ← Ansible Galaxy collections
```

### 4.4 Database Architecture — SQLite Initially, PostgreSQL Later

**Phase 1 (Initial Deployment): SQLite**

SQLite is used for initial deployment to eliminate external dependencies and get Semaphore operational in minutes. The database file lives inside CT-315 at `/var/lib/semaphore/database.sqlite3`.

**Advantages of starting with SQLite:**
- Zero external dependencies — no cross-VM networking, no pg_hba.conf, no circular dependency risk
- Simpler disaster recovery — database is inside the CT-315 PBS backup
- Faster initial deployment — skip database preparation phase entirely
- Proven by Semaphore — fully supported backend

**Trade-offs:**
- Weaker concurrent access (single-writer — acceptable for single-operator homelab)
- Database not separately backed up (but included in CT-315 PBS snapshot)

**Phase 2 (Optional, Post-Stabilization): Migrate to PostgreSQL**

If concurrent access becomes a concern or if centralizing database backup is desired, Semaphore supports backend migration. v2.17 includes a CLI migrator tool. The migration path:

1. Create `semaphore` database on VM-110 PostgreSQL (same as v2 design)
2. Use `semaphore migrate` CLI to move data from SQLite to PostgreSQL
3. Update `/etc/semaphore/config.json` with PostgreSQL connection details
4. Restart service

This can be done at any time with no data loss. The PostgreSQL configuration details from the v2 design remain valid and are preserved in the Decision Log for future reference.

### 4.5 Network Architecture

```
                                    ┌─────────────────────────┐
                                    │   External Access        │
                                    │   (Cloudflare Tunnel)    │
                                    └──────────┬──────────────┘
                                               │
┌──────────────────────────────────────────────┼──────────────────────┐
│  pve-3 Internal Network (10.10.100.0/24)     │                      │
│                                              │                      │
│  ┌─────────────┐    ┌─────────────┐    ┌─────┴───────┐             │
│  │ CT-311       │    │ CT-312      │    │ CT-313      │             │
│  │ Pi-hole      │    │ cloudflared │    │ Traefik     │             │
│  │ :53 DNS      │    │ :443 tunnel │    │ :443 HTTPS  │             │
│  └─────────────┘    └─────────────┘    └──────┬──────┘             │
│                                               │                     │
│                                    ┌──────────┴──────────┐         │
│                                    │ CT-315               │         │
│                                    │ Semaphore UI         │         │
│                                    │ :3000 (Web + API)    │         │
│                                    └──────────┬──────────┘         │
│                                               │                     │
│  SSH to managed hosts:                        │                     │
│  ├── →SSH→ VM-110/PROD-DB (10.10.100.110) core                     │
│  ├── →SSH→ VM-120/PROD-APP (10.10.100.120) core                    │
│  ├── →SSH→ VM-210/DEV-DB (10.10.100.200) core                     │
│  ├── →SSH→ VM-220/DEV-APP (10.10.100.220) core                    │
│  ├── →SSH→ pve-1 (10.10.100.3) root                               │
│  ├── →SSH→ pve-2 (10.10.100.2) root                               │
│  ├── →SSH→ pve-3 (10.10.100.5) root                               │
│  ├── →SSH→ CT-311/Pi-hole (10.10.100.53) root                     │
│  ├── →SSH→ CT-312/cloudflared (10.10.100.54) root                  │
│  ├── →SSH→ CT-313/Traefik (10.10.100.55) root                     │
│  └── →SSH→ VM-900/PBS (10.10.100.242) root                        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.6 DNS & Routing Configuration

| Component | Configuration |
|-----------|--------------|
| **Pi-hole DNS** | `semaphore.cogmai.com` → `10.10.100.55` (Traefik) |
| **Traefik Route** | Host(`semaphore.cogmai.com`) → `http://10.10.100.57:3000` |
| **Cloudflare Tunnel** | `semaphore.cogmai.com` → Traefik (for remote access) |
| **Internal Direct** | `http://10.10.100.57:3000` (fallback) |

### 4.7 Data Flow — Playbook Execution

```
1. Operator clicks "Run" in Semaphore Web UI (or API call, or cron schedule)
         │
2. Semaphore clones/pulls colossus-ansible from GitHub
         │
3. Semaphore injects SSH key + vault password from credential store
         │
4. Ansible playbook executes against target hosts via SSH
         │
5. Real-time stdout/stderr streams to Semaphore Web UI
         │
6. Validation tasks (assert modules) gate progression
         │
7. Execution result (pass/fail) logged with full output to SQLite
         │
8. Operator reviews output, clicks "Run" on next phase playbook (for multi-phase procedures)
         │
9. Notification sent on failure (optional, via webhook)
```

---

## 5. Implementation Plan

### 5.0 Prerequisites (Before Starting Phase 7A)

**CRITICAL — These must be completed before Semaphore deployment:**

| # | Prerequisite | Status | Notes |
|---|-------------|--------|-------|
| P1 | **PBS backup scheduling operational** | ❌ BLOCKER | Phase 6A-3 flagged that PBS backup jobs are not running despite existing Ansible role. Must fix pbs-backup role and validate scheduled jobs are active for all VMs/CTs before Semaphore can orchestrate backup-dependent workflows. |
| P2 | **VM-200 removed from inventory** | ❌ | VM-200 flagged for deletion in transition docs. Must be removed from `inventory/hosts.yml` before Semaphore pulls inventory — otherwise Semaphore sees a stale host. |
| P3 | **Git commit of latest Ansible changes** | ✅ Verify | All Phase 6A roles, playbooks, and inventory changes must be committed and pushed. Semaphore clones from GitHub. |

### 5.1 Phase 7A-1: LXC Container Creation (15 minutes)

**Option A: Via Ansible role (preferred — infrastructure-as-code)**

Create `roles/semaphore/` role following the established `proxmox-lxc` pattern:

```
roles/semaphore/
├── defaults/main.yml           # version, ports, paths
├── tasks/
│   ├── main.yml                # orchestrates all steps
│   ├── prerequisites.yml       # apt packages, semaphore user, venv
│   ├── install.yml             # download .deb, install, verify
│   ├── configure.yml           # config.json, directories, permissions
│   └── service.yml             # systemd unit, enable, start
├── templates/
│   ├── config.json.j2          # Semaphore configuration
│   └── semaphore.service.j2    # systemd unit file
└── handlers/
    └── main.yml                # restart semaphore

playbooks/deploy-semaphore.yml  # targets semaphore group
```

**Option B: Manual creation (fallback)**

From pve-3 shell:

```bash
# Download Debian 12 template if not already present
pveam update
pveam download local debian-12-standard_12.7-1_amd64.tar.zst

# Create CT-315
pct create 315 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname semaphore \
  --cores 1 \
  --memory 512 \
  --swap 256 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=10.10.100.57/24,gw=10.10.100.1 \
  --nameserver 10.10.100.53 \
  --searchdomain cogmai.com \
  --onboot 1 \
  --start 1 \
  --unprivileged 1

# Verify
pct status 315
```

### 5.2 Phase 7A-2: Semaphore Installation (20 minutes)

#### Step 1: Install Prerequisites

```bash
pct exec 315 -- bash -c '
  apt-get update
  apt-get install -y \
    openssh-server \
    git \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    wget

  systemctl enable --now ssh
'
```

#### Step 2: Deploy SSH Key

From workstation:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@10.10.100.57
```

#### Step 3: Create Semaphore Service User

```bash
pct exec 315 -- bash -c '
  adduser --system --group --home /home/semaphore --shell /bin/bash semaphore
'
```

#### Step 4: Install Ansible in Virtual Environment

Per official Semaphore documentation, use a Python virtual environment:

```bash
pct exec 315 -- bash -c '
  sudo -u semaphore bash -c "
    python3 -m venv /home/semaphore/venv
    source /home/semaphore/venv/bin/activate
    pip install --upgrade pip
    pip install ansible
  "
'
```

#### Step 5: Create Ansible Requirements

```bash
pct exec 315 -- bash -c '
  cat > /home/semaphore/requirements.txt << EOF
ansible
netaddr
jmespath
EOF
  chown semaphore:semaphore /home/semaphore/requirements.txt

  cat > /home/semaphore/requirements.yml << EOF
collections:
  - name: community.general
  - name: community.proxmox
  - name: ansible.posix
EOF
  chown semaphore:semaphore /home/semaphore/requirements.yml
'
```

**Note:** Semaphore will also auto-install collections from `requirements.yml` in the Git repo root during project initialization. These local requirements serve as a baseline.

#### Step 6: Install Semaphore Binary

```bash
pct exec 315 -- bash -c '
  # Download latest stable .deb package
  # Check https://github.com/semaphoreui/semaphore/releases for current version
  SEMAPHORE_VERSION="2.17.0"
  wget -q "https://github.com/semaphoreui/semaphore/releases/download/v${SEMAPHORE_VERSION}/semaphore_${SEMAPHORE_VERSION}_linux_amd64.deb"
  dpkg -i "semaphore_${SEMAPHORE_VERSION}_linux_amd64.deb"
  rm -f "semaphore_${SEMAPHORE_VERSION}_linux_amd64.deb"

  # Verify
  semaphore version
'
```

#### Step 7: Configure Semaphore (SQLite)

```bash
pct exec 315 -- bash -c '
  mkdir -p /etc/semaphore /var/lib/semaphore/tmp
  chown -R semaphore:semaphore /var/lib/semaphore

  # Generate secrets
  COOKIE_HASH=$(head -c 32 /dev/urandom | base64)
  COOKIE_ENC=$(head -c 32 /dev/urandom | base64)
  ACCESS_ENC=$(head -c 32 /dev/urandom | base64)

  # Generate config.json with SQLite
  cat > /etc/semaphore/config.json << EOF
{
  "bolt": {
    "host": "/var/lib/semaphore/database.sqlite3"
  },
  "dialect": "sqlite3",
  "port": "",
  "interface": "",
  "tmp_path": "/var/lib/semaphore/tmp",
  "cookie_hash": "${COOKIE_HASH}",
  "cookie_encryption": "${COOKIE_ENC}",
  "access_key_encryption": "${ACCESS_ENC}",
  "email_sender": "",
  "web_host": "https://semaphore.cogmai.com",
  "max_parallel_tasks": 2,
  "git_client": "cmd_git"
}
EOF
  chown semaphore:semaphore /etc/semaphore/config.json
  chmod 600 /etc/semaphore/config.json

  # Run database migrations
  sudo -u semaphore semaphore migrate --config /etc/semaphore/config.json

  # Create admin user
  sudo -u semaphore semaphore user add \
    --config /etc/semaphore/config.json \
    --admin \
    --login admin \
    --name "Admin" \
    --email admin@cogmai.com \
    --password "<admin-password>"
'
```

**Store the admin password in Ansible Vault:**

```bash
cd ~/colossus-ansible
ansible-vault edit secrets/vault.yml
# Add: semaphore_admin_password: "<the-password>"
```

#### Step 8: Create systemd Service

Following the official Semaphore documentation pattern:

```bash
pct exec 315 -- bash -c '
  cat > /etc/systemd/system/semaphore.service << EOF
[Unit]
Description=Semaphore UI
Documentation=https://docs.semaphoreui.com/
Wants=network-online.target
After=network-online.target
ConditionPathExists=/usr/bin/semaphore
ConditionPathExists=/etc/semaphore/config.json

[Service]
User=semaphore
Group=semaphore
Restart=always
RestartSec=10s

# Python/Ansible virtual environment
Environment="PATH=/home/semaphore/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="ANSIBLE_HOST_KEY_CHECKING=false"

# Auto-upgrade Ansible dependencies at startup
ExecStartPre=/bin/bash -c "source /home/semaphore/venv/bin/activate && pip install --upgrade -r /home/semaphore/requirements.txt"
ExecStartPre=/bin/bash -c "source /home/semaphore/venv/bin/activate && ansible-galaxy collection install --upgrade -r /home/semaphore/requirements.yml"

ExecStart=/usr/bin/semaphore server --config /etc/semaphore/config.json
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now semaphore
  systemctl status semaphore
'
```

#### Step 9: Validate

```bash
# From inside CT-315
pct exec 315 -- curl -s http://localhost:3000/api/ping
# Expected: {"message":"pong"}

# From workstation
curl -s http://10.10.100.57:3000/api/ping
# Expected: {"message":"pong"}
```

### 5.3 Phase 7A-3: DNS & Traefik Integration (10 minutes)

#### Pi-hole DNS Record

Add local DNS record (via Pi-hole web UI or Ansible `manage-pihole.yml`):

```
semaphore.cogmai.com → 10.10.100.55  (points to Traefik)
```

#### Traefik Dynamic Configuration

Add to `/etc/traefik/dynamic/services.yml` on CT-313:

```yaml
http:
  routers:
    semaphore:
      rule: "Host(`semaphore.cogmai.com`)"
      entryPoints:
        - websecure
      service: semaphore
      tls:
        certResolver: letsencrypt

  services:
    semaphore:
      loadBalancer:
        servers:
          - url: "http://10.10.100.57:3000"
```

#### Cloudflare Tunnel (optional — remote access)

Add `semaphore.cogmai.com` to the cloudflared tunnel configuration on CT-312 if remote access is desired.

#### Validation

```bash
curl -I https://semaphore.cogmai.com
# Expected: HTTP/2 200 with valid TLS certificate
```

### 5.4 Phase 7A-4: Infrastructure Integration (20 minutes)

#### Ansible Inventory Update

In `~/colossus-ansible/inventory/hosts.yml`, add under `infrastructure`:

```yaml
        semaphore:
          ansible_host: 10.10.100.57
          ctid: 315
```

#### Deploy Alloy Agent

Deploy Grafana Alloy agent to CT-315 using existing role:

```bash
ansible-playbook playbooks/deploy-alloy.yml --limit semaphore
```

This extends monitoring coverage from 11 managed hosts to 12 (Alloy agents) and bumps Prometheus targets from 18 to 19.

#### Configure PBS Backup for CT-315

Create a PBS backup job for CT-315 from Proxmox UI on pve-3:

- **Storage:** PBS (pbs-storage)
- **Schedule:** Daily at 02:00
- **Selection:** CT 315
- **Retention:** Keep daily: 14, weekly: 8, monthly: 12
- **Mode:** Snapshot
- **Compression:** ZSTD

Validate the first backup completes successfully.

#### Configure Syslog Forwarding (v2.17 Feature)

Configure Semaphore to forward logs to the Alloy syslog listener on VM-314 for centralized logging in Loki. Add to `config.json`:

```json
{
  "syslog": {
    "host": "10.10.100.56:514",
    "protocol": "udp"
  }
}
```

### 5.5 Phase 7A-5: Semaphore Project Configuration (15 minutes)

Configure via the Semaphore Web UI at `https://semaphore.cogmai.com`. See Section 7 for complete details.

### 5.6 Phase 7A-6: SSH Connectivity Validation (10 minutes)

**Critical early test.** Before building any playbooks, validate that Semaphore can SSH to all managed hosts. Semaphore binds SSH keys to inventory, but Ansible reads `ansible_user` from group_vars. Test this explicitly:

1. Create a simple "ping all hosts" task template
2. Run it against the full inventory
3. Verify all 11 hosts respond successfully
4. Pay special attention to CoreOS hosts (ansible_user: core) vs LXC hosts (ansible_user: root)

If SSH fails for specific host types, the issue is likely key store configuration — Semaphore needs separate key store entries per SSH user. See Section 7.2.

---

## 6. Neo4j Sync — Separate Phase Playbook Architecture

### 6.1 Critical Design Change: No Monolithic Pause-Based Playbook

**Problem:** The Ansible `pause` module requires a TTY (terminal) to function. AWX issue #1897 documents that `pause` hangs indefinitely in non-interactive environments. Semaphore runs Ansible as a subprocess with no terminal attached. A monolithic playbook with `pause` gates at phase boundaries would hang at the first pause.

**Solution:** Replace the single monolithic playbook with **separate playbooks per phase**, each triggered manually from the Semaphore UI. The operator's workflow becomes:

1. Run Phase 1 (preflight) → review output in Semaphore UI
2. Click "Run" on Phase 2 (backup) → review output
3. Click "Run" on Phase 3 (dump) → review output
4. Continue through all phases

Semaphore's "Run" button in the web UI becomes the pause mechanism. This is actually a **better** design:

- Each phase has its own audit trail entry in Semaphore execution history
- Operator can review output between phases without time pressure
- Individual phases can be re-run if they fail without restarting the entire workflow
- No TTY dependency — works reliably in any automation platform
- Phase timing is captured per-playbook rather than buried in a single long run

### 6.2 Playbook Architecture

```
playbooks/neo4j-sync/
├── 01-preflight.yml            # Phase 1: Health checks on both environments
├── 02-backup-prod.yml          # Phase 2: PBS + application-level backup
├── 03-dump-dev.yml             # Phase 3: Create DEV dump, restart DEV
├── 04-transfer.yml             # Phase 4: Transfer dump file to PROD host
├── 05-load-prod.yml            # Phase 5: Load into PROD (⚠ DESTRUCTIVE)
├── 06-validate.yml             # Phase 6: Data parity validation
├── 07-cleanup.yml              # Phase 7: Remove temporary files
└── rollback.yml                # Emergency: Restore from Phase 2 backup
```

### 6.3 Key Playbook Patterns

#### Validation Gates (Assert Module)

```yaml
# In 01-preflight.yml
- name: "GATE: Verify DEV Neo4j is healthy before dump"
  ansible.builtin.uri:
    url: "http://{{ dev_db_host }}:7474"
    method: GET
    status_code: 200
  register: dev_health

- name: "GATE: Assert DEV Neo4j responded"
  ansible.builtin.assert:
    that:
      - dev_health.status == 200
    fail_msg: "DEV Neo4j is not responding. Aborting sync."
    success_msg: "DEV Neo4j health check passed."
```

#### Phase Summary Output (Replaces Pause Prompts)

```yaml
# End of each phase playbook — output summary for operator review in Semaphore UI
- name: "PHASE 2 COMPLETE — Review before proceeding"
  ansible.builtin.debug:
    msg: |
      ═══════════════════════════════════════════════════
       PHASE 2: PROD BACKUP COMPLETE
       PBS snapshot: {{ pbs_snapshot_id | default('check PBS UI') }}
       App backup: {{ prod_backup_path }}

       ► Review this output, then run Phase 3 (03-dump-dev)
       ► The NEXT phase will STOP the DEV Neo4j container
      ═══════════════════════════════════════════════════
```

#### SELinux-Aware Container Operations (CoreOS + Podman)

```yaml
- name: "Stop Neo4j container on DEV"
  ansible.builtin.command: >
    sudo systemctl stop colossus-neo4j.service
  become: false  # core user runs sudo

- name: "Create Neo4j dump on DEV (one-shot Podman container)"
  ansible.builtin.command: >
    sudo podman run --rm
    --security-opt label=disable
    -v /var/mnt/data/neo4j:/data
    docker.io/library/neo4j:5
    neo4j-admin database dump neo4j --to-path=/data
  become: false
```

### 6.4 Transfer Path Clarification

When Semaphore (CT-315) runs the transfer playbook, the dump file path is:

```
VM-210 (DEV) → CT-315 (Semaphore, intermediary) → VM-110 (PROD)
```

**Not** through proxima-centauri as in the manual runbook. Important considerations:

- CT-315 has 4GB root disk. Neo4j dumps are currently 50–200MB — acceptable.
- If the database grows significantly, consider direct VM-to-VM transfer using `delegate_to` patterns or TrueNAS shared storage as intermediary.
- Alternative: use the Proxmox host filesystem (`/tmp` on pve nodes) as a transfer point, avoiding Semaphore disk entirely.

### 6.5 Execution Flow

```
Phase 1: Pre-flight (01-preflight.yml)
  ├── Assert DEV Neo4j healthy (HTTP 7474)
  ├── Assert PROD Neo4j healthy (HTTP 7474)
  ├── Assert DEV node count > 0
  ├── Assert PROD PBS storage accessible
  └── Display current state summary
         │
    ► OPERATOR: Review output in Semaphore UI, click "Run" on Phase 2
         │
Phase 2: Backup PROD (02-backup-prod.yml)
  ├── Trigger PBS backup of VM-110 (vzdump)
  ├── Wait for PBS job completion
  ├── Create application-level Neo4j dump on PROD
  ├── Assert backup files exist
  └── Record backup IDs for rollback reference
         │
    ► OPERATOR: Review output, click "Run" on Phase 3
         │
Phase 3: Dump DEV (03-dump-dev.yml)
  ├── Stop colossus-neo4j.service on VM-210
  ├── Run neo4j-admin database dump (one-shot Podman container)
  ├── Assert dump file exists and size > 0
  ├── Restart colossus-neo4j.service on VM-210
  └── Assert DEV Neo4j recovers (HTTP 7474)
         │
Phase 4: Transfer (04-transfer.yml)
  ├── SCP dump file: VM-210 → CT-315 (or direct VM-to-VM)
  ├── SCP dump file: CT-315 → VM-110
  ├── Assert dump file checksum matches on destination
  └── Report transfer size and duration
         │
    ► OPERATOR: ⚠ DESTRUCTIVE OPERATION AHEAD — Review, click "Run" on Phase 5
         │
Phase 5: Load PROD (05-load-prod.yml) ⚠ DESTRUCTIVE
  ├── Stop colossus-neo4j.service on VM-110
  ├── Run neo4j-admin database load (one-shot Podman, --overwrite-destination)
  ├── Assert load completed without errors
  ├── Restart colossus-neo4j.service on VM-110
  └── Wait for PROD Neo4j to become healthy (retry loop, up to 60s)
         │
Phase 6: Validate (06-validate.yml)
  ├── Query PROD node count via Cypher HTTP API
  ├── Query DEV node count via Cypher HTTP API
  ├── Assert PROD node count == DEV node count
  ├── Query PROD relationship count
  ├── Assert PROD relationship count == DEV relationship count
  └── Display validation summary
         │
    ► OPERATOR: Review validation, click "Run" on Phase 7 (or run rollback.yml if failed)
         │
Phase 7: Cleanup (07-cleanup.yml)
  ├── Remove dump files from DEV, CT-315, and PROD
  └── Display final summary with timings
```

### 6.6 Rollback Procedure

If validation fails at Phase 6, the operator runs `rollback.yml` from Semaphore:

1. Stop PROD Neo4j: `systemctl stop colossus-neo4j.service` on VM-110
2. Restore from pre-sync dump: `neo4j-admin database load` using the Phase 2 backup
3. Restart PROD Neo4j
4. Validate restored data matches pre-sync state

### 6.7 Incremental Build Strategy

Build and test each phase playbook incrementally rather than big-bang:

1. **Phase 1 first:** preflight checks only. Run from Semaphore, validate works.
2. **Add Phase 2:** backup. Run, validate PBS integration works from Semaphore.
3. **Add Phase 3:** DEV dump — first service-disrupting step, test against DEV only.
4. **Build up to full workflow** only after each phase individually validated.

This matches the wave-based deployment pattern used for Alloy agent rollout.

---

## 7. Semaphore Project & Template Configuration

### 7.1 Project Structure

Configuration performed via the Semaphore Web UI at `https://semaphore.cogmai.com`:

| Semaphore Object | Configuration |
|-----------------|---------------|
| **Project name** | `Colossus Infrastructure` |
| **Repository** | `colossus-ansible` (GitHub `rhrywnak/colossus-ansible`, main branch) |
| **Inventory** | `colossus-all-hosts` (from `inventory/hosts.yml`) |
| **Environment** | `colossus-production` |

### 7.2 Key Store Entries

| Key Name | Type | Purpose |
|----------|------|---------|
| `ssh-key-root` | SSH Key (login: root) | Proxmox nodes, LXC containers, PBS |
| `ssh-key-core` | SSH Key (login: core) | CoreOS VMs (VM-110, 120, 210, 220) |
| `ansible-vault-password` | Login with password | Decrypts Ansible Vault secrets |
| `github-access` | None (or token) | Git clone of colossus-ansible |

**SSH Key Architecture Note:** Semaphore binds SSH key to inventory, not individual hosts. Since Ansible reads `ansible_user` from group_vars (core for CoreOS VMs, root for LXCs), this should work natively. However, this must be validated explicitly during Phase 7A-6 (SSH Connectivity Validation) — don't discover issues mid-sync.

### 7.3 Task Templates

| Template Name | Playbook | Schedule | Tags |
|--------------|----------|----------|------|
| **Neo4j Sync: 01-Preflight** | `playbooks/neo4j-sync/01-preflight.yml` | On-demand | neo4j, sync |
| **Neo4j Sync: 02-Backup** | `playbooks/neo4j-sync/02-backup-prod.yml` | On-demand | neo4j, sync |
| **Neo4j Sync: 03-Dump DEV** | `playbooks/neo4j-sync/03-dump-dev.yml` | On-demand | neo4j, sync |
| **Neo4j Sync: 04-Transfer** | `playbooks/neo4j-sync/04-transfer.yml` | On-demand | neo4j, sync |
| **Neo4j Sync: 05-Load PROD ⚠** | `playbooks/neo4j-sync/05-load-prod.yml` | On-demand | neo4j, sync, destructive |
| **Neo4j Sync: 06-Validate** | `playbooks/neo4j-sync/06-validate.yml` | On-demand | neo4j, sync |
| **Neo4j Sync: 07-Cleanup** | `playbooks/neo4j-sync/07-cleanup.yml` | On-demand | neo4j, sync |
| **Neo4j Sync: Rollback** | `playbooks/neo4j-sync/rollback.yml` | On-demand | neo4j, rollback |
| **Infrastructure Health Check** | `playbooks/validate-all.yml` | Daily 06:00 | health, validation |
| **PBS Backup Verification** | `playbooks/verify-backups.yml` | Daily 08:00 | backup, validation |
| **Drift Detection** | `playbooks/drift-detect.yml` | Weekly Sun 03:00 | drift, audit |
| **Database Backup (DEV)** | `playbooks/backup-dev-databases.yml` | Daily 01:00 | backup, dev |
| **Database Backup (PROD)** | `playbooks/backup-prod-databases.yml` | Daily 02:00 | backup, prod |
| **Container Image Update** | `playbooks/update-containers.yml` | On-demand | update, maintenance |

### 7.4 Scheduling Strategy

| Schedule | Purpose | Alert on Failure |
|----------|---------|-----------------|
| **Daily 01:00** | DEV database backups (PostgreSQL, Neo4j, Qdrant) | Yes |
| **Daily 02:00** | PROD database backups | Yes |
| **Daily 06:00** | Full infrastructure health check (all hosts) | Yes |
| **Daily 08:00** | PBS backup verification (confirm all jobs ran) | Yes |
| **Weekly Sun 03:00** | Drift detection (`--check --diff` mode) | Yes (if drift detected) |

---

## 8. Monitoring & Observability Integration

### 8.1 Alloy Agent Deployment

Deploy a Grafana Alloy agent on CT-315 following the same pattern as existing infrastructure containers:

- **Metrics:** node_exporter metrics (CPU, memory, disk, network)
- **Logs:** journald logs for semaphore.service
- **Forward to:** Prometheus (metrics) and Loki (logs) on VM-314

This extends monitoring coverage from 11 managed hosts to 12 (Alloy agents from 11 to 12, Prometheus targets from 18 to 19).

### 8.2 Syslog Integration (v2.17)

Semaphore v2.17 supports native syslog forwarding. Configure Semaphore to send logs to the Alloy syslog listener on VM-314 (UDP 514), which forwards to Loki. This provides centralized Semaphore operational logs alongside all other infrastructure logs.

### 8.3 Grafana Dashboard

Create a "Semaphore Operations" panel in the existing infrastructure dashboard:

- **Container health:** CT-315 CPU, memory, disk usage (from Alloy node_exporter)
- **Service uptime:** semaphore.service active state via journal logs
- **Semaphore logs:** Operational logs via Loki (from syslog forwarding)

### 8.4 Alerting Rules

Add to Prometheus alerting configuration on VM-314:

```yaml
groups:
  - name: semaphore
    rules:
      - alert: SemaphoreDown
        expr: up{instance=~"10.10.100.57.*"} == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Semaphore (CT-315) is unreachable"
```

---

## 9. Security Considerations

### 9.1 Credential Management

| Credential | Storage Location | Access |
|-----------|-----------------|--------|
| SSH private key | Semaphore Key Store (encrypted via `access_key_encryption`) | Semaphore process only |
| Ansible Vault password | Semaphore Key Store | Injected at playbook runtime |
| Semaphore admin password | Created during setup, stored in SQLite (bcrypt) | Web UI login |
| Cookie/encryption keys | `/etc/semaphore/config.json` (chmod 600, owned by semaphore) | Semaphore process only |

### 9.2 Network Security

- Semaphore web UI accessible only via Traefik with TLS (Let's Encrypt)
- Direct access to port 3000 only from internal 10.10.100.0/24 network
- SSH from Semaphore to managed hosts uses the same Ed25519 key already deployed

### 9.3 Service Isolation

- Semaphore runs as non-root `semaphore` user
- Unprivileged LXC container (no elevated Proxmox capabilities)
- No container runtime installed — no attack surface from Docker/Podman daemons
- Ansible executes in a Python virtual environment, isolated from system Python

---

## 10. Backup & Disaster Recovery

### 10.1 Backup Strategy (Layered)

| Layer | What | How | Retention |
|-------|------|-----|-----------|
| **PBS** | Full CT-315 snapshot (includes SQLite DB) | Proxmox vzdump to PBS | Daily 14, Weekly 8, Monthly 12 |
| **Project Export** | Semaphore project configuration | `semaphore project export` CLI (v2.17) | On-demand, store in Git |
| **Git** | All playbooks and configuration | GitHub private repo (`colossus-ansible`) | Unlimited (Git history) |
| **Config** | `/etc/semaphore/config.json` | Inside PBS CT-315 snapshot + can be version-controlled | Per PBS retention |

**Advantage of SQLite:** The database is inside CT-315, so PBS snapshots capture everything — binary, config, database, and state. No separate database backup needed.

### 10.2 Recovery Procedure

**Scenario: CT-315 destroyed or corrupted**

1. Restore CT-315 from PBS backup (fastest — full state recovery), OR:
2. Recreate CT-315 from the `pct create` command in Section 5.1
3. Install prerequisites (Section 5.2, Steps 1–5)
4. Install Semaphore binary (Section 5.2, Step 6)
5. Restore `/etc/semaphore/config.json` from backup or recreate from documented values
6. Restore SQLite database from PBS backup, or start fresh and import project via `semaphore project import` CLI (v2.17)
7. Create systemd service (Section 5.2, Step 8)
8. Start service

**Estimated recovery time:** 10–15 minutes from PBS restore, 20–25 minutes from scratch.

**v2.17 Enhancement:** Project export/import via CLI means project configuration (templates, inventories, environments) can be version-controlled separately from the database, providing an additional recovery path.

---

## 11. Success Metrics

### 11.1 Deployment Success Criteria

| # | Criterion | Validation Method |
|---|-----------|------------------|
| 1 | CT-315 created and running on pve-3 | `pct status 315` shows "running" |
| 2 | Semaphore v2.17 installed and healthy | `semaphore version` returns 2.17.x |
| 3 | Semaphore web UI accessible via TLS | `curl -s https://semaphore.cogmai.com/api/ping` returns "pong" |
| 4 | GitHub repo connected and syncing | Repository shows successful sync in UI |
| 5 | All 11 hosts visible in Semaphore inventory | Inventory view shows all hosts |
| 6 | SSH connectivity to all hosts from Semaphore | "Ping all" task template succeeds (both root and core users) |
| 7 | Ansible Vault decryption works | Playbook referencing vault variables executes |
| 8 | PBS backup of CT-315 configured and validated | First backup completes successfully |
| 9 | Alloy agent reporting CT-315 metrics | CT-315 appears as UP in Prometheus targets (target 19/19) |
| 10 | Neo4j sync Phase 1 (preflight) executes from Semaphore | Preflight playbook runs and reports health status |

### 11.2 Operational Success Metrics (30-Day)

| Metric | Target | Measurement |
|--------|--------|-------------|
| Scheduled task success rate | >95% | Semaphore execution history |
| Manual SSH for routine operations | 0 | All routine ops via Semaphore |
| Unscheduled backup gaps | 0 | PBS verification playbook |
| Drift detection findings addressed | 100% within 7 days | Weekly drift report |
| Semaphore uptime | >99.5% | Prometheus UP metric |

### 11.3 What "Done" Looks Like

Phase 7A is complete when:

1. CT-315 is running, backed up, monitored, and accessible via Traefik
2. All Neo4j sync phase playbooks execute successfully from the Semaphore UI
3. At least 3 recurring templates are scheduled (health check, backup verification, drift detection)
4. SSH connectivity validated to all managed hosts from Semaphore

---

## 12. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| PBS backups not operational (prerequisite) | **Known issue** | **High** | Must fix before starting Phase 7A. Listed as prerequisite P1. |
| SQLite corruption from power loss | Very Low | Medium | PBS daily snapshots; can migrate to PostgreSQL if stability concerns arise |
| LXC container resource exhaustion | Low | Low | 512MB cap with swap; Go binary is lightweight |
| Semaphore binary update breaks compatibility | Low | Medium | Pin version; v2.17 supports migration rollback; test updates in maintenance window |
| SSH key compromise via Semaphore config | Low | High | config.json chmod 600; unprivileged LXC; dedicated key option (future) |
| `pause` module hangs in Semaphore (TTY issue) | **Eliminated** | — | Replaced with separate phase playbooks. No pause modules used. |
| GitHub unavailable blocks repo sync | Low | Low | Semaphore caches last successful clone |
| Dump file exceeds CT-315 disk during transfer | Low | Medium | Monitor dump size growth; use delegate_to pattern or shared storage if needed |
| Stale inventory (VM-200 still listed) | **Known issue** | Low | Prerequisite P2: remove before Semaphore deployment |

---

## 13. Future Expansion

### 13.1 Near-Term (Post-Phase 7A)

| Enhancement | Priority |
|-------------|----------|
| Webhook notifications (Semaphore → Alertmanager) for task failures | High |
| Additional playbooks: cert renewal, TrueNAS health, image update | High |
| Dedicated Semaphore SSH key (separate from workstation key) | Medium |
| Semaphore API integration with monitoring alerts | Medium |
| Migrate to PostgreSQL if SQLite shows limitations | Medium |

### 13.2 Medium-Term

| Enhancement | Priority |
|-------------|----------|
| Terraform/OpenTofu integration for VM/CT lifecycle | Medium |
| Atuin Desktop on proxima-centauri for ad-hoc interactive runbooks | Medium |
| MCP server integration (cloin/semaphore-mcp) for AI-assisted operations | Low |
| Multi-user access for controlled delegation | Low |

### 13.3 Long-Term Vision

Every operational procedure is an executable workflow, visible and triggerable from a web dashboard, with full audit trail. New VMs/CTs are automatically integrated into monitoring, backup, DNS, and Traefik routing via a single "onboard new resource" playbook. Configuration drift is detected weekly and remediated proactively. The operator's role shifts from executing procedures to reviewing results and making decisions at phase boundaries.

---

## 14. Decision Log

| # | Decision | Rationale | Date |
|---|----------|-----------|------|
| 1 | Semaphore UI over Rundeck, StackStorm, AWX | Minimal footprint (Go binary), direct Ansible integration, homelab-appropriate, healthy community (159 contributors) | 2026-02-17 |
| 2 | Native `.deb` binary in LXC, not Docker | Colossus architecture: no Docker in LXC, no `nesting=1`. Follows CT-311/312/313 pattern. LXC correct because Semaphore is single binary + SSH, not composable containers. | 2026-02-17 |
| 3 | **SQLite initially, PostgreSQL later** (changed from v2) | Zero external dependencies, faster deployment, simpler DR (database inside PBS snapshot). Migrate to PostgreSQL when/if needed — v2.17 includes CLI migrator. | 2026-02-17 |
| 4 | ~~PROD PostgreSQL (VM-110)~~ | **Deferred.** Original rationale valid (stability, backup coverage) but SQLite eliminates circular dependency risk and cross-VM networking. Preserved for future migration. | 2026-02-17 |
| 5 | CT-315 on pve-3 | Infrastructure services belong on infra node. Follows established pattern. | 2026-02-17 |
| 6 | Traefik route with TLS | Consistent with all other web services. Encrypted access from anywhere on LAN. | 2026-02-17 |
| 7 | Reuse existing SSH key (initially) | All hosts already trust this key. Dedicated Semaphore key is future hardening. | 2026-02-17 |
| 8 | **Separate phase playbooks** (changed from v2) | Replaces monolithic pause-based playbook. `pause` module hangs without TTY in Semaphore (AWX #1897). Separate playbooks give better audit trail, per-phase retry, and no TTY dependency. | 2026-02-17 |
| 9 | 512MB RAM (not 1024MB) | No container runtime, no local database server. Go binary + Ansible fit comfortably. | 2026-02-17 |
| 10 | **Atuin Desktop: deploy on workstation** (changed from v2) | Promoted from "monitor only" to complementary tool. Handles interactive procedures where operator is at keyboard. Clean separation: Semaphore=scheduled, Atuin=interactive. | 2026-02-17 |
| 11 | Target Semaphore v2.17 | Latest stable (Feb 15, 2026). Includes syslog support, project export/import CLI, one-time schedules, migration rollback. | 2026-02-17 |
| 12 | PBS fix as hard prerequisite | Neo4j sync Phase 2 depends on PBS backup. Phase 6A-3 flagged PBS jobs not running. Must resolve before Semaphore can orchestrate backup-dependent workflows. | 2026-02-17 |

---

## 15. References

### 15.1 External

| Resource | URL |
|----------|-----|
| Semaphore UI GitHub Repository | https://github.com/semaphoreui/semaphore |
| Semaphore UI Documentation | https://docs.semaphoreui.com/ |
| Semaphore Manual Installation Guide | https://docs.semaphoreui.com/administration-guide/installation_manually/ |
| Semaphore Package Manager Installation | https://docs.semaphoreui.com/administration-guide/installation/package-manager/ |
| Semaphore GitHub Releases | https://github.com/semaphoreui/semaphore/releases |
| Semaphore Configuration Reference | https://docs.semaphoreui.com/administration-guide/configuration/ |
| Semaphore v2.17 Release Notes | https://semaphoreui.com/releases/semaphore-v2_17 |
| Semaphore Repositories (auto requirements.yml) | https://docs.semaphoreui.com/user-guide/repositories/ |
| Ansible `assert` Module | https://docs.ansible.com/ansible/latest/collections/ansible/builtin/assert_module.html |
| AWX Issue #1897 (pause TTY hang) | https://github.com/ansible/awx/issues/1897 |
| Atuin Desktop GitHub | https://github.com/atuinsh/desktop |
| Semaphore MCP Server | https://github.com/cloin/semaphore-mcp |

### 15.2 Internal (Colossus Project)

| Document | Purpose |
|----------|---------|
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v5.md` | Canonical project reference |
| `COLOSSUS_ANSIBLE_RUNBOOK_v2.md` | Ansible foundation documentation |
| `COLOSSUS_ANSIBLE_FOUNDATION_RUNBOOK_v1.md` | Phase 5B-1 implementation details |
| `NEO4J_DEV_TO_PROD_SYNC_RUNBOOK.md` | Original manual sync procedure |
| `COLOSSUS_DEV_BACKUP_RESTORE_RUNBOOK_v1.md` | Database backup/restore procedures |
| `COLOSSUS_MONITORING_STACK_DESIGN_v2.md` | Monitoring architecture (Alloy agent patterns) |
| `COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md` | Ansible design including Semaphore evaluation |
| `COLOSSUS_COREOS_VM_CREATION_RUNBOOK_v1.md` | VM creation patterns (virtiofs, SELinux) |
| `PHASE6A_3_SESSION_TRANSITION.md` | Current state, PBS backup issue flagged |

---

## Appendix A: IP Address Allocation

| IP Address | Host | Purpose |
|-----------|------|---------|
| 10.10.100.2 | pve-2 | DEV Proxmox node |
| 10.10.100.3 | pve-1 | PROD Proxmox node |
| 10.10.100.5 | pve-3 | Infra Proxmox node |
| 10.10.100.53 | CT-311 | Pi-hole DNS |
| 10.10.100.54 | CT-312 | cloudflared tunnel |
| 10.10.100.55 | CT-313 | Traefik reverse proxy |
| 10.10.100.56 | VM-314 | Monitoring stack |
| **10.10.100.57** | **CT-315** | **Semaphore UI** ← NEW |
| 10.10.100.110 | VM-110 | PROD database (Neo4j, PostgreSQL, Qdrant) |
| 10.10.100.120 | VM-120 | PROD application |
| 10.10.100.200 | VM-210 | DEV database (Neo4j, PostgreSQL, Qdrant) |
| 10.10.100.220 | VM-220 | DEV application |
| 10.10.100.242 | VM-900 | PBS (Proxmox Backup Server) |

**Note:** VM-200 has been flagged for removal from inventory (Prerequisite P2).

---

## Appendix B: Estimated Resource Impact on pve-3

| Resource | Current Usage | After CT-315 | Notes |
|----------|--------------|--------------|-------|
| **VMs/CTs** | 5 (VM-900, CT-311–313, VM-314) | 6 | Well within limits |
| **Memory** | ~7.5GB allocated | ~8.0GB allocated | pve-3 has 64GB total |
| **Storage** | Varies | +4GB (CT-315 root disk) | local-lvm has capacity |
| **CPU** | ~6 cores allocated | ~7 cores allocated | pve-3 has 16 threads |

CT-315 adds trivial overhead — 1 core and 512MB RAM for a service that is idle most of the time.

---

## Appendix C: PostgreSQL Migration Reference (Deferred)

When migrating from SQLite to PostgreSQL, use these steps:

```bash
# On VM-110: Create database
ssh core@10.10.100.110 'sudo podman exec -i colossus-postgres psql -U postgres' << 'SQL'
CREATE USER semaphore WITH PASSWORD '<password>';
CREATE DATABASE semaphore OWNER semaphore;
GRANT ALL PRIVILEGES ON DATABASE semaphore TO semaphore;
SQL

# On CT-315: Migrate data
sudo -u semaphore semaphore migrate --config /etc/semaphore/config-postgres.json

# Update config.json to use PostgreSQL dialect
# Restart semaphore.service
```

PostgreSQL on VM-110 listens on 0.0.0.0:5432. If `pg_hba.conf` restricts connections by source IP, add an entry for 10.10.100.57/32 (CT-315).

---

*End of Document*
