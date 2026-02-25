# Colossus — CoreOS Database VM Creation Runbook

**Version:** v1.0  
**Date:** 2026-02-08  
**Scope:** Creating a Fedora CoreOS VM on Proxmox for containerized database hosting  
**Validated on:** pve-2 (DEV), VM-210

---

## 0. Purpose

This runbook documents the complete, tested procedure for creating a Colossus database VM from scratch. It was validated during Phase 2 (DEV) and is the reference procedure for Phase 3 (PROD).

**The VM is fully disposable.** All persistent data lives on host ZFS datasets. Destroying and recreating the VM from this procedure restores full functionality after data restore.

---

## 1. Prerequisites

### 1.1 Host Requirements

| Requirement | Detail |
|-------------|--------|
| Proxmox VE | 9.1.5+ |
| Fedora CoreOS QCOW2 | Downloaded to `/var/coreos/images/` |
| ZFS pool + datasets | Created and tuned on the target node |
| Proxmox directory mappings | Created for each database dataset |
| Butane CLI | Available on operator workstation (via container) |

### 1.2 Fedora CoreOS Image

The image only needs to be downloaded once per node. Current validated image:

```
/var/coreos/images/fedora-coreos-42.20250929.3.0-proxmoxve.x86_64.qcow2
```

To download a new one:

```bash
STREAM="stable"
podman run --pull=always --rm -v "/var/coreos/images:/data" -w /data \
    quay.io/coreos/coreos-installer:release download \
    -s $STREAM -p proxmoxve -f qcow2.xz --decompress
```

### 1.3 Proxmox Storage for Snippets

A Proxmox storage entry must exist to serve Ignition files as cloud-init vendor snippets:

```bash
# One-time setup (if not already done)
mkdir -p /var/coreos/{images,snippets}
pvesm add dir coreos --path /var/coreos --content images,snippets
```

---

## 2. ZFS Dataset Preparation

### 2.1 Create ZFS Pool (one-time per node)

Identify the target device (`lsblk`), then:

```bash
zpool create \
  -o ashift=12 \
  -O compression=zstd \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  <pool-name> \
  /dev/<device>
```

**DEV (pve-2):** Pool name `dev-zfs` on Crucial MX500 2TB  
**PROD (pve-1):** Pool name `prod-zfs` on target NVMe

### 2.2 Create Datasets

```bash
POOL=dev-zfs  # or prod-zfs

zfs create ${POOL}/postgres
zfs create ${POOL}/neo4j
zfs create ${POOL}/qdrant
```

### 2.3 Apply Recordsize Tuning

```bash
zfs set recordsize=16K  ${POOL}/postgres   # Matches PG 8K page size
zfs set recordsize=1M   ${POOL}/neo4j      # Large sequential I/O
zfs set recordsize=128K ${POOL}/qdrant     # Mixed workload
```

### 2.4 Verify

```bash
zfs list ${POOL}
zfs get compression,atime,recordsize ${POOL}/postgres ${POOL}/neo4j ${POOL}/qdrant
```

Script: `01-verify-dev-zfs.sh` automates this verification.

---

## 3. Proxmox Directory Mappings

Directory mappings are cluster-level resources that wire host filesystem paths to virtiofs tag names. They must be created before the VM.

### 3.1 Create Mappings

```bash
NODE=pve-2  # or pve-1 for PROD
BASE_MP=/<pool-mountpoint>  # e.g., /dev-zfs

pvesh create /cluster/mapping/dir \
    --id db-postgres \
    --map "node=${NODE},path=${BASE_MP}/postgres"

pvesh create /cluster/mapping/dir \
    --id db-neo4j \
    --map "node=${NODE},path=${BASE_MP}/neo4j"

pvesh create /cluster/mapping/dir \
    --id db-qdrant \
    --map "node=${NODE},path=${BASE_MP}/qdrant"
```

### 3.2 Verify

```bash
pvesh get /cluster/mapping/dir/db-postgres
pvesh get /cluster/mapping/dir/db-neo4j
pvesh get /cluster/mapping/dir/db-qdrant
```

Script: `02-setup-directory-mappings.sh` automates this.

**Note for PROD:** If the same mapping IDs are reused across nodes, the mapping must include both nodes in the `--map` parameter. Alternatively, use PROD-specific IDs (e.g., `prod-db-postgres`).

---

## 4. Butane Configuration

### 4.1 Structure

The Butane config (`colossus-dev-db1.bu`) declares everything the VM needs:

