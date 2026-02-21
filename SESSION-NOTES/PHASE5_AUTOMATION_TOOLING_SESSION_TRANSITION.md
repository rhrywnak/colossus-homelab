# PHASE 5 — Automation Tooling Research: Session Transition Document

**Date:** Sunday, Feb 9, 2026  
**Phase:** Pre-Phase 5 — Automation Tooling Evaluation  
**Status:** Research complete; decision and execution pending  
**Sessions consumed:** 6 (context limit reached)

---

## 1. Purpose of This Document

This document captures the full research and analysis performed across multiple
sessions today evaluating open-source automation tooling for the Colossus homelab.
It enables a clean session restart without re-research.

---

## 2. Current Project State (Locked)

### 2.1 Completed Phases

| Phase | Status | Date |
|-------|--------|------|
| Phase 1 — Backups & PBS | 🔒 Locked | 2026-02-05 |
| Phase 2 — DEV DB Externalization | 🔒 Locked | 2026-02-08 |
| Phase 3 — PROD DB Deployment | 🔒 Locked | 2026-02-09 |

### 2.2 Phase 4 — Designed, Not Yet Executed

Phase 4 has two sub-phases:

- **Phase 4A:** Colossus-Legal application deployment (VM-220 DEV, VM-120 PROD)
- **Phase 4B:** Edge services — DNS, Pi-hole, Cloudflare Tunnel (VM-310, CT-311)

Design documents delivered:
- `COLOSSUS_PHASE4_DESIGN_v1.md`
- `COLOSSUS_PHASE4_EXECUTION_CHECKLIST.md`

### 2.3 VM Inventory (Current)

| VMID | Name | Node | IP | Role | Status |
|------|------|------|----|------|--------|
| 110 | colossus-prod-db1 | pve-1 | 10.10.100.110 | PROD DB host | Running |
| 200 | colossus-db1-dev | pve-2 | 10.10.100.50 | Frozen DEV reference | Running |
| 210 | colossus-dev-db1 | pve-2 | 10.10.100.200 | Active DEV DB host | Running |
| 900 | PBS | pve-3 | — | Proxmox Backup Server | Running |

### 2.4 Planned VMs (Phase 4)

| VMID | Name | Node | Role |
|------|------|------|------|
| 120 | colossus-prod-app1 | pve-1 | PROD application host |
| 220 | colossus-dev-app1 | pve-2 | DEV application host |
| 310 | colossus-edge1 | pve-3 | Edge services (cloudflared) |
| 311 | CT — pihole | pve-3 | Pi-hole DNS (LXC container) |

### 2.5 Key Infrastructure Facts

- **pve-1 NIC issue:** Intel igc (i225/i226) intermittent SSH drops under burst traffic. SSH multiplexing is the workaround. ethtool offload changes need to be made persistent.
- **CoreOS auto-updates:** Zincati enabled by default, reboots VM. PROD needs maintenance window strategy.
- **Colossus-Legal application:** Rust backend (port 3403) + React frontend (port 5473), connects to Neo4j on DB VM. Stateless containers with document PDF mount.

---

## 3. Automation Tooling Research — Full Summary

### 3.1 Tools Evaluated

The following tools were researched in depth across 6 sessions:

| Category | Tool | Status |
|----------|------|--------|
| **Container Management** | Komodo | Evaluated — good for Docker, Podman support immature |
| **Configuration Management** | Ansible | Evaluated — strong recommendation for Colossus |
| **Ansible Orchestration** | Semaphore UI | Evaluated — recommended lightweight UI |
| **Ansible Orchestration** | AWX | Evaluated — too heavy for homelab (requires K8s) |
| **Ansible Orchestration** | Rundeck | Evaluated — tool-agnostic, more complex than needed |
| **IaC — Provisioning** | OpenTofu | Evaluated — recommended over Terraform (licensing) |
| **IaC — Provisioning** | Terraform | Evaluated — BSL license concern, EOL for OSS July 2025 |
| **Git + CI/CD** | Forgejo + Actions | Evaluated — recommended for self-hosted Git |
| **CI/CD** | Woodpecker CI | Evaluated — mature alternative to Forgejo Actions |
| **Golden Images** | Packer | Evaluated — useful but not needed immediately |
| **Secrets — Built-in** | Ansible Vault | Evaluated — recommended starting point |
| **Secrets — SaaS** | Doppler | Evaluated — free tier for ≤3 users, zero ops |
| **Secrets — Self-hosted** | Infisical | Evaluated — MIT license, developer-friendly |
| **Secrets — Self-hosted** | OpenBao | Evaluated — Vault fork under Linux Foundation |
| **Secrets — Self-hosted** | HashiCorp Vault | Evaluated — enterprise-grade, complex for homelab |
| **Secrets — File-level** | Mozilla SOPS | Evaluated — file encryption, not full secrets manager |
| **Secrets — Password Mgr** | Bitwarden CLI | Evaluated — works for simple automation secrets |

