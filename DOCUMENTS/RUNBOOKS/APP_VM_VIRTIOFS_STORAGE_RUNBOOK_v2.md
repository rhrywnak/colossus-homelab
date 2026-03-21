# Colossus — Adding virtiofs Storage to Application VMs

**Version:** v2.0
**Date:** 2026-02-25
**Scope:** Externalize document storage from local VM paths to ZFS-backed virtiofs mounts
**Applies to:** VM-220 (colossus-dev-app1, pve-2), VM-120 (colossus-prod-app1, pve-1)
**Status:** ✅ COMPLETE — DEV and PROD operational

---

## 0. Purpose

The Colossus-Legal backend needs persistent, externalized storage for PDF documents that will be served to the frontend UI. This runbook implements the full Colossus storage pattern: ZFS dataset → Proxmox directory mapping → virtiofs → systemd mount unit → container volume. This follows the Colossus golden rule: **no persistent data inside container layers or VM root filesystems.**

**Why Butane/Ignition rebuild (not runtime patching):**
Ignition only executes on first boot. To change mount units declaratively, we must destroy and recreate the VM. A reboot is NOT sufficient — Ignition does not re-run on reboot. Since app VMs are stateless — all persistent data lives on the host ZFS dataset — this is safe and takes minutes.

---

## 1. Prerequisites

| Requirement | Detail |
|-------------|--------|
| SSH access to pve-1 and pve-2 | As root |
| SSH access to workstation | For Butane transpilation and image builds |
| Existing ZFS pools | `dev-zfs` on pve-2, `prod-zfs` on pve-1 |
| CoreOS QCOW2 image | Already present at `/var/coreos/images/` on both nodes |
| Butane CLI | Via container: `quay.io/coreos/butane:release` |
| PDF source files | At `~/colossus-legal-data/documents/` on workstation |
| Ansible vault password | For subsequent application deployment |
| Git push access | Semaphore pulls from `origin/master` — local commits do NOT deploy |

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

## 3. Critical Rules — Commit to Memory

### 3.1 CoreOS / virtiofs Rules

1. **Canonical paths only:** CoreOS symlinks `/mnt` → `/var/mnt`. systemd mount units MUST use `/var/mnt/data/...` — never `/mnt/data/...`
2. **SELinux context required:** virtiofs mounts from Proxmox appear as `virtiofs_t`. Containers running as `container_t` cannot access them. Fix: `Options=context="system_u:object_r:container_file_t:s0"` on the mount unit
3. **No `:z` or `:Z` volume flags:** virtiofs lacks xattr passthrough. The mount-level `context=` option handles SELinux instead
4. **Mount unit naming:** systemd derives the unit name from the path. `/var/mnt/data/legal-docs` → `var-mnt-data-legal\x2ddocs.mount` (hyphens in the final component are escaped as `\x2d`)
5. **virtiofs tag = directory mapping ID:** The `What=` in the mount unit must match the Proxmox directory mapping ID exactly (e.g., `dev-legal-docs`, not a shortened name)
6. **Ignition is first-boot only:** A reboot does NOT re-apply Ignition. To change Ignition config, you must destroy and recreate the VM.

### 3.2 VM Configuration Rules

1. **`--cpu host` is required:** ONNX Runtime (via ort-sys/fastembed) uses AVX2 instructions. The default `kvm64` CPU type strips these, causing SIGILL (exit code 132). Always use `qm set $VMID --cpu host`
2. **Both SSH keys in Butane:** Operator key (roman@proxima-centauri) AND Semaphore infra key must be present, or Ansible deploys fail after rebuild
3. **No quoted passwords in Butane env files:** Podman treats quotes as literal characters. Use `NEO4J_PASSWORD=CHANGEME_ANSIBLE_WILL_OVERWRITE` — Ansible overwrites on deploy

### 3.3 Build Pipeline Rules

