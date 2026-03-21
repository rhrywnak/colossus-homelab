# Phase 6A-2 Session Transition — Alloy Agents Deployed

**Date:** 2026-02-16
**Phase:** 6A-2 — Observability (Alloy Agent Fleet Deployment)
**Status:** ✅ PHASE 6A-2 COMPLETE — Checkpoint 3 passed (11/11 agents UP)
**Next Phase:** 6A-3 — Traefik metrics, Pi-hole exporter, UniFi syslog, dashboards
**Follow-on:** 6A-4 — Validation & closeout → Phase 6B (Tailscale)
**Previous Transition:** Phase 6A-1 (2026-02-15) — Core monitoring stack on VM-314

---

## 1. What Was Accomplished This Session

### 1.1 Alloy Agent Deployment (6A-2)

| Task | Status |
|------|--------|
| Pre-flight: bumped CT-312 (cloudflared) memory 256MB → 512MB | ✅ |
| Pre-flight: bumped CT-313 (Traefik) memory 256MB → 512MB | ✅ |
| Pre-flight: VM-200 marked for decommission (skipped for Alloy) | ✅ |
| Updated vars/ct-312-cloudflared.yml and vars/ct-313-traefik.yml | ✅ |
| Created `alloy-agent` Ansible role (8 files) | ✅ |
| Created `playbooks/deploy-alloy.yml` | ✅ |
| Wave 1: Deployed Alloy to CT-311, CT-312, CT-313 (APT) | ✅ |
| Wave 2: Deployed Alloy to pve-1, pve-2, pve-3, PBS (APT) | ✅ |
| Wave 3: Deployed Alloy to VM-110, VM-120, VM-200, VM-220 (Podman Quadlet) | ✅ |
| All 11 Alloy targets UP in Prometheus (0 errors) | ✅ |
| All 11 hosts shipping logs to Loki | ✅ |
| Node Exporter Full dashboard (ID 1860) ready to import | ✅ |

### 1.2 Issues Encountered and Resolved

| # | Issue | Root Cause | Resolution |
|---|-------|-----------|------------|
| 1 | `--check` mode fails on APT install | APT repo added in check mode is simulated, not real — package not found | Expected limitation; run live against single host first |
| 2 | pve-1 `apt update` 401 Unauthorized | Proxmox enterprise repo enabled without subscription (`pve-enterprise.sources`) | Added `Enabled: no` to enterprise sources file |
| 3 | PBS same 401 + missing free repo | Enterprise repo enabled, no-subscription repo not present | Disabled enterprise, created `pbs-no-subscription.sources` |
| 4 | CoreOS: Alloy container "permission denied" reading journal | Container runs as non-root by default; `/var/log/journal` owned by root:systemd-journal | Added `User=0` to Quadlet `.container` unit |
| 5 | CoreOS: Still "permission denied" with User=0 | SELinux on CoreOS blocks container access to host journal even as root | Added `SecurityLabelDisable=true` to Quadlet unit |
| 6 | CoreOS: `daemon-reload` timeout during Ansible handler | systemd stuck processing previously failed alloy units | Manual `systemctl reset-failed` + `daemon-reload` + `start` on all 4 VMs |

### 1.3 Lessons Learned

| # | Lesson |
|---|--------|
| 1 | `--check` mode is unreliable for first-time APT repo + install combos — test live on a single low-risk host instead |
| 2 | Proxmox 8.x (trixie) uses DEB822 `.sources` format, not traditional `.list` — look for `pve-enterprise.sources` not `.list` |
| 3 | All Proxmox hosts should have enterprise repo disabled consistently — pve-1 was the odd one out |
| 4 | PBS needs its own `pbs-no-subscription.sources` separate from PVE's — different repo path |
| 5 | Containerized Alloy on CoreOS needs both `User=0` AND `SecurityLabelDisable=true` for journal access |
| 6 | Quadlet `User=0` translates to `--user 0` in podman run; `SecurityLabelDisable=true` translates to `--security-opt label=disable` |
| 7 | When systemd gets stuck on failed units, `reset-failed` before `daemon-reload` clears the jam |
| 8 | Wave-based deployment with `-l` group targeting is effective — catches issues early on low-risk hosts |
| 9 | "Module invocation had junk after JSON data" warnings on CoreOS are cosmetic — caused by Python version/locale mismatch |
| 10 | Future Ansible role idea: standardize Proxmox APT repo config across all nodes (enterprise disabled, no-subscription enabled) |

