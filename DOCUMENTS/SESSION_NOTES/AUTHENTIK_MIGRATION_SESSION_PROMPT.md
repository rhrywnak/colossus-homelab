# Session Prompt: Authentik Migration Execution

## Context

I'm Roman, building the Colossus homelab infrastructure. We're migrating from Authelia to Authentik for centralized authentication across all `*.cogmai.com` services. The migration design is complete and ready for execution.

## What's Done

**Stages 1–4 (infrastructure):** DNS (`auth.cogmai.com → 10.10.100.55`), Cloudflare Tunnel route, Traefik ForwardAuth middleware, and `forwardedHeaders.trustedIPs` fix are all deployed and working. These carry forward unchanged.

**Authelia (CT-316)** is running on pve-3 at 10.10.100.58 and protecting all routes. It works, but lacks admin UI, forced password changes, and self-service password management — unacceptable for multi-user operation.

**Design documents created:**
- `COLOSSUS_AUTHENTIK_MIGRATION_DESIGN_v1.md` — full architecture (VM spec, Quadlet containers, Traefik integration, app contract)
- `COLOSSUS_AUTH_EXECUTION_TASK_TRACKER_v2.md` — staged task tracker
- `COLOSSUS_LEGAL_AUTHELIA_INTEGRATION_GUIDE_v1.md` — app integration contract (needs header name updates for Authentik)
- `AUTHENTIK_MIGRATION_SESSION_TRANSITION.md` — detailed session transition from last session

All documents are in Project knowledge. Read the migration design and task tracker before starting.

## What's Next — Execute in Order

**Stage 5A: Create VM-316 on pve-3**
- ZFS datasets: `pbs-zfs/services/authentik/{postgres,media,templates}`
- Proxmox directory resource mappings
- Butane config → Ignition (CoreOS VM with virtiofs mounts)
- VM: VMID 316, IP 10.10.100.58, 2 cores, 2048MB RAM, 20GB disk

**Stage 5B: Deploy containers via Quadlet**
- PostgreSQL (data on virtiofs `/data/postgres`)
- Authentik server (port 9000)
- Authentik worker
- No Redis needed (removed in Authentik 2025.10)

**Stage 5C: Configure via admin UI**
- Proxy provider: domain-level forward auth, cookie domain `cogmai.com`
- Groups: admin, legal_editor, legal_viewer, ai_user
- User: roman (admin + legal_editor + ai_user), temporary password with forced change

**Stage 5D: Traffic switchover (~15 min downtime)**
- Stop CT-316 (Authelia)
- Update Traefik: ForwardAuth URL → `http://10.10.100.58:9000/outpost.goauthentik.io/auth/traefik`
- Update headers: `Remote-User` → `X-authentik-username`, etc.
- Add outpost router for `/outpost.goauthentik.io/` callback path
- Test internal + external access

**Stage 5E: Cleanup**
- Destroy CT-316 and Authelia ZFS datasets
- Update Ansible inventory, monitoring, PBS backups

**Stages 6–7: Application code** (backend header names + frontend logout URL)
**Stage 8: Remove API auth_bypass** from Traefik routes

## Key Technical Details

- Colossus follows CoreOS + Podman Quadlet for VMs, native services for LXC
- Golden rule: no persistent data inside containers — everything on ZFS via virtiofs
- All automation in `colossus-ansible` repo, provisioning scripts in `colossus-homelab`
- PROD backend (VM-120) is at v0.3.2, healthy, RUST_LOG=warn
- DEV backend (VM-220) is at v0.3.2, healthy, RUST_LOG=info
- External access: `https://colossus-legal.cogmai.com` via Cloudflare Tunnel → Traefik → Auth → App

## Known Issues to Keep in Mind
1. Traefik static config (`traefik.yml`) not managed by Ansible — only in provisioning script
2. PROD backend doesn't handle SIGTERM gracefully (gets SIGKILL after 10s timeout)
3. CT-315 Semaphore has storage violation (persistent data inside container) — backlog item
4. API routes have `auth_bypass: true` — must be removed after Stage 7

## Start Here

Read the migration design doc from Project knowledge, then let's execute Stage 5A.
