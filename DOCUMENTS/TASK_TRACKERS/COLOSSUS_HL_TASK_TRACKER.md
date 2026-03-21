# Colossus Homelab — Task Tracker

**Last Updated:** 2026-02-09  
**Purpose:** Single view of all outstanding work items across the project

---

## Completed Phases (Reference Only)

| Phase | Status | Completed |
|-------|--------|-----------|
| Phase 1 — Backups & PBS | 🔒 Locked | 2026-02-05 |
| Phase 2 — DEV DB Externalization | 🔒 Locked | 2026-02-08 |
| Phase 3 — PROD DB Deployment | 🔒 Locked | 2026-02-09 |

---

## Open Tasks

### Infrastructure Maintenance

| ID | Task | Priority | Target | Notes |
|----|------|----------|--------|-------|
| INFRA-01 | Make pve-1 ethtool offload changes persistent | Medium | This week | Add `post-up ethtool -K nic0 tso off gso off gro off` to `/etc/network/interfaces` |
| INFRA-02 | Investigate pve-1 igc NIC root cause | Low | This week | Research igc driver fixes in newer Proxmox kernels; evaluate ice NIC as alternative |
| INFRA-03 | Configure CoreOS Zincati update strategy for PROD | Medium | This week | Set maintenance windows to prevent unexpected reboots on VM-110 |
| INFRA-04 | Configure CoreOS Zincati update strategy for DEV | Low | This week | Less critical — DEV can tolerate surprise reboots |

### Edge Services & DNS

| ID | Task | Priority | Target | Notes |
|----|------|----------|--------|-------|
| EDGE-01 | Choose and register public domain | — | Not scheduled | Prerequisite for all edge work |
| EDGE-02 | Set up Cloudflare account + add domain | — | Not scheduled | After EDGE-01 |
| EDGE-03 | Configure UDM VLAN DNS split (family vs lab) | — | Not scheduled | Family VLAN must not depend on Pi-hole |
| EDGE-04 | Deploy Pi-hole on pve-3 | — | Not scheduled | Lab DNS server |
| EDGE-05 | Deploy Edge VM on pve-3 (cloudflared) | — | Not scheduled | Cloudflare Tunnel connector |
| EDGE-06 | Configure Cloudflare Tunnel + Access policies | — | Not scheduled | After EDGE-05 |
| EDGE-07 | Implement split-horizon DNS | — | Not scheduled | Internal overrides in Pi-hole |
| EDGE-08 | Validation + rollback plan | — | Not scheduled | Full test suite per design doc |

See `COLOSSUS_EDGE_DNS_CLOUDFLARE_EXECUTION_TASK_TRACKER_v1.0.md` for detailed subtasks.

### Management Services (Future)

| ID | Task | Priority | Target | Notes |
|----|------|----------|--------|-------|
| MGMT-01 | Authentik (SSO/identity) | — | Not scheduled | |
| MGMT-02 | Reverse proxy | — | Not scheduled | May be bundled with edge work |
| MGMT-03 | Monitoring + logging (Grafana/Prometheus) | — | Not scheduled | |

### Housekeeping

| ID | Task | Priority | Target | Notes |
|----|------|----------|--------|-------|
| HK-01 | Decide fate of VM-200 (frozen reference) | Low | After confidence period | Can be shut down or destroyed once PROD is trusted |
| HK-02 | Set up scheduled DEV backups (VM-210) | Low | — | Currently manual only |
| HK-03 | Verify PBS retention policy is active | Low | — | Confirm prune jobs are running |

---

## Task Log (Completed)

| ID | Task | Completed | Notes |
|----|------|-----------|-------|
| — | Phase 1: PBS deployment | 2026-02-05 | |
| — | Phase 2: DEV DB externalization | 2026-02-08 | |
| — | Phase 3: PROD DB deployment | 2026-02-09 | |
| — | Phase 3: PBS backup for VM-110 | 2026-02-09 | First backup + daily schedule |
| — | Phase 3: Validation + reboot test | 2026-02-09 | All checks passed |
| — | SSH multiplexing config on workstation | 2026-02-09 | Workaround for igc NIC |

---

## Notes

- INFRA tasks are independent and can be done in any order
- EDGE tasks have dependencies (must be done in sequence)
- MGMT tasks are not yet designed — need design docs before execution
- This tracker supplements, not replaces, the Edge DNS detailed tracker
