# Proxmox Cluster & Storage Architecture  
**Version:** v0.3 (Locked Storage & TrueNAS Integration)  
**Date:** 2026-01-31  

---

## Executive Summary

This document is the **authoritative, build-ready architecture specification** for the Proxmox 9 cluster and its supporting TrueNAS storage system.

Version **v0.3** locks in the **final TrueNAS pool topology**, dataset layout, and Proxmox storage mappings. From this point forward, the design is intentionally *boring* and *stable*, enabling confident implementation without revisiting foundational decisions.

---

## 1. Goals & Constraints (Unchanged)

- 3-node Proxmox 9 cluster
- Tiered storage: fast local, shared, backup, offline
- ZFS + NFS + PBS
- Simplicity and reliability over exotic features
- No Ceph, no Kubernetes (Phase 1)

---

## 2. Hardware Inventory & Roles (Confirmed)

### Proxmox Nodes
| Node | Role | Notes |
|----|----|----|
| **pve-1 (PROD-01)** | Primary workloads | NVMe ZFS for hot data |
| **pve-2 (DEV-01)** | Secondary / dev | SSD-backed local storage |
| **pve-3 (MGMT-01)** | Infrastructure | PBS VM, utilities |

### Storage Node
| Node | Role |
|----|----|
| **NAS-01 (TrueNAS)** | Shared storage & backup anchor |

---

## 3. TrueNAS Pool Design (FINAL)

### Pool Name
`Pool-1`

### Disk Topology
- **4 × 3.64 TiB HDD**
- **2 × mirror vdevs (2-wide)**

Layout:
```
Pool-1
├── mirror-0 (sda + sdb)
└── mirror-1 (sdc + sdd)
```

### Rationale
- Fast resilvers
- Excellent IOPS for NFS and PBS
- Tolerates up to two disk failures (if not same mirror)
- Lower risk than RAIDZ1, simpler than RAIDZ2

### Explicit Non-Features (by design)
- No SLOG
- No L2ARC
- No special metadata vdev
- No dedup

This is intentional and correct.

---

## 4. TrueNAS Dataset Layout (FINAL)

```
Pool-1
├── nfs
│   ├── iso
│   ├── templates
│   └── shared-vm
│
├── pbs
│   └── datastore
│
└── offline-staging (optional)
```

### Dataset Properties (apply per dataset)

| Property | Value |
|----|----|
| Compression | lz4 |
| atime | off |
| Recordsize | default |
| Sync | standard |
| Dedup | off |

---

## 5. NFS Export Policy (FINAL)

### Exported Datasets
- `Pool-1/nfs/iso`
- `Pool-1/nfs/templates`
- `Pool-1/nfs/shared-vm`
- `Pool-1/pbs/datastore`

### NFS Settings
- NFSv4.1
- Export restricted to:
  - pve-1
  - pve-2
  - pve-3
- Trusted LAN
- Stable UID/GID mapping or mapall strategy

---

## 6. Proxmox Storage IDs (FINAL)

Register the following storages in Proxmox:

| Storage ID | Backing Dataset | Content Types |
|----|----|----|
| `truenas-iso` | Pool-1/nfs/iso | ISO |
| `truenas-templates` | Pool-1/nfs/templates | VZDump, CT templates, snippets |
| `truenas-shared` | Pool-1/nfs/shared-vm | VM disks (non-critical) |
| `pbs-datastore` | Pool-1/pbs/datastore | PBS datastore |

Naming is intentional — do not abbreviate.

---

## 7. Backup Architecture (LOCKED)

### Proxmox Backup Server
- Runs as a **VM on pve-3**
- Small footprint (2 vCPU / 4–8 GB RAM)
- OS disk local to pve-3
- Datastore on `Pool-1/pbs/datastore`

### Retention Policy
- Daily × 7
- Weekly × 4
- Monthly × 3–6

### Jobs
- Backup: nightly
- Prune: weekly
- Verify: weekly

---

## 8. Offline Backup (Air-Gapped)

### Hardware
- External desktop HDD (14–18 TB)
- Attached to TrueNAS only when used

### Pool
- Separate ZFS pool (e.g. `offline-01`)

### Method
- ZFS replication:
  - Source: `Pool-1/pbs/datastore`
  - Destination: `offline-01/pbs/datastore`

### Operational Rule
> Drive is **physically disconnected** when not replicating.

Monthly cadence + before risky changes.

---

## 9. Container Strategy (CONFIRMED)

- Databases run as **Proxmox LXC containers**
- Each DB has:
  - One container
  - One mounted ZFS dataset (local to node)
- No databases on NFS

Immediate task:
- Decommission CoreOS VM
- Replace with native LXCs

---

## 10. Operational Placement Rules (LOCKED)

- **Tier A (local ZFS):** DBs, high IO workloads
- **Tier B (NFS):** templates, general VMs, shared data
- **Tier C (PBS):** everything backed up
- **Tier D (offline):** last-resort recovery

---

## 11. Deferred Enhancements (Documented, Not Built)

- Proxmox SDN private networks
- Zero-trust ingress (Cloudflare Tunnel)
- Authentik SSO
- CrowdSec / WAF
- Network upgrades (2.5 / 10 GbE)

---

## 12. Status & Next Steps

**v0.3 is locked and buildable.**

Next recommended actions:
1. Create datasets exactly as specified
2. Export NFS shares
3. Register Proxmox storages
4. Deploy PBS VM
5. Begin workload migration

No further architectural decisions are required to proceed.

---

*End of document*
