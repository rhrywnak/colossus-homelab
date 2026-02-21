# Colossus Homelab Proxmox Cluster & Storage Architecture
**Version:** v1.2  
**Date:** 2026-02-05  

> **Fix notice:** v1.1 was accidentally published as a truncated append-only fragment (Sections 11–18 only).  
> This v1.2 restores the complete baseline from v1.0 **and** includes the v1.1 additions.

---

## 0. Executive Summary

You now have a healthy 3-node Proxmox VE 9.1.5 cluster (**`colossus`**) with strict node roles:

- **pve-1 (PROD)**: production apps + production databases on fast local NVMe
- **pve-2 (DEV)**: development apps + dev databases (currently VM 200 runs CoreOS with Neo4j/Postgres/Qdrant)
- **pve-3 (MGMT)**: cluster services (DNS, Authentik, reverse proxy, monitoring/logging) + **Proxmox Backup Server** (PBS)

Shared storage is provided by:
- **TrueNAS (TerraMaster F4-423)** with **4×2TB in RAID10** (two mirrors) exporting **NFS** for templates, ISO library, and “offline copy” of backups.

This document defines:
1) A consistent storage layout per node  
2) Where VM ISOs live and how they are shared  
3) Where application data lives and how it is mounted into VMs/containers  
4) A reproducible way to create VMs/containers and attach storage  
5) A runbook to transition **VM 200** to external persistence (outside containers and optionally outside the VM)  
6) A controlled migration path from **Dev Neo4j → Prod Neo4j**  
7) A layered backup architecture: **PBS primary** + **TrueNAS secondary/offline**  

---

## 1. Node Inventory (Authoritative)

### 1.1 pve-1 — PROD node (Minisforum MS-02 Ultra)
- **CPU:** Intel 285HX
- **RAM:** 64GB (initial)
- **Storage:**
  - NVMe #1 (OS): **Crucial P510 1TB** (replaced T500 due to heatsink clearance)
  - NVMe #2 (DATA): **Crucial T500 2TB** (for VM disks + prod DB/app data)
- **Role:** Prod apps + Prod DB VM(s); performance-sensitive workloads.

### 1.2 pve-2 — DEV node (BeeLink SER5)
- **CPU:** Ryzen 7 5700U
- **Storage:**
  - NVMe: **Crucial P3 1TB (CT1000P3SSD8)** (Proxmox OS + local-lvm)
  - SATA SSD: **Crucial MX500 2TB (CT2000MX500SSD1)** (available for dev VM disks / data)
- **Role:** Development workloads; contains **VM 200** (`colossus-db1-dev`) running CoreOS + Neo4j/Postgres/Qdrant.

### 1.3 pve-3 — MGMT node (Dell Precision 7810)
- **Storage:**
  - OS disk: **Samsung 860 EVO 1TB** (Proxmox OS + local-lvm)
  - Data disk: **Crucial MX500 2TB (CT2000MX500SSD1)** (cleaned from old Ceph; available)
- **Role:** Cluster-wide services and **PBS** (recommended as VM). “Boring and stable.”

---

## 2. Storage Strategy (Principles)

### 2.1 Separation goals
We enforce three tiers:

1) **Fast local NVMe (Prod/Dev data):**  
   - DBs and latency-sensitive app state stays local to the node that runs it (simple, fast, reliable).

2) **Shared NFS from TrueNAS (library + cold storage):**  
   - ISO library  
   - VM templates  
   - Shared “general VMs” only if desired  
   - Offline/secondary backup copies (pull from PBS)

3) **Backups (PBS primary + TrueNAS secondary/offline):**  
   - PBS as the primary backup target  
   - TrueNAS stores offline copies (and can replicate to an external USB disk later)

### 2.2 Why not Ceph here
Ceph across 3 heterogeneous nodes increases complexity and the “blast radius.”
For your priorities (simplicity + reliability), **PBS + NFS** wins.

---

## 3. Storage Layout (Concrete) by Node

### 3.1 Proxmox default storages (common)
Each node has:
- `local` (Directory): `/var/lib/vz` (ISOs, templates if desired, backups if enabled)
- `local-lvm` (LVM-thin): VM disks by default

