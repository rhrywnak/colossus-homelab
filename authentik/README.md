# Authentik VM Deployment Scripts

Provisioning scripts for VM-316 (Authentik) on pve-3. Deploys Authentik 2025.12 as a CoreOS VM with Podman Quadlet containers.

## Architecture

| Container | Image | Port | Volume |
|-----------|-------|------|--------|
| `authentik-postgresql` | `postgres:16-alpine` | internal only | `/mnt/data/postgres` → `/var/lib/postgresql/data` |
| `authentik-server` | `goauthentik/server:2025.12` | 9000, 9443 | `/mnt/data/authentik` → `/data` |
| `authentik-worker` | `goauthentik/server:2025.12` | — | `/mnt/data/authentik` → `/data` |

All three containers communicate via a Podman network (`authentik`). PostgreSQL is not exposed to the host network.

## ZFS Datasets

| Dataset | Mountpoint | Purpose | recordsize |
|---------|-----------|---------|------------|
| `pbs-zfs/services/authentik/postgres` | `/pbs-zfs/services/authentik/postgres` | PostgreSQL data | 8K |
| `pbs-zfs/services/authentik/data` | `/pbs-zfs/services/authentik/data` | Authentik media, templates, exports | 128K (default) |

## Scripts

| # | Script | Runs on | Purpose |
|---|--------|---------|---------|
| — | `config.sh` | (sourced) | Shared configuration |
| 0 | `00-destroy.sh` | pve-3 | Destroy VM (preserves ZFS data) |
| 1 | `01-create-zfs-datasets.sh` | pve-3 | Create ZFS datasets |
| 2 | `02-create-directory-mappings.sh` | pve-3 | Create Proxmox directory mappings |
| 3 | `03-create-vm.sh` | pve-3 | Create and start VM-316 |

## Execution Flow

### Step 0: Prepare Butane config (workstation)

```bash
cd ~/Projects/colossus-homelab/butane/

# 1. Generate secrets
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
AUTHENTIK_SECRET_KEY=$(openssl rand -hex 32)
echo "PostgreSQL password: ${POSTGRES_PASSWORD}"
echo "Authentik secret key: ${AUTHENTIK_SECRET_KEY}"

# 2. Edit authentik.bu — replace all placeholders:
#    CHANGEME_POSTGRES_PASSWORD      (appears in 2 env files — must match)
#    CHANGEME_AUTHENTIK_SECRET_KEY
#    SSH_KEY_OPERATOR                (your ed25519 pubkey)
#    SSH_KEY_SEMAPHORE               (semaphore-infra pubkey)

# 3. Transpile
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < authentik.bu > authentik.ign

# 4. Copy to pve-3
scp authentik.ign root@pve-3:/var/coreos/snippets/
```

### Step 1: Create ZFS datasets (pve-3)

```bash
bash scripts/authentik/01-create-zfs-datasets.sh
```

### Step 2: Create directory mappings (pve-3)

```bash
bash scripts/authentik/02-create-directory-mappings.sh
```

### Step 3: Create and start VM (pve-3)

```bash
bash scripts/authentik/03-create-vm.sh
```

### Step 4: Verify (workstation, ~3-4 min after boot)

```bash
# SSH access
ssh core@10.10.100.58

# Check containers
sudo podman ps

# Check mounts
mount | grep virtiofs

# Access initial setup wizard
curl -s -o /dev/null -w '%{http_code}' http://10.10.100.58:9000/if/flow/initial-setup/
```

## Rebuild

The VM is cattle, not a pet. To rebuild from scratch while preserving data:

```bash
# On pve-3:
bash scripts/authentik/00-destroy.sh    # preserves ZFS data
bash scripts/authentik/03-create-vm.sh  # recreates VM, containers find existing data
```

## Full Cleanup

To remove everything including data:

```bash
# On pve-3:
bash scripts/authentik/00-destroy.sh
zfs destroy -r pbs-zfs/services/authentik

# Remove directory mappings (from any cluster node):
pvesh delete /cluster/mapping/dir/authentik-postgres
pvesh delete /cluster/mapping/dir/authentik-data
```

## Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | 2025.12 not 2025.10 | Latest stable; `/data` mount consolidation; no Redis |
| 2 | 2 ZFS datasets not 3 | 2025.12 uses single `/data` mount; separate `postgres` for 8K recordsize |
| 3 | Podman network | PostgreSQL not exposed to host; clean container DNS resolution |
| 4 | `postgres:16-alpine` | Matches Authentik tested version; lightweight |
| 5 | No Redis container | Removed in Authentik 2025.10; PostgreSQL handles everything |