1. **Dockerfile base must be Ubuntu 24.04:** Debian Bookworm (glibc 2.36) causes `__isoc23_strtol` linker errors. Ubuntu 24.04 (glibc 2.39) matches the workstation
2. **Rust version must match workstation:** Check `cargo --version` and match in Dockerfile. Currently 1.88
3. **Use `--locked` in Dockerfile:** Prevents surprise crate upgrades. `Cargo.lock` is the source of truth
4. **Use `--no-cache` in build-release.sh:** Prevents stale layers from hiding code changes
5. **Always `git push` before Semaphore deploy:** Semaphore pulls from `origin/master`. Unpushed local commits do not deploy. Verify with `git log --oneline origin/master..HEAD`

### 3.4 Semaphore Rules

1. **Limit goes in the Limit field:** Not in CLI Args. Semaphore passes CLI args as positional arguments
2. **Clear SSH known_hosts after VM rebuild:** On BOTH the workstation AND Semaphore (CT-315 at 10.10.100.57)

---

## 4. Phase 1 — ZFS Dataset Creation

**Run on:** Proxmox host (pve-2 for DEV, pve-1 for PROD)

### 4.1 Scripted (recommended)

Copy scripts to the Proxmox host first — they must run locally, not from the workstation:

```bash
# From workstation
scp -r ~/Projects/colossus-homelab/scripts/app-vm-storage root@pve-2:/tmp/

# On pve-2
ssh root@pve-2
cd /tmp/app-vm-storage
ENV=dev ./01-create-zfs-dataset.sh
```

### 4.2 Manual

```bash
ssh root@pve-2

zfs create dev-zfs/legal-docs
zfs list dev-zfs/legal-docs
zfs get compression,mountpoint dev-zfs/legal-docs
chmod 755 /dev-zfs/legal-docs
```

Expected mountpoint: `/dev-zfs/legal-docs`

### 4.3 PROD (pve-1)

Same procedure, substituting `prod-zfs/legal-docs` and running on pve-1.

### 4.4 Verification Gate

- [ ] `zfs list dev-zfs/legal-docs` shows the dataset on pve-2
- [ ] `zfs list prod-zfs/legal-docs` shows the dataset on pve-1
- [ ] Both mountpoints exist and are accessible

---

## 5. Phase 2 — Proxmox Directory Mappings

**Run on:** Proxmox host (cluster-level resource, but must reference correct node and path)

### 5.1 Scripted

```bash
# On pve-2
ENV=dev ./02-create-directory-mapping.sh
```

### 5.2 Manual

```bash
pvesh create /cluster/mapping/dir \
  --id dev-legal-docs \
  --map "node=pve-2,path=/dev-zfs/legal-docs"

pvesh get /cluster/mapping/dir/dev-legal-docs
```

### 5.3 PROD

```bash
# On pve-1
pvesh create /cluster/mapping/dir \
  --id prod-legal-docs \
  --map "node=pve-1,path=/prod-zfs/legal-docs"
```

### 5.4 Verification Gate

- [ ] `pvesh get /cluster/mapping/dir/dev-legal-docs` returns correct path
- [ ] `pvesh get /cluster/mapping/dir/prod-legal-docs` returns correct path

---

## 6. Phase 3 — Copy PDFs to ZFS Datasets

**Run from:** Workstation (SCP to Proxmox hosts)

The copy script expects files on the Proxmox host. Since the PDFs live on the workstation, SCP directly:

```bash
# DEV
scp ~/colossus-legal-data/documents/*.pdf root@pve-2:/dev-zfs/legal-docs/

# PROD
scp ~/colossus-legal-data/documents/*.pdf root@pve-1:/prod-zfs/legal-docs/
```

**IMPORTANT:** Do NOT include trailing slash on the source path if the target directory may not exist.

### 6.1 Verify

```bash
# On pve-2
ssh root@pve-2 "ls /dev-zfs/legal-docs/*.pdf | wc -l"

# On pve-1
ssh root@pve-1 "ls /prod-zfs/legal-docs/*.pdf | wc -l"
```

### 6.2 Verification Gate

- [ ] PDFs present in `/dev-zfs/legal-docs/` on pve-2
- [ ] PDFs present in `/prod-zfs/legal-docs/` on pve-1

---

## 7. Phase 4 — Update Butane Configurations

