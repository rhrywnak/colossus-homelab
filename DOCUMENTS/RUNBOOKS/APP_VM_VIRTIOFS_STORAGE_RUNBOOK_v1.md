# Colossus — Adding virtiofs Storage to Application VMs

**Version:** v1.0  
**Date:** 2026-02-22  
**Scope:** Externalize document storage from local VM paths to ZFS-backed virtiofs mounts  
**Applies to:** VM-220 (colossus-dev-app1, pve-2), VM-120 (colossus-prod-app1, pve-1)  
**Status:** ⬜ PENDING

---

## 0. Purpose

The Colossus-Legal backend needs persistent, externalized storage for PDF documents that will be served to the frontend UI. The current app VMs use a local directory (`/var/home/core/data/documents`) which violates the Colossus golden rule: **no persistent data inside container layers or VM root filesystems.**

This runbook implements the full Colossus storage pattern: ZFS dataset → Proxmox directory mapping → virtiofs → systemd mount unit → container volume. This is the same pattern used for the database VMs (VM-210, VM-110) and is designed to be repeatable for any future storage need.

**Why Butane/Ignition rebuild (not runtime patching):**  
Ignition only executes on first boot. To change mount units declaratively, we must destroy and recreate the VM. Since app VMs are stateless — all persistent data lives on the Proxmox host — this is safe and takes minutes.

---

## 1. Prerequisites

| Requirement | Detail |
|-------------|--------|
| SSH access to pve-1 and pve-2 | As root |
| SSH access to workstation | For Butane transpilation |
| Existing ZFS pools | `dev-zfs` on pve-2, `prod-zfs` on pve-1 |
| CoreOS QCOW2 image | Already present at `/var/coreos/images/` on both nodes |
| Butane CLI | Via container: `quay.io/coreos/butane:release` |
| PDF source files | 16 PDFs at `~/colossus-legal-data/` on workstation |
| Ansible vault password | For subsequent application deployment |

---

## 2. Architecture Overview

```
Workstation                     pve-2 (DEV)                          pve-1 (PROD)
───────────                     ──────────                           ──────────

PDFs copied via SCP ──────────► dev-zfs/legal-docs (ZFS dataset)     prod-zfs/legal-docs (ZFS dataset)
                                    │                                     │
                                    ▼                                     ▼
                                Proxmox directory mapping             Proxmox directory mapping
                                "dev-legal-docs"                      "prod-legal-docs"
                                    │                                     │
                                    ▼ virtiofs                            ▼ virtiofs
                                VM-220 (colossus-dev-app1)            VM-120 (colossus-prod-app1)
                                /var/mnt/data/legal-docs              /var/mnt/data/legal-docs
                                    │ systemd mount unit                  │ systemd mount unit
                                    │ (SELinux: container_file_t)         │ (SELinux: container_file_t)
                                    ▼                                     ▼
                                colossus-backend container            colossus-backend container
                                /data/documents:rw                    /data/documents:rw
```

**Storage chain (each layer):**

| Layer | What | Where |
|-------|------|-------|
| 1. ZFS Dataset | `{env}-zfs/legal-docs` | Proxmox host filesystem |
| 2. Directory Mapping | `{env}-legal-docs` | Proxmox cluster config |
| 3. virtiofs Device | `--virtiofs0 dirid={mapping}` | VM hardware config |
| 4. systemd Mount Unit | `var-mnt-data-legal\x2ddocs.mount` | Inside CoreOS (Ignition) |
| 5. Container Volume | `/mnt/data/legal-docs:/data/documents:rw` | Quadlet .container file |

---

## 3. Phase 1 — ZFS Dataset Creation

### 3.1 DEV (pve-2)

SSH to pve-2:

```bash
ssh root@pve-2
```

Create the dataset:

```bash
zfs create dev-zfs/legal-docs
```

No special recordsize tuning needed — PDFs are large sequential reads and the default 128K is ideal.

Verify:

```bash
zfs list dev-zfs/legal-docs
zfs get compression,mountpoint dev-zfs/legal-docs
```

