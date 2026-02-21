# Session Transition Prompt — Phase 5B-2: Codify Existing Infrastructure

Paste the following into a new Claude session:

---

## Context

I'm Roman, building the "Colossus" homelab — a three-node Proxmox cluster running containerized services. The project knowledge in this Claude Project contains all authoritative documentation. The canonical reference is **COLOSSUS_HOMELAB_MASTER_CONTEXT_v5.md**.

## Completed Phases

| Phase | What | Date |
|-------|------|------|
| 1 | Backups & PBS | 2026-02-05 |
| 2 | DEV DB externalization (VM-210) | 2026-02-08 |
| 3 | PROD DB deployment (VM-110) | 2026-02-09 |
| 4A | App deployment (VM-120/220) | 2026-02-11 |
| 4B | Edge services (Pi-hole, Cloudflare Tunnel) | 2026-02-11 |
| 5A | Traefik reverse proxy (CT-313) | 2026-02-12 |
| TrueNAS | PBS replication, ISO library, ZFS snapshots | 2026-02-13 |
| 5B-1 | **Ansible foundation** — SSH keys, inventory, vault, validation | 2026-02-14 |

## Current Infrastructure

**Proxmox cluster:** pve-1 (PROD), pve-2 (DEV), pve-3 (Infra/PBS)  
**VMs:** VM-110 (prod-db), VM-120 (prod-app), VM-210 (dev-db), VM-220 (dev-app) — all Fedora CoreOS 43  
**LXCs:** CT-311 (Pi-hole), CT-312 (cloudflared), CT-313 (Traefik) — all Debian 12 on pve-3  
**PBS:** VM-900 on pve-3, syncs to TrueNAS (10.10.0.38) daily at 02:00  
**Ansible control node:** proxima-centauri (workstation, 10.10.0.99)

## Ansible State (Phase 5B-1 Complete)

- **Project:** `~/colossus-ansible/`
- **Inventory:** `inventory/hosts.yml` — 11 hosts (10 managed + TrueNAS unmanaged)
- **Groups:** proxmox, coreos_vms (db_vms + app_vms), infrastructure, backup, storage
- **Vault:** `secrets/vault.yml` (auto-decrypt via `~/.vault_pass`)
- **Validation:** `ansible-playbook playbooks/gather-facts.yml` → 11/11 ok, changed=0, forks=10
- **SSH:** Key auth to all hosts, multiplexing enabled for 10.10.100.* (ControlPersist 120s)
- **UniFi IPS:** Detection exclusions added for 10.10.100.0/24 and 10.10.0.0/24

## Today's Goal: Phase 5B-2 — Codify Existing Infrastructure

Convert existing manual processes into Ansible roles. Don't deploy anything new — make the current state reproducible.

### Roles to Create (Priority Order)

| Role | Codifies | Why First |
|------|----------|-----------|
| `traefik-route` | Adding routers/services to Traefik dynamic config | Most frequently needed for new apps |
| `pihole-dns` | Adding DNS records to Pi-hole | Needed for every new app |
| `coreos-app` | Deploying Quadlet containers + env files to CoreOS | Core deployment pattern |
| `pbs-backup` | Creating PBS backup jobs | Medium priority |
| `proxmox-vm` | Creating CoreOS VMs via qm | Medium priority |
| `proxmox-lxc` | Creating LXC containers | Medium priority |

### Success Criteria

1. All roles created with tasks, defaults, and templates
2. Running each role against current infrastructure produces `changed=0` (current state matches)
3. Each role is idempotent (run twice → no changes)
4. Each role supports `--check --diff` (dry-run capability)

### Design Reference

The Ansible automation design is in **COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md** (project knowledge). It describes the application-as-YAML-variable pattern where apps are defined as variable files consumed by reusable playbooks.

### Key Technical Details

- **Traefik config:** `/etc/traefik/dynamic/services.yml` on CT-313 (hot-reload, no restart needed)
- **Pi-hole DNS:** Managed via web UI → Settings → All Settings → `dns.hosts` (Pi-hole v6)
- **CoreOS apps:** Quadlet `.container` files in `/etc/containers/systemd/`, env files in `/var/home/core/colossus/`
- **PBS backups:** Jobs configured in `/etc/pve/jobs.cfg` (cluster-wide)
- **CoreOS VMs:** Created via `qm` CLI with q35 machine type, virtiofs mounts, Ignition snippets
- **LXC containers:** Created via `pct` CLI with two-script pattern

## Documents to Reference

- `COLOSSUS_HOMELAB_MASTER_CONTEXT_v5.md` — Canonical project reference
- `COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md` — Ansible automation design
- `COLOSSUS_ANSIBLE_FOUNDATION_RUNBOOK_v1.md` — Phase 5B-1 operational procedures
- `PHASE5B1_SESSION_TRANSITION.md` — Previous session record

Let's start with the `traefik-route` role. Please read the Ansible design document and master context first, then we'll work through the implementation.