**Run on:** Workstation

### 7.1 Butane Requirements

Each Butane config must include:

**SSH keys (both required):**
```yaml
ssh_authorized_keys:
  - "ssh-ed25519 AAAAC3...mUpD6 roman@proxima-centauri"
  - "ssh-ed25519 AAAAC3...kj+C semaphore-infra@colossus"
```

**virtiofs mount unit:**
```yaml
- path: /etc/systemd/system/var-mnt-data-legal\x2ddocs.mount
  mode: 0644
  contents:
    inline: |
      [Unit]
      Description=Mount legal documents (virtiofs from host ZFS)
      After=systemd-modules-load.service
      Before=multi-user.target

      [Mount]
      What={env}-legal-docs
      Where=/var/mnt/data/legal-docs
      Type=virtiofs
      Options=context="system_u:object_r:container_file_t:s0"

      [Install]
      WantedBy=multi-user.target
```

**Backend Quadlet (key lines):**
```yaml
After=network-online.target var-mnt-data-legal\x2ddocs.mount
Requires=var-mnt-data-legal\x2ddocs.mount
Volume=/mnt/data/legal-docs:/data/documents:rw
```

**Backend env (no quoted passwords):**
```yaml
NEO4J_PASSWORD=CHANGEME_ANSIBLE_WILL_OVERWRITE
```

**Mount unit enabled:**
```yaml
systemd:
  units:
    - name: var-mnt-data-legal\x2ddocs.mount
      enabled: true
```

### 7.2 Environment-Specific Values

| Field | DEV | PROD |
|-------|-----|------|
| IP address | 10.10.100.220/24 | 10.10.100.120/24 |
| virtiofs What= | dev-legal-docs | prod-legal-docs |
| NEO4J_URI | bolt://10.10.100.200:7687 | bolt://10.10.100.110:7687 |
| QDRANT_URL | http://10.10.100.200:6333 | http://10.10.100.110:6333 |
| CORS | https://colossus-legal-dev.cogmai.com | https://colossus-legal.cogmai.com |
| API URL | https://colossus-legal-api-dev.cogmai.com | https://colossus-legal-api.cogmai.com |
| RUST_LOG | debug | warn |

### 7.3 File Locations

| File | Location |
|------|----------|
| DEV Butane | `~/Projects/colossus-homelab/app-vm-deployment/app-vm/colossus-dev-app1.bu` |
| PROD Butane | `~/Projects/colossus-homelab/prod-vm-deployment/prod-vm/colossus-prod-app1.bu` |

### 7.4 Verification Gate

- [ ] Both SSH keys present in both Butane files
- [ ] Mount unit `What=` matches directory mapping ID
- [ ] Mount unit `Where=/var/mnt/data/legal-docs` (canonical path)
- [ ] Mount unit has SELinux context option
- [ ] Backend Quadlet has `Requires=` for mount unit
- [ ] No quoted passwords in env files
- [ ] No `:Z` flag on any Volume line

---

## 8. Phase 5 — Transpile and Deploy Ignition

**Run on:** Workstation

```bash
# DEV
cd ~/Projects/colossus-homelab/app-vm-deployment/app-vm
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < colossus-dev-app1.bu > colossus-dev-app1.ign
scp colossus-dev-app1.ign root@pve-2:/var/coreos/snippets/

# PROD
cd ~/Projects/colossus-homelab/prod-vm-deployment/prod-vm
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < colossus-prod-app1.bu > colossus-prod-app1.ign
scp colossus-prod-app1.ign root@pve-1:/var/coreos/snippets/
```

`--strict` means no warnings tolerated. Fix any errors before proceeding.

### 8.1 Verification Gate

- [ ] Both `.ign` files transpiled without errors
- [ ] DEV ignition present at `pve-2:/var/coreos/snippets/colossus-dev-app1.ign`
- [ ] PROD ignition present at `pve-1:/var/coreos/snippets/colossus-prod-app1.ign`

---

## 9. Phase 6 — Destroy and Recreate App VMs

**Run on:** Proxmox host (scripts must execute locally, not from workstation)

