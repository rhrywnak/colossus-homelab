# Colossus Homelab — Master Task Tracker

**Last Updated:** 2026-02-21
**Scope:** All infrastructure work across `colossus-homelab` and `colossus-ansible` repos
**Owner:** Roman Hrywnak

---

## Completed Phases (Reference Only)

| Phase | Scope | Completed | Notes |
|-------|-------|-----------|-------|
| Phase 1 | Backups & PBS | 2026-02-05 | 🔒 Locked |
| Phase 2 | DEV DB Externalization | 2026-02-08 | 🔒 Locked |
| Phase 3 | PROD DB Deployment | 2026-02-09 | 🔒 Locked |
| Phase 4A | Application Deployment | 2026-02-11 | 🔒 Locked |
| Phase 4B | Edge Services (DNS, Tunnel, Pi-hole) | 2026-02-11 | 🔒 Locked |
| Phase 5A | Traefik Reverse Proxy | 2026-02-12 | 🔒 Locked |
| TrueNAS | Backup Replication & Shared Storage | 2026-02-13 | ✅ Complete |
| Phase 5B-1 | Ansible Foundation | 2026-02-14 | ✅ Complete |
| Phase 6A | Monitoring Stack (Prometheus/Grafana/Loki) | 2026-02-16 | ✅ Complete (closeout pending) |
| Phase 7A | Semaphore UI & Neo4j Sync Automation | 2026-02-20 | ✅ Complete |
| App Deploy Pipeline | build-release.sh, deploy-app, Semaphore templates | 2026-02-21 | ✅ Complete |

---

## Open Tasks — High Priority

| ID | Task | Repo | Priority | Notes |
|----|------|------|----------|-------|
| HIGH-01 | Test Semaphore PROD deploy template | ansible | High | Created but never run — validate with next release |
| HIGH-02 | Fix `rollback-app.yml` — add `become: true` and `confirm_prod` | ansible | High | Will fail without these; same fixes as deploy-app.yml |
| HIGH-03 | Apply Master Context v6→v7 delta | homelab | High | Delta document created 2026-02-21; produce v7 |
| HIGH-04 | Commit documentation updates to both repos | both | High | Session transition, ANSIBLE-README, DEPLOYMENT.md, addendum |

---

## Open Tasks — Medium Priority

| ID | Task | Repo | Priority | Notes |
|----|------|------|----------|-------|
| MED-01 | Clean orphan containers after VM reboot | ansible | Medium | Old Butane configs use `colossus-legal-backend`; Ansible uses `colossus-backend`. Orphans may respawn on reboot of VM-120/VM-220 |
| MED-02 | Update Butane source files for app VMs | homelab | Medium | Change container names to match Ansible (`colossus-backend`/`colossus-frontend`), retranspile Ignition |
| MED-03 | Phase 6A-4 documentation closeout | both | Medium | Some items still ⬜ in Phase 6A tracker (dashboard exports, Ansible runbook v3, design doc updates) |
| MED-04 | Design automated version tagging system | ansible | Medium | Current workflow requires manual version input in Semaphore survey — prone to typos and inconsistencies. Design a system that derives version from git tags, commit SHAs, or a VERSION file to eliminate human error |
| MED-05 | Design and deploy build VM on pve-2 | homelab | Medium | Dedicated container build host to remove workstation as a dependency for image builds. Could be CoreOS VM or LXC with Podman. Enables Semaphore-triggered builds (full CI pipeline) |
| MED-06 | Install and configure Opik | homelab | Medium | Self-hosted LLM observability platform (github.com/comet-ml/opik). Needs: research deployment requirements, choose LXC vs VM, allocate resources (ClickHouse needs RAM), deploy via Ansible, add Traefik route (`opik.cogmai.com`), DNS, PBS backup |

---

## Open Tasks — Low Priority