### 1.4 Pre-flight Changes Made

| Change | Detail |
|--------|--------|
| CT-312 memory | 256MB → 512MB (live + vars file updated) |
| CT-313 memory | 256MB → 512MB (live + vars file updated) |
| pve-1 enterprise repo | `Enabled: no` added to `/etc/apt/sources.list.d/pve-enterprise.sources` |
| PBS enterprise repo | `Enabled: no` added to `/etc/apt/sources.list.d/pbs-enterprise.sources` |
| PBS no-subscription repo | Created `/etc/apt/sources.list.d/pbs-no-subscription.sources` |
| VM-200 | Planned for decommission — Alloy still deployed (came with `coreos_vms` group) |

---

## 2. Current State of Infrastructure

### 2.1 Completed Phases

| Phase | Status | Date |
|-------|--------|------|
| Phase 1 — Backups & PBS | 🔒 Locked | 2026-02-05 |
| Phase 2 — DEV DB Externalization | 🔒 Locked | 2026-02-08 |
| Phase 3 — PROD DB Deployment | 🔒 Locked | 2026-02-09 |
| Phase 4A — Application Deployment | 🔒 Locked | 2026-02-10 |
| Phase 4B — Edge Services (DNS, Cloudflare) | 🔒 Locked | 2026-02-10 |
| Phase 5A — Traefik + Cloudflare Integration | 🔒 Locked | 2026-02-11 |
| Phase 5B-1 — Ansible Foundation | 🔒 Locked | 2026-02-12 |
| Phase 5B-2 — Infrastructure Roles + GitHub | 🔒 Locked | 2026-02-14 |
| Phase 5 — TrueNAS Integration | 🔒 Locked | 2026-02-13 |
| Phase 6A Design — Monitoring Stack | 🔒 Locked | 2026-02-14 |
| Phase 6A-1 — Core Monitoring Stack | 🔒 Locked | 2026-02-15 |
| **Phase 6A-2 — Alloy Agent Deployment** | **✅ Complete** | **2026-02-16** |

### 2.2 Live Infrastructure

```
pve-1 (PROD)              pve-2 (DEV)               pve-3 (Infra)
├── VM-110 PROD DB         ├── VM-200 Frozen ref †    ├── VM-900 PBS
├── VM-120 PROD App        ├── VM-210 DEV DB          ├── CT-311 Pi-hole
                           ├── VM-220 DEV App         ├── CT-312 cloudflared
                                                      ├── CT-313 Traefik
                                                      └── VM-314 Monitoring

† VM-200 planned for decommission
All hosts except TrueNAS now run Grafana Alloy agents
```

### 2.3 Monitoring Targets — Current State

| Target | Count | Status | Notes |
|--------|-------|--------|-------|
| prometheus (self) | 1 | ✅ UP | localhost:9090 |
| proxmox × 3 (via PVE Exporter) | 3 | ✅ UP | pve-1, pve-2, pve-3 |
| alloy × 11 (all hosts) | 11 | ✅ UP | **NEW — deployed this session** |
| traefik | 1 | ⬜ DOWN | Metrics endpoint not enabled yet (Phase 6A-3) |
| pihole | 1 | ⬜ DOWN | Exporter not installed yet (Phase 6A-3) |

### 2.4 Alloy Agent Fleet

