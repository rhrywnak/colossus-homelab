# Colossus Proxmox Cluster – Transition & Execution Plan
**Version:** v1.0
**Purpose:** Session hand-off document to safely transition from *design* to *execution*.

This document is intentionally operational. It defines **where we are**, **what is frozen**, and **the exact execution order** for the next sessions so work can resume without re-analysis or re-design.

---

## 1. Current Authoritative State (Baseline)

### 1.1 Cluster
- **Cluster name:** `colossus`
- **Proxmox version:** 9.1.5 on all nodes
- **Quorum:** Healthy (3/3)

### 1.2 Node Roles (LOCKED)

| Node | Role | Notes |
|---|---|---|
| **pve-1** | PROD | Hosts production apps + production DB VM(s) on local NVMe |
| **pve-2** | DEV | Hosts dev workloads; VM 200 runs CoreOS + Neo4j/Postgres/Qdrant |
| **pve-3** | MGMT | Cluster-wide services + Proxmox Backup Server |

No hostname changes, role swaps, or rebalancing will occur going forward.

### 1.3 Critical VM
- **VMID:** 200
- **Name:** `colossus-db1-dev`
- **Node:** pve-2
- **OS:** Fedora CoreOS
- **Services:** Neo4j, PostgreSQL, Qdrant (containers)
- **State:** Running, validated, snapshot taken

### 1.4 Existing Design Artifacts (SOURCE OF TRUTH)
These documents are already committed to the project folder and must be treated as authoritative:

1. **`COLOSSUS_PROXMOX_CLUSTER_DESIGN_v1.1.md`**
   - Defines cluster architecture, storage layout, CoreOS strategy

2. **`VM200_EXTERNALIZATION_RUNBOOK_v1.2.md`**
   - Defines the exact procedure to externalize DB persistence for VM 200

No architectural decisions should be revisited unless explicitly revised in a newer version.

---

## 2. What Is Frozen (Do Not Change)

The following are **explicitly frozen** and must not be altered during execution:

- Cluster membership and node order
- VMID 200
- Use of Fedora CoreOS as service VM OS
- Use of Podman + systemd units inside CoreOS
- ZFS-based persistence model per node
- TrueNAS as secondary/offline storage

Any change here requires a **new design revision**, not ad-hoc execution.

---

## 3. Execution Phases (Strict Order)

Execution is intentionally broken into **small, reversible phases**.

### Phase 1 — Backup Foundation (NEXT SESSION STARTS HERE)

**Objective:** Ensure we have a real, restorable backup before touching data layouts.

Tasks:
1. Create **Proxmox Backup Server (PBS) VM** on **pve-3**
   - PBS version: 4.1
   - VMID: 900 (reserved)
   - Datastore: `mgmt-zfs/pbs-datastore`

2. Configure PBS
   - Datastore validation
   - Retention policy (daily/weekly/monthly)

3. Perform first backup
   - Backup **VM 200** from Proxmox → PBS
   - Verify backup metadata

**Exit criteria:**
- VM 200 exists as a successful backup in PBS
- Restore options are visible in PBS UI

---

### Phase 2 — Externalize Dev DB Persistence (VM 200)

**Objective:** Remove DB data from container layers and VM OS disk.

Execution document:
- **`VM200_EXTERNALIZATION_RUNBOOK_v1.2.md`** (follow verbatim)

Key rules:
- One service at a time (Postgres → Neo4j → Qdrant)
- No deletion of old data until:
  - service verified
  - PBS backup completed post-cutover

**Exit criteria:**
- All DB data lives on pve-2 ZFS datasets
- VM 200 boots cleanly
- Containers auto-start and serve data

---

### Phase 3 — Post-Externalization Safety Net

Tasks:
1. Take a new VM snapshot: `post-externalize-dev-db`
2. Run a second PBS backup of VM 200
3. Verify ZFS dataset usage reflects expected DB sizes

**Exit criteria:**
- Two independent recovery paths exist (snapshot + PBS)

---

### Phase 4 — Build Production DB VM (pve-1)

**Objective:** Prepare production database environment without touching prod data yet.

Tasks:
1. Create CoreOS-based **Prod DB VM** on pve-1
2. Create `prod-zfs` datasets for Neo4j/Postgres/Qdrant
3. Attach datasets via virtiofs
4. Deploy containers using the same templates as dev

**Exit criteria:**
- Prod DB VM running
- Empty but healthy DB services available

---

### Phase 5 — Dev → Prod Neo4j Migration

**Objective:** Controlled promotion of data.

Method (LOCKED):
- `neo4j-admin dump` (dev)
- Secure transfer
- `neo4j-admin load --force` (prod)

**Exit criteria:**
- Prod Neo4j matches dev dataset
- Dev remains intact for rollback

---

### Phase 6 — Management Services (Later)

Out of scope for immediate execution, but planned:
- Internal DNS + split-horizon
- Authentik
- Reverse proxy / SSO
- Monitoring + logging

---

## 4. Session Restart Instructions

When starting a **new ChatGPT session**, paste the following:

> We are continuing the Colossus Proxmox build.
>
> Baseline documents:
> - COLOSSUS_PROXMOX_CLUSTER_DESIGN_v1.1.md
> - VM200_EXTERNALIZATION_RUNBOOK_v1.2.md
> - COLOSSUS_TRANSITION_EXECUTION_PLAN_v1.0.md
>
> Current state:
> - Cluster healthy
> - VM 200 running on pve-2
> - Ready to begin Phase 1 (PBS deployment)

This avoids re-discovery and ensures continuity.

---

## 5. Operator Guidance (Non-Technical but Critical)

- Do not rush Phase 2 (data externalization)
- Take breaks between services
- Verify after every step
- If something feels wrong: **stop** and re-check against the documents

This plan is intentionally conservative. That is a feature, not a flaw.

---

*End of Transition & Execution Plan v1.0*