We will standardize:
- `local-lvm` used for OS and light VMs only
- “DATA disk” used for heavy VM disks / DB volumes

### 3.2 pve-1 storage (PROD)
**Recommended:**
- OS NVMe (1TB P510): `local` + `local-lvm` (default)
- Data NVMe (2TB T500): dedicated storage for PROD VM disks and prod data

**Implementation option (recommended): ZFS on data NVMe**
- Create ZFS pool: `prod-zfs` on the 2TB T500
- Create datasets:
  - `prod-zfs/db-neo4j`
  - `prod-zfs/db-postgres`
  - `prod-zfs/db-qdrant`
  - `prod-zfs/app-data`
- Defaults:
  - `compression=zstd`, `atime=off`

**Where prod data lives:**
- All prod DB directories live under these datasets (mounted into VMs/containers).

### 3.3 pve-2 storage (DEV)
- OS NVMe (1TB): `local` + `local-lvm`
- Data SSD (2TB MX500): dev VM disks / dev DB persistence

**Implementation option (recommended): ZFS on 2TB**
- Pool: `dev-zfs` on the 2TB MX500
- Datasets:
  - `dev-zfs/db-neo4j`
  - `dev-zfs/db-postgres`
  - `dev-zfs/db-qdrant`
  - `dev-zfs/app-data`

**Where dev data lives:**
- Ultimately outside containers (and preferably outside the VM OS disk). See Section 6.

### 3.4 pve-3 storage (MGMT + PBS)
- OS SSD (860 EVO 1TB): `local` + `local-lvm`
- Data SSD (MX500 2TB): ZFS pool for:
  - PBS datastore
  - mgmt service persistence (auth/proxy/monitoring/logs)

**Recommended ZFS pool on /dev/sdb**
- Pool name: `mgmt-zfs`
- Datasets:
  - `mgmt-zfs/pbs-datastore`
  - `mgmt-zfs/services/authentik`
  - `mgmt-zfs/services/proxy`
  - `mgmt-zfs/services/dns`
  - `mgmt-zfs/services/monitoring`
  - `mgmt-zfs/services/logs`

---

## 4. TrueNAS Storage (Shared)

### 4.1 Current TrueNAS configuration (given)
- TrueNAS Community Edition 25.04.2.6
- 4×3.64 TiB disks in **2× mirror vdevs** (RAID10 equivalent)
- Export: NFS

### 4.2 NFS exports (recommended)
Create these datasets/shares:

1) `tank/nfs/iso`  
   - Proxmox ISO library

2) `tank/nfs/templates`  
   - VM templates, container templates, cloud images

3) `tank/nfs/offline-backups`  
   - “offline” copy destination (PBS sync target / pull target)

### 4.3 Where ISOs should live
**Recommended:**
- Keep ISOs on **TrueNAS NFS** so every node sees the same library.
- Optionally keep a minimal ISO set on each node’s `local` for emergency recovery.

---

## 5. App Data: Definition, Location, and Mounting (Core Pattern)

### 5.1 What “app data” means
Any state that must survive:
- container restarts
- VM reboots
- host reboots
- upgrades and rollbacks

Includes:
- DB files (Postgres data dir, Neo4j data, Qdrant storage)
- uploaded files
- certs (proxy)
- Authentik state
- monitoring state

### 5.2 Golden rule
**App data must never live inside container layers** (images).  
It must be a **mounted volume** backed by Proxmox storage.

### 5.3 Mount patterns (choose per layer)

#### Pattern A — Containers directly on Proxmox (LXC)
- Best for: mgmt services (Pi-hole, reverse proxy, small apps)
- Storage: bind-mount ZFS dataset path into LXC
- Pros: efficient, simple, PBS-friendly
- Cons: some apps prefer full VM isolation

#### Pattern B — Containers inside a service VM (your current approach)
- Best for: grouped services (dev DB stack), CoreOS-based patterns
- Storage: mount host-provided filesystem into the VM, then map into containers

Recommended VM mount technology:
- **virtiofs** (preferred)
- NFS inside the VM (works, adds dependency)

---

## 6. Transition Plan: VM 200 (Dev DB VM) to External Persistence