```
Butane config
├── Hostname (/etc/hostname)
├── virtiofs mount units (3x systemd .mount files)
│   └── Each with SELinux context= option
├── Quadlet container definitions (3x .container files)
│   └── Each with Requires/After on its mount unit
├── Environment files (2x .env files for credentials)
├── Directory structure (/var/mnt/data/*, /etc/colossus/env/)
├── SSH authorized key
└── systemd unit enablement (mount units only)
```

### 4.2 Critical Configuration Notes

**SELinux context on mount units (MANDATORY):**

```ini
[Mount]
What=db-postgres
Where=/var/mnt/data/postgres
Type=virtiofs
Options=context="system_u:object_r:container_file_t:s0"
```

Without this, containers cannot access virtiofs mounts. See Phase 2 Completion Report §4.1 for full explanation.

**Path canonicalization (MANDATORY):**

CoreOS's `/mnt` is a symlink to `/var/mnt`. systemd mount units MUST use canonical paths:

| Context | Use this path |
|---------|--------------|
| systemd mount unit `Where=` | `/var/mnt/data/postgres` |
| systemd mount unit filename | `var-mnt-data-postgres.mount` |
| Container volume mount | `/mnt/data/postgres` (symlink is fine) |
| SSH commands | `/mnt/data/postgres` (symlink is fine) |

**Quadlet container files:**

Placed in `/etc/containers/systemd/`. The systemd generator creates `.service` units automatically. Do NOT list these in the Butane `systemd.units` section with `enabled: true` — the service files don't exist at Ignition time.

### 4.3 Customization for Different Environments

When adapting for PROD or additional VMs, change:

| Parameter | DEV value | Change for PROD |
|-----------|-----------|----------------|
| Hostname | `colossus-dev-db1` | `colossus-prod-db1` |
| virtiofs `What=` tags | `db-postgres` etc. | Match PROD mapping IDs |
| Postgres password | (set in env file) | PROD password |
| Neo4j password | (set in env file) | PROD password |

### 4.4 Transpile

```bash
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < colossus-dev-db1.bu > colossus-dev-db1.ign
```

**`--strict` is important** — it will reject configs with warnings that would otherwise produce broken Ignition.

### 4.5 Deploy Ignition to Host

```bash
scp colossus-dev-db1.ign root@pve-2:/var/coreos/snippets/
```

---

## 5. VM Creation

### 5.1 Configuration Parameters

| Parameter | DEV value | Notes |
|-----------|-----------|-------|
| VMID | 210 | Must not already exist |
| Name | `colossus-dev-db1` | |
| Machine type | **q35** | **Required for virtiofs** |
| CPU | 4 cores | |
| Memory | 16384 MiB | |
| Disk | local-lvm + 40G | |
| Network | virtio, bridge=vmbr0 | DHCP |
| SCSI | virtio-scsi-pci | |

### 5.2 Creation Commands

```bash
VMID=210
NAME=colossus-dev-db1
STORAGE=local-lvm
QCOW=/var/coreos/images/fedora-coreos-42.20250929.3.0-proxmoxve.x86_64.qcow2

# Create VM (q35 is mandatory for virtiofs)
qm create $VMID \
    --name $NAME \
    --machine q35 \
    --cores 4 \
    --memory 16384 \
    --net0 "virtio,bridge=vmbr0" \
    --scsihw virtio-scsi-pci

# Import CoreOS disk
qm set $VMID --scsi0 "${STORAGE}:0,import-from=${QCOW}"

# Grow disk
qm resize $VMID scsi0 +40G

# Cloud-init drive (Ignition delivery)
qm set $VMID --ide2 "${STORAGE}:cloudinit"

# Boot order
qm set $VMID --boot order=scsi0

# Serial console
qm set $VMID --serial0 socket --vga serial0

# Ignition via cloud-init vendor snippet
qm set $VMID --cicustom "vendor=coreos:snippets/colossus-dev-db1.ign"
qm set $VMID --ciupgrade 0

# Attach virtiofs shares
qm set $VMID -virtiofs0 "dirid=db-postgres,cache=always"
qm set $VMID -virtiofs1 "dirid=db-neo4j,cache=always"
qm set $VMID -virtiofs2 "dirid=db-qdrant,cache=always"
```

Script: `03-create-vm-210.sh` automates this with pre-flight checks.

### 5.3 Start VM

```bash
qm start $VMID
```

### 5.4 Access

```bash
# Serial console (useful before DHCP IP is known)
qm terminal $VMID

# SSH (once DHCP IP is discovered)
ssh core@<ip>
```