Expected mountpoint: `/dev-zfs/legal-docs`

Set ownership for virtiofs passthrough:

```bash
chmod 755 /dev-zfs/legal-docs
```

### 3.2 PROD (pve-1)

SSH to pve-1:

```bash
ssh root@pve-1
```

```bash
zfs create prod-zfs/legal-docs
zfs list prod-zfs/legal-docs
zfs get compression,mountpoint prod-zfs/legal-docs
chmod 755 /prod-zfs/legal-docs
```

Expected mountpoint: `/prod-zfs/legal-docs`

### 3.3 Verification Gate

- [ ] `zfs list dev-zfs/legal-docs` shows the dataset on pve-2
- [ ] `zfs list prod-zfs/legal-docs` shows the dataset on pve-1
- [ ] Both mountpoints exist and are accessible

---

## 4. Phase 2 — Proxmox Directory Mappings

Directory mappings are **cluster-level** resources. They can be created from any Proxmox node but must reference the correct node and path.

### 4.1 DEV Mapping

On any Proxmox node (pve-1, pve-2, or pve-3):

```bash
pvesh create /cluster/mapping/dir \
  --id dev-legal-docs \
  --map "node=pve-2,path=/dev-zfs/legal-docs"
```

Verify:

```bash
pvesh get /cluster/mapping/dir/dev-legal-docs
```

### 4.2 PROD Mapping

```bash
pvesh create /cluster/mapping/dir \
  --id prod-legal-docs \
  --map "node=pve-1,path=/prod-zfs/legal-docs"
```

Verify:

```bash
pvesh get /cluster/mapping/dir/prod-legal-docs
```

### 4.3 Verification Gate

- [ ] `pvesh get /cluster/mapping/dir/dev-legal-docs` returns correct path
- [ ] `pvesh get /cluster/mapping/dir/prod-legal-docs` returns correct path

---

## 5. Phase 3 — Copy PDFs to ZFS Datasets

Copy the source documents before the VMs are rebuilt so they're available on first boot.

### 5.1 From Workstation

```bash
# DEV
scp ~/colossus-legal-data/*.pdf root@pve-2:/dev-zfs/legal-docs/

# PROD
scp ~/colossus-legal-data/*.pdf root@pve-1:/prod-zfs/legal-docs/
```

### 5.2 Verify File Counts

On pve-2:

```bash
ls -la /dev-zfs/legal-docs/
ls /dev-zfs/legal-docs/*.pdf | wc -l
# Expected: 16
```

On pve-1:

```bash
ls -la /prod-zfs/legal-docs/
ls /prod-zfs/legal-docs/*.pdf | wc -l
# Expected: 16
```

### 5.3 Verification Gate

- [ ] 16 PDFs present in `/dev-zfs/legal-docs/` on pve-2
- [ ] 16 PDFs present in `/prod-zfs/legal-docs/` on pve-1

---

## 6. Phase 4 — Update Butane Configurations

This is the core change. We're replacing the local document directory with a virtiofs mount, adding a systemd mount unit, and updating the Quadlet backend container to depend on the mount.

### 6.1 Critical CoreOS/virtiofs Rules (Reference)

These rules apply to ALL virtiofs mounts on CoreOS — commit them to memory for future use:

1. **Canonical paths only:** CoreOS symlinks `/mnt` → `/var/mnt`. systemd mount units MUST use `/var/mnt/data/...` — never `/mnt/data/...`
2. **SELinux context required:** virtiofs mounts from Proxmox (non-SELinux host) appear as `virtiofs_t`. Containers running as `container_t` cannot access them. Fix: `Options=context="system_u:object_r:container_file_t:s0"` on the mount unit
3. **No `:z` or `:Z` volume flags:** virtiofs lacks xattr passthrough. SELinux relabeling doesn't work. The mount-level `context=` option handles it instead
4. **Mount unit naming:** systemd derives the unit name from the path. `/var/mnt/data/legal-docs` → `var-mnt-data-legal\x2ddocs.mount` (hyphens in the final component are escaped as `\x2d`)