---

### 3.2 Komodo — Container Management Platform

**What it is:** Self-hosted web app for Docker container management (GPLv3). Server + Periphery agent architecture, similar to Portainer but with GitOps emphasis.

**Strengths:**
- Clean UI for managing Docker Compose stacks across multiple hosts
- Declarative infrastructure via TOML files synced from Git
- Build pipeline support (build images, deploy, automated procedures)
- Active community, rapidly growing in homelab space (2025–2026)
- Free and open-source

**Weaknesses for Colossus:**
- **Podman support is immature** — Colossus uses Podman + Quadlet on CoreOS, not Docker
- Agent (Periphery) expects Docker socket
- Would require either switching to Docker or waiting for Podman maturity
- CoreOS immutable filesystem complicates agent installation

**Verdict:** Great tool, wrong fit for current Colossus architecture. Revisit if/when Podman support matures or if adding Docker-based service VMs.

---

### 3.3 Ansible — Configuration Management & Automation

**What it is:** Agentless IT automation tool. SSH-based, YAML playbooks, idempotent operations.

**Why it fits Colossus:**
- Agentless — works with CoreOS immutable filesystem (SSH only)
- Idempotent — run playbooks repeatedly, only changes what needs changing
- Covers the full lifecycle: VM provisioning → configuration → deployment → validation
- `community.proxmox` collection provides 20+ modules for Proxmox management
- Ansible Vault built-in for secrets (zero additional infrastructure)
- Huge ecosystem, excellent documentation, massive community

**Proxmox Modules (community.proxmox):**
- `proxmox_kvm` — Create/manage KVM VMs (clone from template, cloud-init config)
- `proxmox` — Create/manage LXC containers
- `proxmox_disk`, `proxmox_nic`, `proxmox_backup`, etc.
- Requires `proxmoxer` Python library on control node

**Practical Implementation Pattern:**
1. Inventory file defines all hosts (pve-1, pve-2, pve-3, VMs)
2. Playbooks codify existing shell scripts (VM creation, app deployment, backup)
3. Roles organize reusable configuration (database-vm, app-vm, edge-vm)
4. Variables separate DEV vs PROD configuration

**Dependencies:** Python + `proxmoxer` on workstation, SSH access to targets.

**Verdict:** Strong recommendation. Codifies existing shell script patterns with idempotency. Natural evolution from current approach.

---

### 3.4 Ansible Orchestration — Semaphore UI vs AWX vs Rundeck

| Feature | Semaphore UI | AWX | Rundeck |
|---------|-------------|-----|---------|
| Setup complexity | 2 containers (app + DB) | 4-6 containers, often needs K8s | Medium, Java-based |
| Resource usage | Light (~256MB RAM) | Heavy (~2-4GB RAM) | Medium (~1GB RAM) |
| Ansible focus | Yes, built for Ansible | Yes, official upstream of Tower | Tool-agnostic |
| Multi-tool support | Ansible, Terraform, OpenTofu, PowerShell | Ansible only | Many tools via plugins |
| Git integration | Yes | Yes | Limited |
| Web UI quality | Modern, clean | Feature-rich but complex | Functional |
| Scheduling | Yes | Yes | Yes (strength) |
| RBAC | Basic | Enterprise-grade | Enterprise-grade |
| License | MIT (open source) | Apache 2.0 | Apache 2.0 (community) |
| Best for | Homelab, small-mid teams | Enterprise, large scale | Self-service operations |

**Verdict:** Semaphore UI recommended for Colossus. Lightweight, modern, supports Ansible + OpenTofu, trivial to deploy as 2 containers.

---

### 3.5 OpenTofu vs Terraform — Infrastructure as Code

**Key facts:**
- OpenTofu is a community fork of Terraform 1.6.x (last open-source version)
- Terraform switched to BSL (Business Source License) in August 2023
- Terraform OSS is EOL after July 2025
- OpenTofu is MPL 2.0 (true open-source) under Linux Foundation governance
- Both use identical HCL syntax and share 3,900+ providers
- OpenTofu adds state encryption (long-requested feature Terraform never delivered)
- Migration from Terraform → OpenTofu is trivial (rename binary, `tofu init`)

