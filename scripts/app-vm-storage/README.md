# App VM virtiofs Storage Scripts

Scripts for adding externalized document storage to Colossus application VMs.

Follows the established Colossus pattern: ZFS dataset → Proxmox directory mapping → virtiofs → systemd mount unit → container volume.

## Scripts

| # | Script | Runs on | Purpose |
|---|--------|---------|---------|
| — | `config.sh` | (sourced) | Shared configuration, parameterized by `ENV` |
| 1 | `01-create-zfs-dataset.sh` | Proxmox host | Create ZFS dataset for PDF storage |
| 2 | `02-create-directory-mapping.sh` | Any Proxmox node | Create cluster-level directory mapping |
| 3 | `03-copy-legal-docs.sh` | Workstation | SCP PDFs to ZFS dataset |
| 4 | `04-recreate-app-vm.sh` | Proxmox host | Destroy + recreate VM with virtiofs |
| 5 | `05-validate-vm-storage.sh` | Workstation | Verify mount, SELinux, files, containers |

## Execution Flow

All scripts are parameterized by `ENV=dev` or `ENV=prod`. Run the full sequence for DEV first, validate, then repeat for PROD.

### DEV (pve-2, VM-220)

```bash
# On pve-2:
ENV=dev ./01-create-zfs-dataset.sh
ENV=dev ./02-create-directory-mapping.sh

# On workstation:
ENV=dev ./03-copy-legal-docs.sh

# On pve-2:
ENV=dev ./04-recreate-app-vm.sh

# On workstation (wait ~2-3 min for boot):
ENV=dev ./05-validate-vm-storage.sh
```

### PROD (pve-1, VM-120)

```bash
# On pve-1:
ENV=prod ./01-create-zfs-dataset.sh
ENV=prod ./02-create-directory-mapping.sh

# On workstation:
ENV=prod ./03-copy-legal-docs.sh

# On pve-1:
ENV=prod ./04-recreate-app-vm.sh

# On workstation (wait ~2-3 min for boot):
ENV=prod ./05-validate-vm-storage.sh
```

### After Both Environments

1. Update Ansible role (see runbook Phase 7)
2. Deploy via Ansible/Semaphore
3. Re-run `05-validate-vm-storage.sh` to confirm container mounts
4. Reboot test both VMs

## Prerequisites

- Updated Butane configs transpiled to Ignition (see runbook Phase 4-5)
- Ignition files placed at `/var/coreos/snippets/` on each Proxmox host
- PDF source files at `~/colossus-legal-data/` on workstation

## Design Notes

- All scripts are **idempotent** — safe to run multiple times
- Script 04 has a **confirmation prompt** before destroying the VM
- Same scripts work for both DEV and PROD via the `ENV` variable
- Pattern is reusable: copy this script set and modify `config.sh` for new storage needs