### 9.1 Copy Updated Script to Proxmox Host

```bash
# From workstation
scp ~/Projects/colossus-homelab/scripts/app-vm-storage/04-recreate-app-vm.sh \
  root@pve-2:/tmp/app-vm-storage/

scp ~/Projects/colossus-homelab/scripts/app-vm-storage/04-recreate-app-vm.sh \
  root@pve-1:/tmp/app-vm-storage/
```

### 9.2 Recreate DEV (VM-220)

```bash
ssh root@pve-2
cd /tmp/app-vm-storage
ENV=dev ./04-recreate-app-vm.sh
```

The script includes `--cpu host` and virtiofs attachment automatically.

### 9.3 Recreate PROD (VM-120)

```bash
ssh root@pve-1
cd /tmp/app-vm-storage
ENV=prod ./04-recreate-app-vm.sh
```

### 9.4 Post-Rebuild: Clear SSH Known Hosts

VM rebuilds generate new host keys. Clear stale keys on BOTH the workstation AND Semaphore:

```bash
# On workstation
ssh-keygen -R 10.10.100.220   # DEV
ssh-keygen -R 10.10.100.120   # PROD
ssh core@10.10.100.220        # accept new key
ssh core@10.10.100.120        # accept new key

# On Semaphore (CT-315)
ssh root@10.10.100.57
su - semaphore
ssh-keygen -R 10.10.100.220
ssh core@10.10.100.220        # accept new key
ssh-keygen -R 10.10.100.120
ssh core@10.10.100.120        # accept new key
exit
exit
```

### 9.5 Validate VM Configuration

Wait ~3-4 minutes for first boot (Ignition + Python install + reboot), then:

```bash
ssh core@10.10.100.220

# CPU must show actual host CPU (not "Common KVM processor")
cat /proc/cpuinfo | grep "model name" | head -1

# virtiofs must be mounted
mount | grep virtiofs

# PDFs must be visible
ls /mnt/data/legal-docs/*.pdf | wc -l

# SELinux context must be container_file_t
ls -Z /mnt/data/legal-docs/ | head -3
```

### 9.6 Verification Gate

- [ ] VM-220: CPU shows host CPU (e.g., AMD Ryzen 7 5700U)
- [ ] VM-220: virtiofs mounted at `/var/mnt/data/legal-docs`
- [ ] VM-220: PDFs listed
- [ ] VM-220: SELinux context shows `container_file_t`
- [ ] VM-120: All four checks pass
- [ ] SSH known_hosts cleared on workstation and Semaphore

---

## 10. Phase 7 — Build Container Images

**Run on:** Workstation

### 10.1 Pre-Build Checklist

Before building, verify these are correct:

```bash
# Rust toolchain version
cargo --version
# Must match Dockerfile FROM — currently 1.88

# Dockerfile base image
grep "FROM" ~/Projects/colossus-legal/backend/Dockerfile
# Must be ubuntu:24.04 (glibc 2.39)

# --locked flag present
grep "cargo build" ~/Projects/colossus-legal/backend/Dockerfile
# Both lines must include --locked

# Source is committed and clean
cd ~/Projects/colossus-legal
git status
git log --oneline -1
```

### 10.2 Build

```bash
cd ~/Projects/colossus-ansible/scripts
./build-release.sh v0.3.2
```

The script uses `--no-cache`, builds both backend and frontend, and pushes to ghcr.io.

### 10.3 Verification Gate

- [ ] Both images built without errors
- [ ] Both images pushed to ghcr.io

---

## 11. Phase 8 — Deploy via Ansible/Semaphore

### 11.1 Pre-Deploy: Ensure Changes Are Pushed

**CRITICAL:** Semaphore pulls from `origin/master`. Unpushed commits do not deploy.

```bash
cd ~/Projects/colossus-ansible
git log --oneline origin/master..HEAD
# Must be empty — if not:
git push
```

### 11.2 Deploy to DEV

Via Semaphore: Run **"Deploy Colossus-Legal — DEV"** → version: `v0.3.2`

### 11.3 Validate DEV