### 6.2 Changes to DEV Butane (colossus-dev-app1.bu)

Open `colossus-dev-app1.bu` on your workstation. Make these changes:

**A. Remove the local documents directory.** Delete:

```yaml
  directories:
    - path: /var/home/core/data/documents
      mode: 0755
```

**B. Add the virtiofs systemd mount unit.** Add this file entry in the `storage.files` section:

```yaml
    # ── virtiofs mount unit — legal document storage ─────────────────────────
    # Mounts ZFS dataset exposed from pve-2 via Proxmox directory mapping.
    # What= must match the dirid used in `qm set --virtiofs0 dirid=dev-legal-docs`
    # Where= must use canonical /var/mnt/data/ path (not /mnt/data/)
    # SELinux context= is REQUIRED — see header comments
    - path: /etc/systemd/system/var-mnt-data-legal\x2ddocs.mount
      mode: 0644
      contents:
        inline: |
          [Unit]
          Description=Mount legal documents (virtiofs from host ZFS)
          After=systemd-modules-load.service
          Before=multi-user.target

          [Mount]
          What=legaldocs
          Where=/var/mnt/data/legal-docs
          Type=virtiofs
          Options=context="system_u:object_r:container_file_t:s0"

          [Install]
          WantedBy=multi-user.target
```

**C. Update the backend Quadlet container definition.** Replace the existing `colossus-backend.container` inline content:

```yaml
    # ── Backend Quadlet container definition ─────────────────────────────────
    - path: /etc/containers/systemd/colossus-backend.container
      mode: 0644
      contents:
        inline: |
          [Unit]
          Description=Colossus-Legal Backend (Rust/Axum)
          After=network-online.target var-mnt-data-legal\x2ddocs.mount
          Wants=network-online.target
          Requires=var-mnt-data-legal\x2ddocs.mount

          [Container]
          Image=ghcr.io/rhrywnak/colossus-backend:v0.2.0
          ContainerName=colossus-backend
          EnvironmentFile=/var/home/core/colossus/backend.env
          PublishPort=3403:3403
          Volume=/mnt/data/legal-docs:/data/documents:rw

          [Service]
          Restart=always
          RestartSec=10

          [Install]
          WantedBy=multi-user.target default.target
```

**Key changes from original:**
- `After=` now includes `var-mnt-data-legal\x2ddocs.mount`
- `Requires=var-mnt-data-legal\x2ddocs.mount` — container won't start without the mount
- `Volume=` changed from `/var/home/core/data/documents:/data/documents:Z` to `/mnt/data/legal-docs:/data/documents:rw`
- `:Z` replaced with `:rw` — SELinux is handled by the mount unit's `context=` option
- Image updated to `v0.2.0` (current deployed version)
- Container name changed from `colossus-legal-backend` to `colossus-backend` (matches Ansible)