| ID | Task | Repo | Priority | Notes |
|----|------|------|----------|-------|
| LOW-01 | Investigate `podman_login` module failure with ghcr.io | ansible | Low | Module returns 403; manual login works. Images are public — `ignore_errors` is fine |
| LOW-02 | Suppress "Junk after JSON data" Ansible warnings | ansible | Low | Cosmetic — OSC 8 terminal escapes from CoreOS bash. Already documented |
| LOW-03 | Make pve-1 ethtool offload changes persistent | homelab | Low | Add `post-up ethtool -K nic0 tso off gso off gro off` to `/etc/network/interfaces` |
| LOW-04 | Investigate pve-1 igc NIC root cause | homelab | Low | Research igc driver fixes in newer Proxmox kernels; evaluate ice NIC |
| LOW-05 | Configure CoreOS Zincati update strategy for PROD | homelab | Low | Set maintenance windows to prevent unexpected reboots on VM-110/VM-120 |
| LOW-06 | Decide fate of VM-200 (frozen reference) | homelab | Low | Can be shut down or destroyed — PROD/DEV parity proven, Alloy agent deployed |
| LOW-07 | Retire old COLOSSUS_HL_TASK_TRACKER.md | homelab | Low | Superseded by this document |
| LOW-08 | Document consolidation | homelab | Low | Too many session transition docs and design docs. Consider archiving completed phase docs |

---

## Backlog — Future Work

| ID | Task | Scope | Notes |
|----|------|-------|-------|
| FUT-01 | Tailscale mesh VPN | Infrastructure | Remote access without Cloudflare tunnel dependency |
| FUT-02 | Authentik SSO/identity provider | Infrastructure | Centralized authentication for Grafana, Semaphore, Opik, apps |
| FUT-03 | Cold/offline backup | Infrastructure | USB drive + ZFS send/recv for air-gapped 3-2-1 compliance |
| FUT-04 | NAS VLAN (10.10.40.0/24) | Infrastructure | Dedicated storage VLAN for TrueNAS traffic isolation |
| FUT-05 | Codify existing infrastructure as Ansible roles | Ansible | Roles: traefik-route, pihole-dns, coreos-app, pbs-backup, proxmox-vm, proxmox-lxc |
| FUT-06 | New VM/CT deployment checklist | Ansible | Standard operating procedure: DNS, Traefik, PBS, Alloy, Prometheus — so nothing gets missed |

---

## Dependency Map

```
MED-05 (Build VM) ──→ MED-04 (Version tagging) ──→ Full CI: Semaphore build + deploy
MED-06 (Opik)     ──→ FUT-02 (Authentik) for SSO (optional, can deploy without)
MED-01 (Orphan cleanup) ──→ MED-02 (Update Butane files) — permanent fix
HIGH-02 (Fix rollback) ──→ HIGH-01 (Test PROD template) — rollback should work before relying on PROD deploys
```

---

## Task Log (Recently Completed)

| ID | Task | Completed | Notes |
|----|------|-----------|-------|
| — | Rewrite build-release.sh | 2026-02-21 | Correct paths, registry, build context |
| — | Regenerate GitHub PAT, rebuild Ansible vault | 2026-02-21 | Old token expired, vault password lost |
| — | Restructure vault to group_vars/all/ | 2026-02-21 | Ansible auto-loading fix |
| — | Add dev/prod inventory groups | 2026-02-21 | Environment detection for deploy pipeline |
| — | Fix deploy-app.yml (become, login, pause) | 2026-02-21 | CoreOS root, ghcr.io workaround, Semaphore compat |
| — | Fix API URLs and CORS for Traefik routing | 2026-02-21 | Mixed content blocking resolved |
| — | Build and deploy v0.2.0 to DEV and PROD | 2026-02-21 | Both environments validated |
| — | Create Semaphore deploy templates (DEV + PROD) | 2026-02-21 | DEV tested; PROD created |
| — | Create colossus-homelab GitHub repo | 2026-02-21 | rhrywnak/colossus-homelab |

---

## Notes

- `colossus-ansible` is treated as a sub-project of `colossus-homelab`
- Application repos (`colossus-legal`, etc.) have their own tracking — not covered here
- This tracker covers infrastructure, automation, and platform work only
- Task IDs are stable — completed tasks move to the log, IDs are not reused
