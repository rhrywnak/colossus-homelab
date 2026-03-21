# Audit Report: colossus-homelab

**Date:** 2026-03-06
**Auditor:** Claude Code
**Repo:** ~/Projects/colossus-homelab
**Master Context Version:** v8 (latest found; no v9 exists yet)

---

## Summary

**21 findings:** 2 CRITICAL, 5 HIGH, 8 MEDIUM, 4 LOW, 2 INFO

---

## Findings

---

### [CRITICAL] C-1: Hardcoded Plaintext Passwords in Butane Files

**Files:**
- `prod-vm-deployment/prod-vm/colossus-prod-app1 (1).bu:51` — `NEO4J_PASSWORD=Drwho2010$`
- `claude-takeover/colossus-phase3/butane/colossus-prod-db1.bu:193` — `POSTGRES_PASSWORD=Drwho2010$`
- `claude-takeover/colossus-phase3/butane/colossus-prod-db1.bu:199` — `NEO4J_AUTH=neo4j/Drwho2010$`
- `claude-takeover/colossus-phase2/butane/colossus-dev-db1.bu:172` — `POSTGRES_PASSWORD=Drwho2010$`
- `claude-takeover/colossus-phase2/butane/colossus-dev-db1.bu:178` — `NEO4J_AUTH=neo4j/Drwho2010$`
- `authentik/authentik.bu:123` — `POSTGRES_PASSWORD=R0U5kZwHs0mdTvsok4ix3LtHPBWK3R`
- `authentik/authentik.bu:134` — `AUTHENTIK_POSTGRESQL__PASSWORD=R0U5kZwHs0mdTvsok4ix3LtHPBWK3R`

**Issue:** Production database passwords are committed to the repository in plaintext. The newer app VM Butane files use `CHANGEME_ANSIBLE_WILL_OVERWRITE` placeholders correctly, but the older phase 2/3 DB Butane files and the Authentik Butane file still contain real passwords. This is a credential leak in version control.

**Recommendation:**
1. Replace all hardcoded passwords with `CHANGEME_*` placeholders
2. Consider rotating the exposed passwords since they are in git history
3. Use Ansible Vault or a secrets manager to inject credentials at deploy time
4. Add a pre-commit hook to scan for password patterns

---

### [CRITICAL] C-2: Master Context Lists Authentik as "Deferred" Despite Active Deployment

**File:** `DOCUMENTS/GENERAL_INFO/COLOSSUS_HOMELAB_MASTER_CONTEXT_v8.md:783`
**Content:** `- **Authentication gateway** — Authentik or similar identity provider` (listed under Deferred future work)

**Issue:** The master context (v8) lists authentication as deferred future work, but significant Authentik work is actively underway:
- `authentik/` directory exists with deployment scripts and Butane config
- `DOCUMENTS/TASK_TRACKERS/COLOSSUS_AUTH_EXECUTION_TASK_TRACKER_v2.md` tracks Authelia-to-Authentik migration (Stages 1-4 complete)
- `DOCUMENTS/DESIGN/COLOSSUS_AUTHELIA_DESIGN_v1.md` exists
- Commit `62756c6` added Authelia design docs; commit `6ba9764` added Authentik fixes
- The auth tracker references VM-316 for Authentik, which is not in the master context inventory

**Recommendation:** Master Context v8 needs a v9 update to:
1. Add a Phase section for auth work (Authelia completed stages + Authentik migration)
2. Move authentication from "Deferred" to "Active" in Future Work
3. Add VM-316 (Authentik) to the VM/CT inventory
4. Document CT-316 (old Authelia LXC) disposition

---

### [HIGH] H-1: Stale Butane File with Old Container Names and Versions

**File:** `prod-vm-deployment/prod-vm/colossus-prod-app1 (1).bu`
- Line 77: `Image=ghcr.io/rhrywnak/colossus-backend:v0.1.0`
- Line 78: `ContainerName=colossus-legal-backend`
- Line 102: `Image=ghcr.io/rhrywnak/colossus-frontend:v0.1.0`
- Line 103: `ContainerName=colossus-legal-frontend`

**Issue:** This file uses v0.1.0 images and the old `colossus-legal-*` container names. The master context (line 363) explicitly states these old names are "obsolete" and were replaced by `colossus-backend`/`colossus-frontend`. The current files (`colossus-prod-app1.bu` and `colossus-dev-app1.bu`) correctly use v0.2.0 and the new names. This copy-with-space-in-name appears to be a leftover artifact that could cause confusion.

**Recommendation:** Delete `colossus-prod-app1 (1).bu` — it is superseded by `colossus-prod-app1.bu`.

---

### [HIGH] H-2: Butane Container Versions Behind Deployed State