**D. Add the mount unit to systemd enablement.** In the `systemd.units` section (add this section if it doesn't exist):

```yaml
systemd:
  units:
    - name: var-mnt-data-legal\x2ddocs.mount
      enabled: true
```

### 6.3 Changes to PROD Butane (colossus-prod-app1.bu)

Apply the **identical** changes as DEV (sections A through D above). The mount unit, Quadlet dependencies, and volume paths are the same in both environments.

The only things that remain environment-specific (and are already different) are the backend.env and frontend.env contents, and the network configuration.

### 6.4 Verification Gate

Before transpiling, review each Butane file and confirm:

- [ ] No `directories` entry for `/var/home/core/data/documents`
- [ ] Mount unit file at `/etc/systemd/system/var-mnt-data-legal\x2ddocs.mount`
- [ ] Mount unit `What=legaldocs` (matches virtiofs tag we'll set in Phase 6)
- [ ] Mount unit `Where=/var/mnt/data/legal-docs` (canonical path)
- [ ] Mount unit has `context="system_u:object_r:container_file_t:s0"`
- [ ] Backend Quadlet has `After=...var-mnt-data-legal\x2ddocs.mount`
- [ ] Backend Quadlet has `Requires=var-mnt-data-legal\x2ddocs.mount`
- [ ] Backend Quadlet volume is `/mnt/data/legal-docs:/data/documents:rw`
- [ ] No `:Z` flag on any Volume line
- [ ] `systemd.units` section enables the mount unit

---

## 7. Phase 5 — Transpile and Deploy Ignition

### 7.1 Transpile DEV

On workstation:

```bash
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < colossus-dev-app1.bu > colossus-dev-app1.ign
```

If Butane returns errors, fix them before proceeding. `--strict` means no warnings are tolerated.

### 7.2 Transpile PROD

```bash
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < colossus-prod-app1.bu > colossus-prod-app1.ign
```

### 7.3 Copy Ignition Files to Proxmox Hosts

```bash
# DEV
scp colossus-dev-app1.ign root@pve-2:/var/coreos/snippets/

# PROD
scp colossus-prod-app1.ign root@pve-1:/var/coreos/snippets/
```

### 7.4 Verification Gate

- [ ] Both `.ign` files transpiled without errors or warnings
- [ ] DEV ignition present at `pve-2:/var/coreos/snippets/colossus-dev-app1.ign`
- [ ] PROD ignition present at `pve-1:/var/coreos/snippets/colossus-prod-app1.ign`

---

## 8. Phase 6 — Destroy and Recreate App VMs

**Why destroy?** Ignition only runs on first boot. There is no way to "re-apply" Ignition to a running CoreOS VM. Since app VMs are stateless (persistent data is now on the host ZFS dataset), destroying is safe.

### 8.1 DEV — VM-220 on pve-2

SSH to pve-2:

```bash
ssh root@pve-2
```

Stop and destroy the existing VM:

```bash
qm stop 220
qm destroy 220 --purge
```

Recreate with virtiofs attached. Use the existing `create-vm-220.sh` script, but **add the virtiofs line after the VM is created.** If the script doesn't include virtiofs, run these commands manually or update the script:

```bash
VMID=220
NAME="colossus-dev-app1"
STORAGE="local-lvm"
CORES=2
MEMORY=4096
DISK_GROW="20G"

QCOW=$(ls /var/coreos/images/fedora-coreos-*.qcow2 2>/dev/null | sort -V | tail -1)
IGN="/var/coreos/snippets/colossus-dev-app1.ign"

# Create VM
qm create $VMID \
    --name $NAME \
    --machine q35 \
    --cores $CORES \
    --memory $MEMORY \
    --net0 "virtio,bridge=vmbr0" \
    --scsihw virtio-scsi-pci

# Import CoreOS disk
qm set $VMID --scsi0 "${STORAGE}:0,import-from=${QCOW}"

# Grow disk
qm resize $VMID scsi0 +${DISK_GROW}

# Cloud-init drive (Ignition delivery)
qm set $VMID --ide2 "${STORAGE}:cloudinit"

# Boot order
qm set $VMID --boot order=scsi0

# Serial console
qm set $VMID --serial0 socket --vga serial0

# Ignition
qm set $VMID --cicustom "vendor=coreos:snippets/colossus-dev-app1.ign"
qm set $VMID --ciupgrade 0

# Start on boot
qm set $VMID --onboot 1

# ── VIRTIOFS — legal document storage ────────────────────────────────────
# dirid= must match the Proxmox directory mapping ID from Phase 2
# The virtiofs tag presented to the VM is derived from the mapping
qm set $VMID --virtiofs0 dirid=dev-legal-docs
```

Verify virtiofs is attached:

```bash
qm config 220 | grep -i virtiofs
```

Start the VM:

```bash
qm start 220
```

Wait ~2-3 minutes for first boot, then verify:

```bash
ssh core@10.10.100.220 'mount | grep virtiofs'
ssh core@10.10.100.220 'ls /mnt/data/legal-docs/'
ssh core@10.10.100.220 'ls -Z /mnt/data/legal-docs/ | head -3'
```

Expected: mount shows `legaldocs on /var/mnt/data/legal-docs type virtiofs`, PDFs are listed, and SELinux context shows `container_file_t`.

### 8.2 PROD — VM-120 on pve-1

SSH to pve-1:

```bash
ssh root@pve-1
```

```bash
qm stop 120
qm destroy 120 --purge
```

Same procedure as DEV, substituting:

```bash
VMID=120
NAME="colossus-prod-app1"
IGN="/var/coreos/snippets/colossus-prod-app1.ign"

# (same qm create sequence as DEV above)

# VIRTIOFS — legal document storage
qm set $VMID --virtiofs0 dirid=prod-legal-docs
```

Start and verify:

```bash
qm start 120
# Wait ~2-3 minutes
ssh core@10.10.100.120 'mount | grep virtiofs'
ssh core@10.10.100.120 'ls /mnt/data/legal-docs/'
ssh core@10.10.100.120 'ls -Z /mnt/data/legal-docs/ | head -3'
```

### 8.3 Verification Gate

- [ ] VM-220: `mount | grep virtiofs` shows `legaldocs on /var/mnt/data/legal-docs`
- [ ] VM-220: `ls /mnt/data/legal-docs/*.pdf | wc -l` returns 16
- [ ] VM-220: `ls -Z /mnt/data/legal-docs/` shows `container_file_t` context
- [ ] VM-120: Same three checks pass
- [ ] Both VMs reachable via SSH at expected IPs

---

## 9. Phase 7 — Update Ansible Role

The `colossus-legal` Ansible role needs to match the new storage paths so that subsequent deploys via Ansible/Semaphore write correct Quadlet files.

### 9.1 Update Role Defaults

Edit `roles/colossus-legal/defaults/main.yml`:

**Change:**
```yaml
colossus_legal_documents_host_path: "/var/colossus/legal-documents"
```

**To:**
```yaml
# Document storage — virtiofs mount from host ZFS dataset
# Mount is managed by Ignition (systemd mount unit), not Ansible.
# Path: host ZFS → Proxmox dir mapping → virtiofs → /var/mnt/data/legal-docs
# Inside the VM, /mnt/ symlinks to /var/mnt/, so both paths work.
colossus_legal_documents_host_path: "/mnt/data/legal-docs"
```

### 9.2 Update Backend Quadlet Template

Edit `roles/colossus-legal/templates/colossus-backend.container.j2`:

**Change:**
```ini
[Unit]
Description=Colossus Legal Backend ({{ deploy_version }})
After=network-online.target
Wants=network-online.target
```

**To:**
```ini
[Unit]
Description=Colossus Legal Backend ({{ deploy_version }})
After=network-online.target var-mnt-data-legal\x2ddocs.mount
Wants=network-online.target
Requires=var-mnt-data-legal\x2ddocs.mount
```

The `Volume=` line already uses the variable and will pick up the new path automatically. **Change the access mode** from `:ro` to `:rw` so the backend can manage documents:
```ini
Volume={{ colossus_legal_documents_host_path }}:{{ colossus_legal_documents_container_path }}:rw
```

### 9.3 Remove Directory Creation Task (Optional)

In `roles/colossus-legal/tasks/main.yml`, the task "Create document storage directory" creates the local path. Since the mount point is now managed by Ignition (systemd mount unit), this task is no longer needed. You can either:

- **Remove it** — clean, but Ansible will fail if ever run against a VM without the mount
- **Keep it with a guard** — safer for error messaging

Recommended: keep it but add a check that the mount exists:

```yaml
# ── Verify document storage mount exists ─────────────────────
- name: "Verify document storage mount is active"
  ansible.builtin.command:
    cmd: mountpoint -q {{ colossus_legal_documents_host_path }}
  changed_when: false
  failed_when: false
  register: _mount_check

- name: "Fail if document storage is not mounted"
  ansible.builtin.fail:
    msg: >-
      Document storage path {{ colossus_legal_documents_host_path }} is not a mount point.
      Verify virtiofs is attached to this VM and the systemd mount unit is active.
  when: _mount_check.rc != 0
```

### 9.4 Commit Changes

```bash
cd ~/Projects/colossus-ansible
git add -A
git commit -m "feat: externalize document storage to virtiofs mount

- Update colossus-legal role defaults: documents path → /mnt/data/legal-docs
- Update backend Quadlet template: add mount unit dependency
- Add mount verification task to catch missing virtiofs early
- Matches Butane/Ignition changes for VM-220 and VM-120"

git push
```

### 9.5 Verification Gate

- [ ] `defaults/main.yml` has `colossus_legal_documents_host_path: "/mnt/data/legal-docs"`
- [ ] `colossus-backend.container.j2` has `Requires=var-mnt-data-legal\x2ddocs.mount`
- [ ] Changes committed and pushed

---

## 10. Phase 8 — Deploy Application via Ansible

Now deploy the application. The Ignition-placed Quadlet files from first boot will be overwritten by Ansible with the correct templates.

### 10.1 Deploy to DEV

From workstation or Semaphore:

```bash
cd ~/Projects/colossus-ansible
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal -e version=v0.2.0 \
  -l colossus-dev-app1 --vault-password-file ~/.vault_pass
```

Or via Semaphore: Run **"Deploy Colossus-Legal — DEV"** → version: `v0.2.0`

### 10.2 Validate DEV

```bash
# Health check
curl -sf http://10.10.100.220:3403/health && echo "✓ Backend healthy"

# API returns data
curl -sf http://10.10.100.220:3403/case | grep -q "awad-v-cfs" && echo "✓ Case data OK"

# Frontend serves
curl -sf http://10.10.100.220:5473/ | grep -q "Colossus" && echo "✓ Frontend OK"

# Verify document mount is used by the container
ssh core@10.10.100.220 'sudo podman inspect colossus-backend --format "{{json .Mounts}}"' | python3 -m json.tool
# Should show /mnt/data/legal-docs → /data/documents
```

External access:
- https://colossus-legal-dev.cogmai.com — Frontend
- https://colossus-legal-api-dev.cogmai.com/health — Backend health

### 10.3 Deploy to PROD

```bash
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal -e version=v0.2.0 -e confirm_prod=true \
  -l colossus-prod-app1 --vault-password-file ~/.vault_pass
```

Or via Semaphore: Run **"Deploy Colossus-Legal — PROD"** → version: `v0.2.0`

### 10.4 Validate PROD

Same validation steps as DEV, substituting:
- IP: `10.10.100.120`
- External: `https://colossus-legal.cogmai.com`, `https://colossus-legal-api.cogmai.com/health`

### 10.5 Verification Gate

- [ ] DEV: `/health` returns 200
- [ ] DEV: `/case` returns data
- [ ] DEV: Frontend loads
- [ ] DEV: Container mounts show `/mnt/data/legal-docs`
- [ ] PROD: All four checks pass
- [ ] External URLs work for both environments

---

## 11. Phase 9 — Update VM Creation Scripts

Update the VM creation scripts so future rebuilds include virtiofs automatically.

### 11.1 Update create-vm-220.sh

Add after the `qm set $VMID --onboot 1` line:

```bash
# ── virtiofs — document storage ──────────────────────────────────────────
# Exposes host ZFS dataset (dev-zfs/legal-docs) into the VM via
# Proxmox directory mapping. Mount unit inside VM handles the rest.
qm set $VMID --virtiofs0 dirid=dev-legal-docs
```

### 11.2 Update create-vm-120.sh

Same change:

```bash
qm set $VMID --virtiofs0 dirid=prod-legal-docs
```

### 11.3 Commit

```bash
cd ~/Projects/colossus-homelab  # or wherever scripts live
git add -A
git commit -m "feat: add virtiofs document storage to app VM creation scripts"
git push
```

---

## 12. Phase 10 — Update Documentation

### 12.1 Update Butane Source Files in Repository

Ensure the updated `.bu` files are committed to `colossus-homelab`:

```bash
cd ~/Projects/colossus-homelab
# Copy updated Butane files to repo
git add -A
git commit -m "feat: update app VM Butane configs with virtiofs document storage"
git push
```

### 12.2 Add PBS Backup Verification

Confirm both rebuilt VMs are covered by existing PBS backup schedules. If not, add them:

```bash
# Check existing backup jobs on pve-2 (DEV)
pvesh get /cluster/backup

# VM-220 should appear in a backup job. If missing, add it.
```

---

## 13. Reboot Validation

After all deployment is complete, reboot both VMs to confirm everything survives:

```bash
# DEV
ssh core@10.10.100.220 'sudo reboot'
# Wait ~2 minutes
ssh core@10.10.100.220 'mount | grep virtiofs'
ssh core@10.10.100.220 'sudo podman ps'
curl -sf http://10.10.100.220:3403/health

# PROD
ssh core@10.10.100.120 'sudo reboot'
# Wait ~2 minutes
ssh core@10.10.100.120 'mount | grep virtiofs'
ssh core@10.10.100.120 'sudo podman ps'
curl -sf http://10.10.100.120:3403/health
```

- [ ] DEV: virtiofs mount survives reboot
- [ ] DEV: containers start automatically after reboot
- [ ] DEV: health check passes after reboot
- [ ] PROD: All three checks pass

---

## 14. Rollback

If anything fails:

1. **VM won't boot / mount fails:** Check virtiofs attachment (`qm config <VMID> | grep virtiofs`), verify directory mapping exists (`pvesh get /cluster/mapping/dir/<id>`), check Ignition for typos in mount unit
2. **Container fails to start:** Check `sudo systemctl status colossus-backend` — if mount dependency fails, the container won't start. Verify mount: `mountpoint -q /mnt/data/legal-docs`
3. **Full rollback:** Destroy the new VM, restore from PBS backup (pre-change), or recreate with the old Butane config (still in git history)

Since the old VMs had no critical persistent data (documents were either absent or in a local dir), there is no data loss scenario.

---

## 15. Repeatable Pattern — Adding New virtiofs Storage

This section documents the generalized pattern for future use. When you need to add a new externalized storage mount to any CoreOS VM:

### Step-by-step:

1. **Create ZFS dataset:** `zfs create {pool}/{dataset-name}`
2. **Create Proxmox directory mapping:** `pvesh create /cluster/mapping/dir --id {mapping-id} --map "node={node},path=/{pool}/{dataset-name}"`
3. **Attach virtiofs to VM:** `qm set {VMID} --virtiofs{N} dirid={mapping-id}`
4. **Add systemd mount unit to Butane:**
   - Path: `/etc/systemd/system/{escaped-path}.mount`
   - `What={virtiofs-tag}` (matches the tag from the directory mapping)
   - `Where=/var/mnt/{your/path}` (canonical, no `/mnt/` symlink)
   - `Options=context="system_u:object_r:container_file_t:s0"` (SELinux)
5. **Enable mount unit:** In `systemd.units` section of Butane
6. **Update Quadlet:** Add `After=` and `Requires=` for the mount unit, update `Volume=`
7. **Transpile → deploy Ignition → destroy/recreate VM**
8. **Update Ansible role** if applicable (defaults, templates)
9. **Update VM creation script** to include `--virtiofs{N}` line

### Naming conventions:

| Item | Convention | Example |
|------|-----------|---------|
| ZFS dataset | `{env}-zfs/{service-name}` | `dev-zfs/legal-docs` |
| Directory mapping | `{env}-{service-name}` | `dev-legal-docs` |
| virtiofs tag | derived from mapping ID | `legaldocs` |
| Mount path (VM) | `/var/mnt/data/{service-name}` | `/var/mnt/data/legal-docs` |
| Mount unit name | systemd-escaped path | `var-mnt-data-legal\x2ddocs.mount` |

### Mount unit name escaping:

systemd derives unit names from paths by replacing `/` with `-` and escaping special characters. For a path like `/var/mnt/data/legal-docs`:
- `/` → `-` (except leading slash, which is dropped)
- `-` in path components → `\x2d`
- Result: `var-mnt-data-legal\x2ddocs.mount`

You can verify with: `systemd-escape -p --suffix=mount /var/mnt/data/legal-docs`

---

## Appendix A — Complete DEV Butane Mount Unit + Quadlet Snippet

For copy-paste reference. This is the minimum addition to any app VM Butane to add virtiofs document storage:

```yaml
# In storage.files:

    # ── virtiofs mount unit ──────────────────────────────────────────────────
    - path: /etc/systemd/system/var-mnt-data-legal\x2ddocs.mount
      mode: 0644
      contents:
        inline: |
          [Unit]
          Description=Mount legal documents (virtiofs from host ZFS)
          After=systemd-modules-load.service
          Before=multi-user.target

          [Mount]
          What=legaldocs
          Where=/var/mnt/data/legal-docs
          Type=virtiofs
          Options=context="system_u:object_r:container_file_t:s0"

          [Install]
          WantedBy=multi-user.target

# In storage.files (backend Quadlet — key lines only):

          [Unit]
          After=network-online.target var-mnt-data-legal\x2ddocs.mount
          Requires=var-mnt-data-legal\x2ddocs.mount

          [Container]
          Volume=/mnt/data/legal-docs:/data/documents:rw

# In systemd.units:

    - name: var-mnt-data-legal\x2ddocs.mount
      enabled: true
```

---

## Appendix B — Execution Checklist (Quick Reference)

| # | Task | Target | Done |
|---|------|--------|------|
| 1 | Create ZFS dataset `dev-zfs/legal-docs` | pve-2 | ⬜ |
| 2 | Create ZFS dataset `prod-zfs/legal-docs` | pve-1 | ⬜ |
| 3 | Create directory mapping `dev-legal-docs` | Proxmox cluster | ⬜ |
| 4 | Create directory mapping `prod-legal-docs` | Proxmox cluster | ⬜ |
| 5 | Copy 16 PDFs to `/dev-zfs/legal-docs/` | pve-2 | ⬜ |
| 6 | Copy 16 PDFs to `/prod-zfs/legal-docs/` | pve-1 | ⬜ |
| 7 | Update DEV Butane (mount unit + Quadlet) | Workstation | ⬜ |
| 8 | Update PROD Butane (mount unit + Quadlet) | Workstation | ⬜ |
| 9 | Transpile DEV Ignition (`--strict`) | Workstation | ⬜ |
| 10 | Transpile PROD Ignition (`--strict`) | Workstation | ⬜ |
| 11 | Copy DEV `.ign` to pve-2 snippets | Workstation → pve-2 | ⬜ |
| 12 | Copy PROD `.ign` to pve-1 snippets | Workstation → pve-1 | ⬜ |
| 13 | Destroy + recreate VM-220 with virtiofs | pve-2 | ⬜ |
| 14 | Verify DEV: mount, PDFs, SELinux context | VM-220 | ⬜ |
| 15 | Destroy + recreate VM-120 with virtiofs | pve-1 | ⬜ |
| 16 | Verify PROD: mount, PDFs, SELinux context | VM-120 | ⬜ |
| 17 | Update Ansible role (defaults + template) | Workstation | ⬜ |
| 18 | Commit Ansible changes | Workstation | ⬜ |
| 19 | Deploy to DEV via Ansible/Semaphore | Workstation | ⬜ |
| 20 | Validate DEV (health, data, frontend, mounts) | Workstation | ⬜ |
| 21 | Deploy to PROD via Ansible/Semaphore | Workstation | ⬜ |
| 22 | Validate PROD | Workstation | ⬜ |
| 23 | Update VM creation scripts | Workstation | ⬜ |
| 24 | Commit Butane + scripts to colossus-homelab | Workstation | ⬜ |
| 25 | Reboot test — DEV | VM-220 | ⬜ |
| 26 | Reboot test — PROD | VM-120 | ⬜ |
| 27 | Verify PBS backup coverage | Proxmox | ⬜ |