```bash
ssh core@10.10.100.220

# Quadlet has correct volume path
cat /etc/containers/systemd/colossus-backend.container | grep Volume
# Must show: /mnt/data/legal-docs:/data/documents:rw

# Container mount is correct
sudo podman inspect colossus-backend --format '{{json .Mounts}}' | python3 -m json.tool
# Source must be /mnt/data/legal-docs, RW must be true

# Health check
curl -s http://localhost:3403/health
# Must return: OK

# From workstation — external access
curl -s https://colossus-legal-api-dev.cogmai.com/health
# Must return: OK
```

### 11.4 Deploy to PROD

Via Semaphore: Run **"Deploy Colossus-Legal — PROD"** → version: `v0.3.2`

**Note:** Ensure the Limit field contains `colossus-prod-app1` (not in CLI Args).

### 11.5 Validate PROD

Same checks as DEV, substituting:

- IP: `10.10.100.120`
- External: `https://colossus-legal-api.cogmai.com/health`

### 11.6 End-to-End Validation

Open the frontend in a browser and confirm PDF documents load:

- DEV: `https://colossus-legal-dev.cogmai.com`
- PROD: `https://colossus-legal.cogmai.com`

### 11.7 Verification Gate

- [ ] DEV: Quadlet shows `/mnt/data/legal-docs:/data/documents:rw`
- [ ] DEV: Health check passes
- [ ] DEV: PDFs viewable in frontend
- [ ] PROD: All three checks pass
- [ ] External URLs work for both environments

---

## 12. Phase 9 — Commit and Push All Changes

```bash
# colossus-legal (Dockerfile + Cargo.lock)
cd ~/Projects/colossus-legal
git add -A
git commit -m "fix: Ubuntu 24.04 base, rust 1.88, --locked builds"
git push

# colossus-homelab (Butane, scripts, runbooks)
cd ~/Projects/colossus-homelab
git add -A
git commit -m "feat: virtiofs storage, --cpu host, updated Butane and scripts"
git push

# colossus-ansible (role updates)
cd ~/Projects/colossus-ansible
git add -A
git commit -m "feat: externalize document storage to virtiofs mount"
git push
```

---

## 13. Reboot Validation

Confirm everything survives a reboot:

```bash
# DEV
ssh core@10.10.100.220 'sudo reboot'
# Wait ~2 minutes
ssh core@10.10.100.220 'mount | grep virtiofs'
ssh core@10.10.100.220 'sudo podman ps'
curl -sf https://colossus-legal-api-dev.cogmai.com/health

# PROD
ssh core@10.10.100.120 'sudo reboot'
# Wait ~2 minutes
ssh core@10.10.100.120 'mount | grep virtiofs'
ssh core@10.10.100.120 'sudo podman ps'
curl -sf https://colossus-legal-api.cogmai.com/health
```

- [ ] DEV: virtiofs mount survives reboot
- [ ] DEV: containers start automatically
- [ ] DEV: health check passes
- [ ] PROD: All three checks pass

---

## 14. Rollback

If anything fails:

1. **VM won't boot / mount fails:** Check virtiofs attachment (`qm config <VMID> | grep virtiofs`), verify directory mapping exists (`pvesh get /cluster/mapping/dir/<id>`), check Ignition for typos in mount unit
2. **Container fails with exit code 132 (SIGILL):** VM CPU is not `host`. Fix: `qm set <VMID> --cpu host && qm reboot <VMID>`
3. **Container runs but wrong volume path:** Ansible didn't deploy. Check `git log --oneline origin/master..HEAD` — push if needed, then redeploy via Semaphore
4. **Container can't read documents:** Check SELinux context (`ls -Z /mnt/data/legal-docs/`), verify mount has `context=` option
5. **Full rollback:** Destroy the new VM, restore from PBS backup, or recreate with the old Butane config (still in git history)

---

## 15. Repeatable Pattern — Adding New virtiofs Storage

When you need to add a new externalized storage mount to any CoreOS VM:

### Step-by-step:

1. **Create ZFS dataset:** `zfs create {pool}/{dataset-name}`
2. **Create Proxmox directory mapping:** `pvesh create /cluster/mapping/dir --id {mapping-id} --map "node={node},path=/{pool}/{dataset-name}"`
3. **Attach virtiofs to VM:** `qm set {VMID} --virtiofs{N} dirid={mapping-id}`
4. **Set CPU type:** `qm set {VMID} --cpu host` (if ONNX or AVX2 is needed)
5. **Add systemd mount unit to Butane:**
   - Path: `/etc/systemd/system/{escaped-path}.mount`
   - `What={mapping-id}` (matches the directory mapping ID, NOT a shortened name)
   - `Where=/var/mnt/{your/path}` (canonical, no `/mnt/` symlink)
   - `Options=context="system_u:object_r:container_file_t:s0"` (SELinux)
6. **Enable mount unit:** In `systemd.units` section of Butane
7. **Update Quadlet:** Add `After=` and `Requires=` for the mount unit, update `Volume=`
8. **Include both SSH keys:** Operator + Semaphore in Butane
9. **Transpile → deploy Ignition → destroy/recreate VM** (reboot is NOT sufficient)
10. **Clear SSH known_hosts** on workstation AND Semaphore
11. **Update Ansible role** if applicable (defaults, templates)
12. **Push to git** before Semaphore deploy
13. **Deploy via Semaphore** (not manual Ansible)
14. **Update VM creation script** to include `--virtiofs{N}` and `--cpu host`

### Naming conventions:

| Item | Convention | Example |
|------|-----------|---------|
| ZFS dataset | `{env}-zfs/{service-name}` | `dev-zfs/legal-docs` |
| Directory mapping | `{env}-{service-name}` | `dev-legal-docs` |
| virtiofs tag | same as mapping ID | `dev-legal-docs` |
| Mount path (VM) | `/var/mnt/data/{service-name}` | `/var/mnt/data/legal-docs` |
| Mount unit name | systemd-escaped path | `var-mnt-data-legal\x2ddocs.mount` |

### Mount unit name escaping:

systemd derives unit names from paths by replacing `/` with `-` and escaping special characters:

- `/` → `-` (except leading slash, which is dropped)
- `-` in path components → `\x2d`
- Verify with: `systemd-escape -p --suffix=mount /var/mnt/data/legal-docs`

---

## 16. Build Troubleshooting Checklist

When container builds fail, work through this checklist in order:

### 16.1 Rust Version Mismatch

**Symptom:** `feature 'edition2024' is required` or `requires rustc X.Y`

**Fix:** Match Dockerfile Rust version to workstation:

```bash
cargo --version   # shows workstation version
grep "FROM" backend/Dockerfile   # shows Dockerfile version
```

Update Dockerfile to match. Currently: `rust 1.88` installed via rustup on `ubuntu:24.04`.

### 16.2 glibc Mismatch (Linker Errors)

**Symptom:** `undefined reference to '__isoc23_strtol'` or similar `__isoc23_*` errors

**Fix:** Use Ubuntu 24.04 as the Dockerfile base, not Debian Bookworm:

```bash
ldd --version   # shows workstation glibc (should be 2.39)
```

The `ort-sys` crate ships prebuilt ONNX Runtime libraries compiled against glibc 2.38+. Debian Bookworm has glibc 2.36.

### 16.3 SIGILL at Runtime (Exit Code 132)

**Symptom:** Container starts then immediately dies with exit code 132. `journalctl` shows `Main process exited, code=exited, status=132/n/a`

**Fix:** VM CPU type must be `host`:

```bash
qm config <VMID> | grep cpu   # check current type
qm set <VMID> --cpu host      # fix
qm reboot <VMID>              # apply
```

ONNX Runtime requires AVX2 instructions. The default `kvm64` CPU type only provides SSE2.

### 16.4 Stale Deployment (Old Files on Disk)

**Symptom:** Ansible deploys successfully but old config files remain on the VM

**Fix:** Ensure changes are pushed to git:

```bash
cd ~/Projects/colossus-ansible
git log --oneline origin/master..HEAD
# If not empty → git push, then redeploy
```