| Host | IP | Method | Port | Status |
|------|----|--------|------|--------|
| pve-1 | 10.10.100.3 | APT | 12345 | ✅ UP |
| pve-2 | 10.10.100.2 | APT | 12345 | ✅ UP |
| pve-3 | 10.10.100.5 | APT | 12345 | ✅ UP |
| pihole (CT-311) | 10.10.100.53 | APT | 12345 | ✅ UP |
| cloudflared (CT-312) | 10.10.100.54 | APT | 12345 | ✅ UP |
| traefik (CT-313) | 10.10.100.55 | APT | 12345 | ✅ UP |
| pbs (VM-900) | 10.10.100.242 | APT | 12345 | ✅ UP |
| colossus-prod-db1 (VM-110) | 10.10.100.110 | Podman Quadlet | 12345 | ✅ UP |
| colossus-prod-app1 (VM-120) | 10.10.100.120 | Podman Quadlet | 12345 | ✅ UP |
| colossus-dev-db1 (VM-200) | 10.10.100.200 | Podman Quadlet | 12345 | ✅ UP |
| colossus-dev-app1 (VM-220) | 10.10.100.220 | Podman Quadlet | 12345 | ✅ UP |

### 2.5 Loki Log Sources

All 11 hosts confirmed shipping `{job="systemd-journal"}` logs with labels: `host`, `unit`, `priority`, `transport`.

### 2.6 Ansible State

- **Control node:** proxima-centauri (10.10.0.99)
- **Project:** `~/colossus-ansible/`
- **Git remote:** https://github.com/rhrywnak/colossus-ansible (private)
- **Vault:** `~/.vault_pass` (auto-decrypt), whole-file vault at `secrets/vault.yml`
- **Managed hosts:** 11 (all responding)
- **Roles:** 8 (+1: alloy-agent)
- **Playbooks:** 10 (+1: deploy-alloy.yml)
- **Last commit:** 98db1d1 — "Phase 6A-2: Alloy agent deployment to all managed hosts"
- **Git branch:** `master` (not `main`)
- **DNS records:** 13 (via pihole-dns)
- **Traefik routes:** 6 (2 external)
- **PBS backup jobs:** 9

### 2.7 alloy-agent Role Structure

```
roles/alloy-agent/
├── defaults/main.yml           ← Shared variables (Loki URL, port, image tag)
├── handlers/main.yml           ← Restart handlers (systemd vs podman quadlet)
├── tasks/
│   ├── main.yml                ← Entry point — routes by group membership
│   ├── install-apt.yml         ← Debian: GPG key → repo → install → config → start
│   └── install-podman.yml      ← CoreOS: config → Quadlet unit → pull → start
└── templates/
    ├── config.alloy.j2         ← Shared config (containerized flag for path differences)
    └── alloy.container.j2      ← Quadlet unit (User=0 + SecurityLabelDisable=true)
```

---

## 3. Documents Produced This Session

| Document | Location | Purpose |
|----------|----------|---------|
| `PHASE6A_2_SESSION_TRANSITION.md` | Project knowledge | This document |
| `COLOSSUS_PHASE6A_EXECUTION_TASK_TRACKER_v2.md` | Project knowledge | Updated tracker with 6A-2 complete |
| `COLOSSUS_ANSIBLE_RUNBOOK_ADDENDUM_6A2.md` | Project knowledge | alloy-agent role documentation |

---

## 4. What's Next — Phase 6A-3: Application Metrics + UniFi Syslog

### 4.1 Scope

Enable application-specific metrics exporters and UniFi syslog ingestion with noise filtering.

### 4.2 Tasks

| Step | Task | Method |
|------|------|--------|
| 1 | Enable Traefik Prometheus metrics endpoint | Update Traefik static config, add port 8082 entrypoint |
| 2 | Install pihole6_exporter on CT-311 | New `pihole-exporter` Ansible role |
| 3 | Enable UniFi remote syslog to VM-314 | Manual: UniFi Settings → System → Remote Logging → `10.10.100.56:514` |
| 4 | Enable CyberSecure traffic logging | Manual: UniFi Settings → CyberSecure → Traffic Logging |
| 5 | Verify filtering (noise dropped, security kept) | Loki queries: `{job="unifi"} |= "BLOCK"` and `|= "hostapd"` |
| 6 | Import dashboards: Traefik (17346), Pi-hole (21043), Node Exporter Full (1860) | Grafana → Import |
| 7 | Build custom "Colossus Overview" dashboard | Single-pane with Infrastructure, App, DB, Network, Logs rows |
| 8 | Export dashboards as JSON to Git | `grafana/dashboards/` in ansible repo |