### 6.1 Current situation
- VM 200 is a CoreOS VM on pve-2 running Neo4j/Postgres/Qdrant.
- Goal: get DB data out of container layers (and ideally out of the VM OS disk).

### 6.2 Target state (Dev)
- DB data lives on **pve-2 dev storage** (`dev-zfs/*` datasets)
- VM 200 mounts these datasets into the VM
- Containers mount those paths as volumes

### 6.3 Step-by-step (high-level)
1) Create dev data storage on pve-2:
   - `dev-zfs/db-neo4j`
   - `dev-zfs/db-postgres`
   - `dev-zfs/db-qdrant`

2) Mount into VM 200 (virtiofs recommended)
   - Guest mount: `/mnt/data/postgres`, `/mnt/data/neo4j`, `/mnt/data/qdrant`

3) Update container definitions
   - Postgres: `/var/lib/postgresql/data` → `/mnt/data/postgres`
   - Neo4j: `/data` → `/mnt/data/neo4j/data`; `/logs` → `/mnt/data/neo4j/logs`
   - Qdrant: `/qdrant/storage` → `/mnt/data/qdrant`

4) Controlled migration per service
   - Stop service
   - Copy data to new mount (rsync preserving ownership)
   - Start service
   - Validate

### 6.4 Runtime parameters (reproducibility)
Standardize env/secrets:
- Postgres: `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
- Neo4j: `NEO4J_AUTH=neo4j/<password>`
- Qdrant: enable API keys later if desired

Store in `.env` outside containers (mounted/injected). Later phase: secrets manager.

---

## 7. Reproducible VM/Container Creation (Infrastructure-as-Code)

### 7.1 Principle
Everything should be repeatable from a Git repo: scripts + templates + runbooks.

### 7.2 VM creation (recommended)
Use Proxmox CLI with templates:
- `qm create`, `qm set`, `qm clone`
- Cloud-init templates for Ubuntu/Debian service VMs

### 7.3 LXC creation
Use `pct create` with bind mounts into ZFS datasets.

### 7.4 Suggested repo structure
```
colossus-infra/
  proxmox/
    scripts/
      qm-create-prod-db.sh
      qm-create-prod-app.sh
      qm-create-dev-db.sh
      pct-create-auth.sh
      pct-create-dns.sh
    templates/
      cloud-init/
  services/
    dev-db/
      compose.yml
      env.example
      runbooks/
    prod-db/
      compose.yml
      env.example
      runbooks/
  backups/
    pbs/
      jobs.md
      retention.md
```

---

## 8. Migration: Dev Neo4j → Prod Neo4j

### 8.1 Target state
- Prod Neo4j runs on pve-1 with persistence on `prod-zfs/db-neo4j`

### 8.2 Recommended migration
Neo4j `dump`/`load`:
1) Freeze dev writes
2) `neo4j-admin dump`
3) Transfer dump
4) `neo4j-admin load --force` on prod
5) Validate

---

## 9. Backup Architecture (PBS primary + TrueNAS secondary)

### 9.1 Primary: PBS on pve-3
- PBS runs as VM (suggest VMID 900)
- Datastore: `mgmt-zfs/pbs-datastore`
- First backup target: VM 200

Retention starter:
- daily 14, weekly 8, monthly 12

### 9.2 Secondary/offline: TrueNAS NFS
PBS sync (or scheduled rsync) from PBS datastore to:
- `tank/nfs/offline-backups/pbs-sync`

---

## 10. Immediate Next Steps
1) Create `mgmt-zfs` on pve-3 and datasets
2) Create PBS VM (ISO 4.1), attach datastore
3) Configure backup job for VM 200
4) Create `dev-zfs` on pve-2 and externalize VM 200 DB data
5) Build prod DB VM on pve-1 and migrate Neo4j

---

*End of v1.0 draft*

---

## 11. CoreOS as the Standard Service VM Host

### Was CoreOS the correct choice?
Yes. For your goals—immutability, reproducibility, container-first workflows, and long-lived stability—**Fedora CoreOS is the right choice**.

You are intentionally optimizing for:
- predictable VM behavior
- declarative configuration
- minimal configuration drift
- container-native workloads

Those map directly to CoreOS’s strengths.

Trade-offs you are consciously accepting:
- less interactive “SSH tweaking”
- stronger discipline around externalized data
- systemd-based container management instead of ad-hoc shells

Given your background and architecture, this is a **professional-grade decision**, not a hobbyist one.

---

## 12. CoreOS Golden Template Strategy

### Single golden image
You maintain **one CoreOS VM template** and clone it for:
- dev DB VMs
- prod DB VMs
- app service VMs

Role differences are expressed via:
- attached storage
- Ignition config
- systemd unit definitions

---

## 13. Creating the CoreOS Template (Proxmox)

### Initial creation (one-time)

```bash
qm create 9000   --name coreos-template   --memory 8192   --cores 4   --net0 virtio,bridge=vmbr0   --bios ovmf   --machine q35   --scsi0 local-lvm:32   --scsihw virtio-scsi-single   --boot order=scsi0
```

Install Fedora CoreOS from ISO.

### Convert to template

```bash
qm template 9000
```

---

## 14. CoreOS Container Model

Containers are **systemd-managed Podman services**, not ad-hoc shells.

### Standard layout inside the VM

```
/mnt/data/
  postgres/data
  neo4j/data
  neo4j/logs
  qdrant/storage