**Proxmox Provider:**
- `bpg/proxmox` provider works with both Terraform and OpenTofu
- Can provision VMs, LXC containers, configure storage, networking
- Declarative state management — drift detection

**Verdict:** If using IaC provisioning, use OpenTofu (not Terraform). However, for Colossus immediate needs, Ansible's proxmox modules may be sufficient without adding OpenTofu complexity.

---

### 3.6 Forgejo + CI/CD

**Forgejo:** Self-hosted Git hosting (fork of Gitea, community-governed). Lightweight, single binary or container. Includes issue tracking, pull requests, web IDE.

**Forgejo Actions:** Built-in CI/CD using GitHub Actions-compatible workflow syntax. Requires a runner container alongside Forgejo. Newer but rapidly maturing.

**Woodpecker CI (alternative):** Separate server + agent architecture. More mature than Forgejo Actions, own YAML syntax, established plugin ecosystem. Fork of Drone CI.

**Verdict:** Forgejo recommended for self-hosted Git. For CI/CD, either Forgejo Actions (if wanting GitHub Actions compatibility) or Woodpecker CI (if wanting maturity and distributed agents). Not needed for Phase 4A but valuable for Phase 5+.

---

### 3.7 Packer — Golden Image Builder

**What it does:** Automates VM template creation. Boots from ISO, runs provisioners (shell, Ansible), converts to template.

**Proxmox integration:** `proxmox-iso` and `proxmox-clone` builders connect via Proxmox API.

**CoreOS specifics:** Requires workarounds (qemu-guest-agent in Docker container, `/tmp` as Docker data-root). More complex than standard Ubuntu/Debian images.

**Verdict:** Not needed immediately. Current manual template creation + Ignition works well. Consider for Phase 5+ when managing multiple template variants or automated rebuilds.

---

### 3.8 Secrets Management — Comparison

| Solution | Type | Complexity | Best For |
|----------|------|------------|----------|
| **Ansible Vault** | Built-in | Zero setup | Starting point, small scale |
| **Doppler** | SaaS | Zero ops | Free tier (≤3 users), simple |
| **Bitwarden CLI** | Password mgr | Low | Already using Bitwarden |
| **Infisical** | Self-hosted | Medium | Developer-friendly, MIT license |
| **OpenBao** | Self-hosted | High | Vault-compatible, Linux Foundation |
| **HashiCorp Vault** | Self-hosted | High | Enterprise features, learning |
| **SOPS** | File encryption | Low | GitOps encrypted files |

**Verdict:** Start with Ansible Vault (zero additional infrastructure). Migrate to Infisical or Doppler if centralized management becomes needed.

---

## 4. Recommended Implementation Roadmap

### Phase 4A: Application Deployment (IMMEDIATE)

**Approach:** Makefile or shell scripts (as already designed)
- Manually create VM-220 and VM-120 from CoreOS images
- Deploy Colossus-Legal with Quadlet/systemd
- Use existing deployment patterns from Phase 2/3

**Rationale:** Get the app running. Don't let tooling evaluation block progress.

### Phase 4B: Edge Services

**Approach:** Continue with manual/scripted approach
- Deploy Pi-hole (CT-311), Edge VM (VM-310), Cloudflare Tunnel
- Focus on edge architecture, not automation

### Phase 5A: Ansible Foundation

**Approach:** Install Ansible on workstation
- Create inventory for all Proxmox hosts and VMs
- Convert existing shell scripts to Ansible playbooks
- Use Ansible Vault for secrets
- Test with DEV environment first

**Key playbooks to create:**
1. `create-coreos-vm.yml` — VM provisioning (replaces qm scripts)
2. `deploy-databases.yml` — Database restore and validation
3. `deploy-app.yml` — Colossus-Legal deployment
4. `backup-databases.yml` — Scheduled backup automation

### Phase 5B: Semaphore UI

**Approach:** Deploy Semaphore UI on pve-3 (2 containers)
- Import Ansible playbooks from Git
- Create task templates for common operations
- Set up scheduled tasks (backups, updates)
- Web UI for operational visibility

### Phase 5C: Git Hosting (Optional)

**Approach:** Deploy Forgejo on pve-3
- Self-hosted Git for infrastructure code
- CI/CD via Forgejo Actions or Woodpecker CI
- Automated builds on push

### Phase 5D: IaC with OpenTofu (Optional)

**Approach:** Add OpenTofu for VM provisioning
- Declarative infrastructure state
- Drift detection
- Integrate with Semaphore UI

### Phase 5E: Advanced Secrets (Optional)