---

## 6. Post-Boot Verification

### 6.1 virtiofs Mounts

```bash
mount | grep virtiofs
```

Expected output (3 mounts with `context=` SELinux labels):
```
db-postgres on /var/mnt/data/postgres type virtiofs (rw,relatime,context="system_u:object_r:container_file_t:s0")
db-neo4j on /var/mnt/data/neo4j type virtiofs (rw,relatime,context="system_u:object_r:container_file_t:s0")
db-qdrant on /var/mnt/data/qdrant type virtiofs (rw,relatime,context="system_u:object_r:container_file_t:s0")
```

### 6.2 SELinux Context

```bash
ls -dZ /var/mnt/data/postgres /var/mnt/data/neo4j /var/mnt/data/qdrant
```

Must show `container_file_t`, NOT `virtiofs_t`.

### 6.3 Container Services

```bash
sudo systemctl status colossus-postgres colossus-neo4j colossus-qdrant
sudo podman ps
```

All three should be running. On first boot with empty data directories, PostgreSQL will initialize its database, Neo4j will create an empty store, and Qdrant will start with no collections.

### 6.4 Port Connectivity

From the workstation:

```bash
curl -s http://<vm-ip>:7474    # Neo4j browser
curl -s http://<vm-ip>:6333    # Qdrant API
psql -h <vm-ip> -U postgres -c "SELECT 1;"  # PostgreSQL
```

---

## 7. Data Restore

Data restore is performed from the operator workstation using the Phase 2 restore scripts.

### 7.1 Set UID Ownership (Before Restore)

The restore scripts handle this, but if restoring manually:

```bash
ssh core@<vm-ip> 'sudo chown -R 999:999 /mnt/data/postgres'
ssh core@<vm-ip> 'sudo chown -R 7474:7474 /mnt/data/neo4j'
ssh core@<vm-ip> 'sudo chown -R 1000:1000 /mnt/data/qdrant'
```

### 7.2 Restore Order

1. **Neo4j** (requires service stop, one-shot restore container)
2. **PostgreSQL** (runs against live container via `podman exec`)
3. **Qdrant** (HTTP API upload, no service disruption)

See the Backup/Restore Runbook for detailed procedures.

### 7.3 Validate

```bash
NEO4J_PASS=<password> bash ~/colossus-phase2/scripts/07-validate-parity.sh <old-vm-ip> <new-vm-ip>
```

---

## 8. Destroy and Rebuild

If the VM needs to be rebuilt:

```bash
# On pve-2
qm stop 210
qm destroy 210

# ZFS data is untouched — it lives on the host
# Re-run the creation procedure from Section 5
# Then restore data from backups (Section 7)
```

Total rebuild time (excluding data restore): under 5 minutes.

---

## 9. Known Gotchas

| Issue | Impact | Solution |
|-------|--------|----------|
| Missing `--machine q35` | virtiofs not available to guest | Always specify `--machine q35` in VM creation |
| Missing SELinux `context=` on mount units | Containers get permission denied on all virtiofs volumes | Add `Options=context="system_u:object_r:container_file_t:s0"` to every mount unit |
| Using `/mnt/data/` in systemd mount unit names | Mount unit fails silently (wrong escaped path) | Always use `/var/mnt/data/` in mount unit `Where=` and filenames |
| `:z`/`:Z` on virtiofs volumes | SELinux relabeling fails (no xattr support) | Use mount-level `context=` instead; use `--security-opt label=disable` for one-shot containers |
| Enabling Quadlet services in Butane `systemd.units` | Ignition fails (service files don't exist yet) | Let the Quadlet generator handle enablement via `[Install] WantedBy=` |
| Neo4j restore with virtiofs | `:Z` flag in restore container fails | Use `--security-opt label=disable` on the one-shot restore container |

---

## 10. Adapting for Production (Phase 3)

To create the PROD equivalent on pve-1:

1. **ZFS:** Create `prod-zfs` pool and datasets with identical tuning
2. **Directory mappings:** Create on pve-1 (may need PROD-specific IDs if DEV mappings are node-pinned)
3. **Butane config:** Copy DEV config, change hostname, VMID, credentials
4. **Transpile and deploy** Ignition to pve-1
5. **Create VM** using the same `qm` commands (different VMID, same structure)
6. **Restore data** from DEV-validated backups
7. **Validate**

The procedure is mechanical. No new design decisions are required.

---

*End of CoreOS VM Creation Runbook v1.0*