### 16.5 Crate Version Conflicts

**Symptom:** `failed to select a version for the requirement` errors

**Fix:** Use `--locked` in Dockerfile and ensure `Cargo.lock` is committed:

```bash
cd ~/Projects/colossus-legal/backend
cargo update                # resolve locally first
cargo check                 # verify it builds
git add Cargo.lock
git commit -m "update Cargo.lock"
```

### 16.6 sed Mangles Files

**Symptom:** Using `sed` to edit Dockerfiles or scripts produces corrupted output

**Fix:** Don't use `sed` for complex edits. Use your editor instead. If `sed` corrupts a file:

```bash
git checkout <file>   # restore from git
# Then edit manually
```

---

## Appendix A — Execution Checklist (Quick Reference)

| # | Task | Target | Done |
|---|------|--------|------|
| 1 | Create ZFS dataset | Proxmox host | ⬜ |
| 2 | Create directory mapping | Proxmox cluster | ⬜ |
| 3 | Copy PDFs to ZFS dataset | Workstation → Proxmox | ⬜ |
| 4 | Update Butane (mount unit, SSH keys, Quadlet) | Workstation | ⬜ |
| 5 | Transpile Ignition (`--strict`) | Workstation | ⬜ |
| 6 | Copy `.ign` to Proxmox snippets | Workstation → Proxmox | ⬜ |
| 7 | Copy recreate script to Proxmox host | Workstation → Proxmox | ⬜ |
| 8 | Destroy + recreate VM with virtiofs + `--cpu host` | Proxmox host | ⬜ |
| 9 | Clear SSH known_hosts (workstation + Semaphore) | Both | ⬜ |
| 10 | Validate: CPU, mount, PDFs, SELinux | VM | ⬜ |
| 11 | Verify Dockerfile: Ubuntu 24.04, rust 1.88, --locked | Workstation | ⬜ |
| 12 | Build images with --no-cache | Workstation | ⬜ |
| 13 | Push all git repos | Workstation | ⬜ |
| 14 | Deploy via Semaphore | Semaphore UI | ⬜ |
| 15 | Validate: volume path, health, frontend | VM + browser | ⬜ |
| 16 | Reboot test | VM | ⬜ |

---

## Appendix B — Lessons Learned (2026-02-25 Session)

| # | Lesson | Impact |
|---|--------|--------|
| 1 | Check `cargo --version` FIRST — match Dockerfile to workstation | Would have avoided 3 failed builds |
| 2 | Check `ldd --version` FIRST — glibc must match | Would have avoided linker errors |
| 3 | Check VM CPU type FIRST — `kvm64` doesn't have AVX2 | Would have avoided SIGILL |
| 4 | `git push` before Semaphore — local commits don't deploy | Volume path stayed wrong through multiple deploys |
| 5 | Scripts run on Proxmox host, not workstation | ZFS commands only work locally |
| 6 | Ignition is first-boot only — reboot ≠ re-apply | Added virtiofs after VM creation but mount never appeared |
| 7 | sed is dangerous for complex edits — use an editor | Mangled Dockerfile beyond recognition |
| 8 | `--no-cache` exposes dependency issues hidden by cache | `ort` crate upgrade was invisible with cached builds |
| 9 | `--locked` prevents build-time dependency resolution | Reproducible builds from `Cargo.lock` |
| 10 | Podman treats quotes in env files as literal characters | `NEO4J_PASSWORD='foo'` becomes password `'foo'` with quotes |

---

## Appendix C — Service Endpoints Reference

| Service | DEV | PROD |
|---------|-----|------|
| Frontend | https://colossus-legal-dev.cogmai.com | https://colossus-legal.cogmai.com |
| API | https://colossus-legal-api-dev.cogmai.com | https://colossus-legal-api.cogmai.com |
| Neo4j | bolt://10.10.100.200:7687 | bolt://10.10.100.110:7687 |
| Qdrant | http://10.10.100.200:6333 | http://10.10.100.110:6333 |
| PostgreSQL | postgresql://10.10.100.200:5432/colossus | postgresql://10.10.100.110:5432/colossus |