**Files:**
- `prod-vm-deployment/prod-vm/colossus-prod-app1.bu:121` — `Image=ghcr.io/rhrywnak/colossus-backend:v0.2.0`
- `prod-vm-deployment/prod-vm/colossus-prod-app1.bu:145` — `Image=ghcr.io/rhrywnak/colossus-frontend:v0.2.0`
- `app-vm-deployment/app-vm/colossus-dev-app1.bu:125` — `Image=ghcr.io/rhrywnak/colossus-backend:v0.2.0`
- `app-vm-deployment/app-vm/colossus-dev-app1.bu:149` — `Image=ghcr.io/rhrywnak/colossus-frontend:v0.2.0`

**Issue:** Master context v8 header says v0.3.2 is deployed. Butane source files reference v0.2.0. Since Ansible manages deployments (overwriting container versions), the Butane files won't cause runtime issues. However, if VMs are ever recreated from Butane/Ignition, they would get v0.2.0 instead of v0.3.2.

**Recommendation:** Update Butane files to reference v0.3.2 (or current version) and retranspile to Ignition.

---

### [HIGH] H-3: Qdrant Using `:latest` Tag in Butane Files

**Files:**
- `claude-takeover/colossus-phase3/butane/colossus-prod-db1.bu:176` — `Image=docker.io/qdrant/qdrant:latest`
- `claude-takeover/colossus-phase2/butane/colossus-dev-db1.bu:155` — `Image=docker.io/qdrant/qdrant:latest`

**Issue:** Using `:latest` for a database container means a VM recreate could pull a breaking Qdrant version. The master context (line 262) also lists Qdrant as `:latest`. All other containers use pinned versions.

**Recommendation:** Pin Qdrant to a specific version (e.g., `qdrant/qdrant:v1.13.2` or whatever is currently deployed) in both Butane files and the master context.

---

### [HIGH] H-4: Traefik Install Scripts Reference Old Container Names

**Files:**
- `traefik-lxc/02-install-traefik (1).sh:192-275` — References `colossus-legal-frontend` in Traefik routing config
- `traefik-lxc/02-install-traefik.sh:202-270` — References `colossus-legal-frontend` in Traefik routing config
- `scripts/app-vm-storage/02-install-traefik*.sh` — Multiple copies with same old name references

**Issue:** Traefik install scripts embed dynamic routing config that references `colossus-legal-frontend` as a service name. While the live Traefik config on CT-313 may have been updated, these scripts would recreate the old routing if ever re-run.

**Recommendation:** Update the Traefik install scripts to use current service naming. Delete the `(1)` and `(2)` copy variants if they are superseded.

---

### [HIGH] H-5: Master Context Missing Authentik/Auth VM from Inventory

**File:** `DOCUMENTS/GENERAL_INFO/COLOSSUS_HOMELAB_MASTER_CONTEXT_v8.md`

**Issue:** The VM/CT inventory in the master context does not include:
- VM-316 (Authentik) — referenced in auth execution task tracker
- CT-316 (Authelia LXC) — referenced in auth execution task tracker line 96
- The Ansible inventory section (line 871-879) does not include the `authentik` or `monitoring` groups

The auth task tracker (line 228) explicitly calls out "Update Master Context to v9" as a pending task.

**Recommendation:** Create Master Context v9 with updated inventory including auth infrastructure.

---

### [MEDIUM] M-1: Master Context v8 Says v0.1.0 Published but v0.3.2 Deployed

**File:** `DOCUMENTS/GENERAL_INFO/COLOSSUS_HOMELAB_MASTER_CONTEXT_v8.md:351`
**Content:** `Container images published to ghcr.io (public): colossus-backend:v0.1.0, colossus-frontend:v0.1.0`

**Issue:** This line in the Phase 4A section describes the initial v0.1.0 publish. While technically accurate for that phase, it could mislead readers about the current state. The header and later sections clarify v0.3.2 is current, but the v0.1.0 reference in the "published to ghcr.io" sentence is confusing.

**Recommendation:** Add a note or update to clarify current deployed version.

---

### [MEDIUM] M-2: Multiple Duplicate/Versioned Scripts in scripts/app-vm-storage/

**Files:**
- `scripts/app-vm-storage/02-install-traefik.sh`
- `scripts/app-vm-storage/02-install-traefik (1).sh`
- `scripts/app-vm-storage/02-install-traefik (2).sh`
- `scripts/app-vm-storage/01-create-traefik-lxc (1).sh`
- `scripts/app-vm-storage/01-create-traefik-lxc.sh`
- `traefik-lxc/02-install-traefik (1).sh`
- `traefik-lxc/02-install-traefik.sh`

**Issue:** Multiple copies of scripts with ` (1)` and ` (2)` suffixes indicate download/copy artifacts rather than intentional versions. This creates confusion about which is authoritative.