/etc/containers/env/
  postgres.env
  neo4j.env
  qdrant.env
```

---

## 15. CoreOS Container Unit Templates

### Postgres

```ini
[Unit]
Description=Postgres
After=network-online.target

[Service]
EnvironmentFile=/etc/containers/env/postgres.env
ExecStart=/usr/bin/podman run \
  --rm \
  --name postgres \
  -p 5432:5432 \
  -v /mnt/data/postgres/data:/var/lib/postgresql/data \
  postgres:16
Restart=always

[Install]
WantedBy=multi-user.target
```

### Neo4j

```ini
[Unit]
Description=Neo4j
After=network-online.target

[Service]
EnvironmentFile=/etc/containers/env/neo4j.env
ExecStart=/usr/bin/podman run \
  --rm \
  --name neo4j \
  -p 7474:7474 -p 7687:7687 \
  -v /mnt/data/neo4j/data:/data \
  -v /mnt/data/neo4j/logs:/logs \
  neo4j:5
Restart=always

[Install]
WantedBy=multi-user.target
```

---

## 16. Reproducible VM Creation Flow

1) Clone template:
```bash
qm clone 9000 210 --name dev-db-coreos
```

2) Attach persistent storage (virtiofs preferred):
```bash
qm set 210 --virtiofs0 /dev-zfs/db-neo4j,mountpoint=/mnt/data/neo4j
```

3) Apply Ignition
4) Boot VM
5) Containers auto-start

---

## 17. Backup Implications

- PBS backs up VM disk + attached datasets
- Container images are disposable
- Data lives in Proxmox-managed storage
- Restore = restore VM + data → services restart

---

## 18. Status

You now have:
- a consistent CoreOS VM model
- deterministic container startup
- externalized persistent data
- clean backup semantics

Next document:
**v1.2 – VM 200 Externalization Runbook (step-by-step)**


---

## Appendix C — As-built notes (Feb 2026)

These notes capture what is **actually deployed** right now, to avoid confusion when reading older design text.

### C.1 pve-3 MGMT storage naming
Early drafts used the pool name `mgmt-zfs`. The as-built implementation uses:

- ZFS pool: `pbs-zfs`
- Datasets:
  - `pbs-zfs/datastore` (quota set to ~1.2T for PBS datastore disk allocation boundary)
  - `pbs-zfs/services` (intended for pve-3 hosted services)

In Proxmox storage (`pvesm`), the ZFS pool is registered as:
- Storage ID: `pbs-zfs`
- Type: `zfspool`

### C.2 PBS deployment pattern (as-built)
- PBS runs as a dedicated VM (VMID 900) on `pve-3`
- PBS datastore inside the VM is mounted at:
  - `/mnt/pbs-datastore` on a dedicated data disk (`/dev/sdb`, ~1.2T)

This matches the design intent (“PBS VM is disposable; datastore is the durable asset”) even if the pool name differs.