### 4.3 Expected Outcome

- Traefik request metrics visible in dashboard
- Pi-hole query/block metrics visible in dashboard
- UniFi firewall blocks searchable in Loki
- UniFi AP noise absent from Loki
- Colossus Overview dashboard providing single-pane view

---

## 5. Known Issues Carried Forward

| Issue | Impact | Workaround |
|-------|--------|------------|
| pve-1 igc NIC intermittent SSH drops | Ansible tasks can stall | SSH multiplexing in `~/.ssh/config` |
| ethtool offload changes not persistent on pve-1 | Revert on reboot | Needs `/etc/network/interfaces` entry |
| colossus-legal-dev.cogmai.com DNS drift | Points to VM not Traefik | Documented in runbook |
| CoreOS Zincati auto-updates on PROD | Unexpected reboots | Need maintenance window strategy |
| Workstation uses UDM resolver, not Pi-hole | Need `/etc/hosts` for internal FQDNs | Entries added manually |
| `GF_SECURITY_COOKIE_SECURE=false` | Grafana cookies not secure over HTTP | Will re-enable after confirming HTTPS-only |
| Proxmox enterprise repo inconsistency | pve-1 had it enabled; others had it disabled | Fixed manually; consider Ansible role for consistency |
| CoreOS "junk after JSON data" warnings | Cosmetic Ansible warnings on CoreOS hosts | Harmless; caused by Python version/locale mismatch |
| VM-200 still in inventory | Planned for decommission | Remove from inventory after decommission |

---

## 6. Roadmap

| Phase | Scope | Priority |
|-------|-------|----------|
| **6A-3** | Traefik metrics, pihole6_exporter, UniFi syslog, dashboards | **Next session** |
| **6A-4** | Validation & closeout, documentation | After 6A-3 |
| **6B** | Tailscale mesh VPN — remote access | After 6A |
| **Colossus-AI** | Rust/Axum LLM application | Application priority |

---

## 7. Session Start Prompt

```
We are resuming the Colossus Proxmox homelab project.

Phases 1–5B are complete and locked. Phase 6A-1 (core monitoring stack) was
completed on 2026-02-15. Phase 6A-2 (Alloy agent deployment) was completed
on 2026-02-16.

Current state:
- VM-314 on pve-3: CoreOS + Podman Quadlet, 6 containers running
  (Prometheus, Loki, Grafana, PVE Exporter, Alertmanager, Alloy)
- Prometheus scraping 3 PVE nodes + self + 11 Alloy agents (15/15 UP)
- Grafana accessible at https://grafana.cogmai.com via Traefik
- All 11 managed hosts shipping metrics and logs via Alloy
- Loki receiving journal logs from all 11 hosts
- alloy-agent Ansible role operational (APT + Podman Quadlet paths)
- All config committed and pushed to GitHub

Remaining targets DOWN (expected — not yet configured):
- traefik metrics — Phase 6A-3
- pihole exporter — Phase 6A-3
- UniFi syslog — Phase 6A-3

Ready to begin Phase 6A-3: Application metrics + UniFi syslog.
Tasks:
1. Enable Traefik Prometheus metrics endpoint (port 8082)
2. Install pihole6_exporter on CT-311 (new Ansible role)
3. Configure UniFi remote syslog to VM-314 (manual in UniFi UI)
4. Import dashboards: Node Exporter Full (1860), Traefik (17346), Pi-hole (21043)
5. Build custom "Colossus Overview" dashboard

Reference docs in project knowledge:
- COLOSSUS_MONITORING_STACK_DESIGN_v2.md
- COLOSSUS_PHASE6A_EXECUTION_TASK_TRACKER_v2.md
- PHASE6A_2_SESSION_TRANSITION.md

Ansible control node: proxima-centauri (10.10.0.99)
Project directory: ~/colossus-ansible/
```