**Recommendation:** Identify the canonical version of each script, delete duplicates, and document the canonical script locations in the master context.

---

### [MEDIUM] M-3: Runbooks Do Not Cover Authentik/colossus-rag Components

**Issue:** The DOCUMENTS/RUNBOOKS/ directory contains runbooks for DB VMs, App VMs, Traefik, Pi-hole, Ansible, PBS, etc. No runbook exists for:
- Authentik deployment/recovery
- colossus-rag or Minerva (if deployed)
- Monitoring stack (VM-314) deployment/recovery

The master context also has no mention of `colossus-rag`, `minerva`, or `ANTHROPIC_API_KEY`.

**Recommendation:** Create runbooks for any deployed components not yet covered, starting with Authentik (which is actively being deployed).

---

### [MEDIUM] M-4: References to Old Master Context Versions in Active Documents

**Files:**
- `DOCUMENTS/DESIGN/COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md:724` — References v3
- `DOCUMENTS/DESIGN/APP_DEPLOYMRNT_EDGE_SERVICES_DESIGN.md:6,688` — References v2
- `DOCUMENTS/DESIGN/COLOSSUS_SEMAPHORE_UI_DESIGN_AND_IMPLEMENTATION_v3.md:1238` — References v5
- `DOCUMENTS/RUNBOOKS/NEO4J_DEV_TO_PROD_SYNC_RUNBOOK.md:447-448` — References v5
- `DOCUMENTS/RUNBOOKS/COLOSSUS_ANSIBLE_FOUNDATION_RUNBOOK_v1.md:729` — References v5
- `DOCUMENTS/TASK_TRACKERS/COLOSSUS_PHASE6A_EXECUTION_TASK_TRACKER_v2.md:204` — References v5

**Issue:** Six active documents reference superseded master context versions (v2, v3, v5). Readers following these references will find outdated information.

**Recommendation:** Update cross-references to point to the current master context version (v8, or v9 when created).

---

### [MEDIUM] M-5: Stale VM-200 / colossus-db1-dev References in Active Scripts

**Files:**
- `scripts/app-vm-storage/02-install-pihole.sh:63` — DNS entry `10.10.100.50  colossus-db1-dev.lab`
- `scripts/app-vm-storage/03-create-vm-210.sh:25` — References `colossus-db1-dev2`

**Issue:** VM-200 (`colossus-db1-dev`, IP 10.10.100.50) is described in the master context as a "frozen reference" from Phase 2. If these scripts are re-run, they would create DNS entries pointing to the old VM. The active DEV DB VM is VM-210 at a different IP.

**Recommendation:** Update or annotate scripts that reference VM-200/colossus-db1-dev to clarify they are legacy.

---

### [MEDIUM] M-6: Master Context Does Not List VM-314 (Monitoring) in Inventory

**File:** `DOCUMENTS/GENERAL_INFO/COLOSSUS_HOMELAB_MASTER_CONTEXT_v8.md`

**Issue:** Phase 6A work (monitoring stack) is documented as complete (line 602-615), including VM-314 with Prometheus, Grafana, Loki, Alertmanager. However, scanning the inventory section, VM-314 should be in the Ansible inventory but the infrastructure group (line 878) only lists `pihole, cloudflared, traefik, semaphore` — monitoring is missing.

**Recommendation:** Add VM-314 (monitoring) to the Ansible inventory groups in the master context.

---

### [MEDIUM] M-7: Auth Task Tracker References Authelia Cleanup Not Yet Done

**File:** `DOCUMENTS/TASK_TRACKERS/COLOSSUS_AUTH_EXECUTION_TASK_TRACKER_v2.md`
- Line 96: `Stop Authelia on CT-316` — incomplete
- Line 117: `Destroy CT-316 (Authelia LXC)` — incomplete
- Line 119: `Remove Authelia from Ansible inventory` — incomplete
- Line 126: `Remove Authelia provisioning scripts` — incomplete

**Issue:** Authelia infrastructure (CT-316) cleanup tasks are all still pending. If Authentik is being deployed in parallel, there may be two auth systems running simultaneously, potentially conflicting on Traefik ForwardAuth routes.

**Recommendation:** Complete the Authelia decommission stages or document the coexistence strategy.

---

### [MEDIUM] M-8: Typo in Design Document Filename

**File:** `DOCUMENTS/DESIGN/ APP_DEPLOYMRNT_EDGE_SERVICES_DESIGN.md`

**Issue:** Filename contains a typo ("DEPLOYMRNT" instead of "DEPLOYMENT") and has a leading space before "APP". This makes the file harder to find and reference.

**Recommendation:** Rename to `DOCUMENTS/DESIGN/APP_DEPLOYMENT_EDGE_SERVICES_DESIGN.md` and update any cross-references.

---

### [LOW] L-1: CHANGEME Placeholders in Active Butane Files