**Approach:** Migrate from Ansible Vault to Infisical or Doppler
- Centralized secrets management
- API-based access for CI/CD pipelines

---

## 5. Decision Points Still Open

The following decisions were not finalized during research:

1. **Phase 4A execution approach:** Use existing shell scripts/Makefile as designed, or wait to implement Ansible first?
   - **Recommendation:** Proceed with shell scripts. Don't block on Ansible.

2. **Git hosting:** Forgejo vs external GitHub/GitLab?
   - **Recommendation:** Forgejo for self-hosted (aligns with Colossus principles)

3. **CI/CD engine:** Forgejo Actions vs Woodpecker CI?
   - **Recommendation:** Either works. Forgejo Actions if wanting simplicity + GitHub Actions compat. Woodpecker CI if wanting maturity.

4. **IaC tooling:** OpenTofu vs Ansible-only for VM provisioning?
   - **Recommendation:** Start Ansible-only. Add OpenTofu later if declarative state management is needed.

5. **Secrets management evolution path:** Ansible Vault → what next?
   - **Recommendation:** Ansible Vault now. Evaluate Infisical or Doppler when centralization is needed.

---

## 6. Deliverables Created Today (Across All Sessions)

### 6.1 Documents Delivered to Project

| Document | Location | Purpose |
|----------|----------|---------|
| `COLOSSUS_PHASE3_COMPLETION_REPORT.md` | outputs/ | Phase 3 implementation record |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v2.md` | outputs/ | Updated canonical project reference |
| `COLOSSUS_PHASE4_DESIGN_v1.md` | outputs/ | Phase 4 design (app + edge) |
| `COLOSSUS_PHASE4_EXECUTION_CHECKLIST.md` | outputs/ | Phase 4 execution steps |
| `COLOSSUS_TASK_TRACKER.md` | outputs/ | Open task inventory |

### 6.2 Session Transcripts

| Transcript | Content |
|------------|---------|
| `2026-02-09-19-24-37-phase3-validation-phase4-design.txt` | Phase 3 validation, Phase 4 design |
| `2026-02-09-19-43-59-phase4-deployment-orchestration-komodo-evaluation.txt` | Komodo evaluation, deployment orchestration |
| `2026-02-09-19-46-04-ansible-orchestration-evaluation.txt` | Ansible evaluation |
| `2026-02-09-19-48-03-homelab-automation-tooling-evaluation.txt` | Semaphore UI, OpenTofu, Forgejo evaluation |
| `2026-02-09-19-49-53-homelab-tooling-research-packer-ansible.txt` | Packer, Ansible Proxmox modules |
| `2026-02-09-19-53-23-homelab-automation-stack-comprehensive-research.txt` | Vault alternatives, Woodpecker CI, secrets management |

---

## 7. Known Issues Carried Forward

| Issue | Impact | Workaround |
|-------|--------|------------|
| pve-1 igc NIC intermittent SSH drops | Validation scripts trigger stalls | SSH multiplexing in `~/.ssh/config` |
| ethtool offload changes not persistent on pve-1 | Revert on reboot | Need to add to `/etc/network/interfaces` |
| CoreOS Zincati auto-updates on PROD | Unexpected reboots | Configure maintenance windows |
| VM-200 still running (frozen reference) | Resource usage | Can shut down after confidence period |

---

## 8. Next Session Entry Point

When starting the next session, begin with:

> We are resuming the Colossus Proxmox project.
> Phases 1–3 are complete and locked.
> Phase 4 is designed but not yet executed.
> We completed extensive automation tooling research (documented in
> PHASE5_AUTOMATION_TOOLING_SESSION_TRANSITION.md).
>
> Ready to either:
> (a) Begin Phase 4A execution (Colossus-Legal app deployment), or
> (b) Continue automation stack decisions
>
> Key recommendation from research: Proceed with Phase 4A using existing
> shell script patterns. Implement Ansible as Phase 5A after app is running.

---

## 9. Phase Lock Status

| Phase | Status |
|-------|--------|
| Phase 1 (Backups & PBS) | 🔒 Locked |
| Phase 2 Preparation | 🔒 Locked |
| Phase 2 Execution (DEV) | 🔒 Locked |
| Phase 3 Execution (PROD) | 🔒 Locked |
| Phase 4 Design | ✅ Complete |
| Phase 4A Execution (App Deployment) | ⏳ Pending |
| Phase 4B Execution (Edge Services) | ⏳ Pending |
| Phase 5 Automation Tooling Research | ✅ Complete |
| Phase 5 Execution | ⏳ Not started |