**Files:**
- `app-vm-deployment/app-vm/colossus-dev-app1.bu:97` — `NEO4J_PASSWORD=CHANGEME_ANSIBLE_WILL_OVERWRITE`
- `prod-vm-deployment/prod-vm/colossus-prod-app1.bu:93` — `NEO4J_PASSWORD=CHANGEME_ANSIBLE_WILL_OVERWRITE`
- `claude-takeover/colossus-phase3/butane/colossus-prod-db1.bu:26` — Comment: `Replace CHANGEME_NEO4J_PASSWORD`
- `claude-takeover/colossus-phase2/butane/colossus-dev-db1.bu:25` — Comment: `Replace CHANGEME_NEO4J_PASSWORD`

**Issue:** The app VM Butane files correctly use `CHANGEME_ANSIBLE_WILL_OVERWRITE` placeholders, which is the right pattern. However, the DB Butane comments still say "Replace CHANGEME..." while the actual values are hardcoded passwords (see C-1). This is inconsistent.

**Recommendation:** The DB Butane files should use the same `CHANGEME_*` pattern as the app VM files.

---

### [LOW] L-2: No .gitignore for Sensitive File Patterns

**Issue:** No `.gitignore` was found in the repo root that would prevent accidental commits of `.env` files, vault passwords, or other secrets. The hardcoded passwords in C-1 are evidence that secret-prevention controls are missing.

**Recommendation:** Add a `.gitignore` with patterns for `*.env`, `.vault_pass`, `*secret*`, and similar sensitive file patterns.

---

### [LOW] L-3: `Sort/` Directory Contains Unorganized Files

**Files:**
- `Sort/COLOSSUS_HOMELAB_MASTER_CONTEXT.md` (superseded by v8)
- `Sort/PHASE-2_GUARDRAILS md` (note: space in extension, not `.md`)
- `Sort/VM200_EXTERNALIZATION_RUNBOOK_v1.2.md` (duplicate of DOCUMENTS/RUNBOOKS copy)

**Issue:** The `Sort/` directory appears to be a staging area for files that haven't been filed into the `DOCUMENTS/` structure. The master context file here is the original (superseded). The PHASE-2 file has a broken extension.

**Recommendation:** Move useful files to their proper DOCUMENTS/ subdirectory and delete duplicates/superseded files.

---

### [LOW] L-4: Git Working Tree Has Many Deleted Files Pending Commit

**Issue:** `git status` shows ~50 deleted files from `DOCUMENTS/Save/`, `SESSION-NOTES/`, and `SESSION-TRANSFER-NOTES/` directories, plus new untracked directories under `DOCUMENTS/` and `authentik/`. This suggests an in-progress reorganization of the document structure that hasn't been committed.

**Recommendation:** Stage and commit the reorganization to make the repo state match the working tree.

---

### [INFO] I-1: Only One Branch (main) Exists

**Details:** The repo has only `main` with 5 commits. All work appears to be committed directly to main. No feature branches, no PR workflow.

**Observation:** For a single-operator homelab, this is pragmatic. If collaboration increases, consider a branching strategy.

---

### [INFO] I-2: No Large Files Detected

**Details:** No files over 1MB found (excluding `.git/`). Repo is clean in terms of binary bloat.

---

## Section Summary

| Section | Findings | Key Concern |
|---------|----------|-------------|
| 1. Docs vs Deployed State | C-2, M-1 | Master context behind reality on auth work and version references |
| 2. Butane/Ignition Files | C-1, H-1, H-2, H-3, L-1 | Hardcoded passwords, stale versions, `:latest` tags |
| 3. Script Inventory | H-4, M-2, M-5 | Old container names in Traefik scripts, duplicate files |
| 4. Phase Status Accuracy | M-6, M-7 | Monitoring not in inventory, Authelia cleanup pending |
| 5. DR Runbook Completeness | M-3 | No runbooks for Authentik or monitoring |
| 6. Stale References | M-4, M-8, L-3 | Old master context versions cited, typo in filename |
| 7. Git Hygiene | L-2, L-4, I-1, I-2 | No .gitignore for secrets, uncommitted reorg |

---

## Priority Actions

1. **Rotate exposed passwords** and replace hardcoded credentials in Butane files with placeholders (C-1)
2. **Create Master Context v9** incorporating Authentik, VM-316, VM-314 inventory, and current version state (C-2, H-5, M-6)
3. **Delete stale Butane file** `colossus-prod-app1 (1).bu` (H-1)
4. **Pin Qdrant version** in Butane files and master context (H-3)
5. **Update Butane container versions** to v0.3.2 (H-2)
6. **Update Traefik install scripts** with current service names (H-4)
7. **Add `.gitignore`** with secret file patterns (L-2)
8. **Commit the document reorganization** (L-4)
