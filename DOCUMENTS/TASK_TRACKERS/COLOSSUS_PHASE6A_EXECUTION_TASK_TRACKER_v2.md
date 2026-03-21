# COLOSSUS — Phase 6A Monitoring Stack — Execution Task Tracker v2.0

**Updated:** 2026-02-16 (Phase 6A-2 complete)
**Use this as a living checklist.**
- Add notes in the "Operator Notes" column as you execute.
- When complete, mark ✅ and add completion date/time.
- Do NOT skip safety gates or checkpoints.

**Scope:** VM-314 provisioning (CoreOS + Podman Quadlet) → core monitoring stack → Alloy agents on all hosts → application metrics → UniFi syslog → dashboards → PBS backups → documentation closeout.

**Design Document:** `COLOSSUS_MONITORING_STACK_DESIGN_v2.md`
**Ansible Control Node:** proxima-centauri (10.10.0.99)
**Project Directory:** `~/colossus-ansible/`

---

## 0. Pre-Flight Safety Gates

| Gate | Requirement | Status | Operator Notes |
|------|-------------|:------:|----------------|
| G0.1 | Phases 1–5B locked and stable | ✅ | Verified 2026-02-15 |
| G0.2 | `ansible all -m ping` succeeds for all 11 hosts | ✅ | All 11 responding |
| G0.3 | pve-3 has sufficient capacity (~4GB RAM, 60GB disk free) | ✅ | Confirmed |
| G0.4 | CoreOS QCOW2 template available on pve-3 | ✅ | Copied from pve-2 |
| G0.5 | Ansible Vault password file present at `~/.vault_pass` | ✅ | |
| G0.6 | `butane` CLI installed on proxima-centauri | ✅ | |
| G0.7 | colossus-ansible repo clean (`git status`) | ✅ | |
| G0.8 | Console access to pve-3 available (out-of-band recovery) | ✅ | |

---

## Phase 6A-1: Core Stack (VM-314) — ✅ COMPLETE (2026-02-15)

### ✅ CHECKPOINT 1 & 2 PASSED

All tasks completed. See `PHASE6A_1_SESSION_TRANSITION.md` for full details.
- VM-314 deployed: 6 containers running (Prometheus, Loki, Grafana, PVE Exporter, Alertmanager, Alloy)
- Prometheus scraping 3 PVE nodes + self
- Grafana accessible at `https://grafana.cogmai.com`
- Proxmox dashboard (10347) imported
- Clean destroy/rebuild validated (Butane v2.1)
- PBS backup job #9 configured
- 9 issues encountered and resolved, all baked into Butane v2.1
- Git committed and pushed

---

## Phase 6A-2: Alloy Agents (Per-Host) — ✅ COMPLETE (2026-02-16)

### 2A. Pre-Flight

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 2A.0a | Check CT-312 memory | If 256MB, bump to 512MB for Alloy headroom | ✅ | Was 256MB → bumped to 512MB via `pct set 312 -memory 512` |
| 2A.0b | Check CT-313 memory | If 256MB, bump to 512MB for Alloy headroom | ✅ | Was 256MB → bumped to 512MB via `pct set 313 -memory 512` |
| 2A.0c | Update vars files | ct-312-cloudflared.yml and ct-313-traefik.yml | ✅ | sed -i to update ct_memory values |
| 2A.0d | Decide on VM-200 | Frozen ref — deploy Alloy or skip? | ✅ | VM-200 planned for decommission; Alloy deployed anyway (in coreos_vms group) |

### 2B. Ansible Role Creation

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 2B.1 | Create `roles/alloy-agent/` structure | tasks, templates, defaults, handlers | ✅ | 8 files total |
| 2B.2 | Create Alloy config template | Jinja2 template with `alloy_containerized` flag for path differences | ✅ | `config.alloy.j2` — shared between APT and Podman paths |
| 2B.3 | Create `playbooks/deploy-alloy.yml` | Targets `all:!truenas:!monitoring` | ✅ | Supports `-l` for wave-based deployment |
| 2B.4 | Handle host type differences | APT for Debian/Proxmox/PBS, Podman for CoreOS | ✅ | `alloy_containerized` auto-set from `coreos_vms` group membership |

### 2C. Wave 1 — LXC Container Agents (CT-311, CT-312, CT-313)

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 2C.1 | Deploy Alloy to CT-311 (Pi-hole) | APT install + systemd | ✅ | First host tested; readiness check needed 1 retry (normal) |
| 2C.2 | Deploy Alloy to CT-312 (cloudflared) | APT install + systemd | ✅ | |
| 2C.3 | Deploy Alloy to CT-313 (Traefik) | APT install + systemd | ✅ | |
| 2C.4 | Verify CT agents in Prometheus targets | 3 new targets showing UP at `:12345` | ✅ | Confirmed via Prometheus API |
| 2C.5 | Verify CT logs in Loki | Grafana Explore → `{host="pihole"}`, etc. | ✅ | Confirmed via Loki label API |

### 2D. Wave 2 — Proxmox Node Agents + PBS

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 2D.1 | Deploy Alloy to pve-1 | APT install + systemd | ✅ | **Issue:** apt 401 from enterprise repo. Fixed by adding `Enabled: no` to `pve-enterprise.sources` |
| 2D.2 | Deploy Alloy to pve-2 | APT install + systemd | ✅ | Enterprise repo already disabled |
| 2D.3 | Deploy Alloy to pve-3 | APT install + systemd | ✅ | Enterprise repo already disabled |
| 2D.4 | Deploy Alloy to PBS (VM-900) | APT install + systemd | ✅ | **Issue:** Same 401 + missing no-subscription repo. Created `pbs-no-subscription.sources` |
| 2D.5 | Verify PVE+PBS agents in Prometheus | 4 targets showing UP at `:12345` | ✅ | |
| 2D.6 | Verify PVE+PBS logs in Loki | `{host="pve-1"}`, `{host="pbs"}`, etc. | ✅ | |

### 2E. Wave 3 — CoreOS VM Agents (VM-110, VM-120, VM-200, VM-220)

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 2E.1 | Deploy Alloy to VM-110 (PROD DB) | Podman Quadlet | ✅ | Required `User=0` + `SecurityLabelDisable=true` for journal access |
| 2E.2 | Deploy Alloy to VM-120 (PROD App) | Podman Quadlet | ✅ | Same fix applied |
| 2E.3 | Deploy Alloy to VM-200 (DEV DB frozen) | Podman Quadlet | ✅ | Deployed via coreos_vms group membership |
| 2E.4 | Deploy Alloy to VM-220 (DEV App) | Podman Quadlet | ✅ | Used as debugging target for issues #4–6 |
| 2E.5 | Verify CoreOS agents in Prometheus | 4 targets showing UP at `:12345` | ✅ | |
| 2E.6 | Verify CoreOS logs in Loki | Includes Podman container logs via journald | ✅ | |

### 2F. Fleet Validation

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 2F.1 | All 11 Alloy targets UP in Prometheus | `curl` Prometheus targets API → alloy job: 11/11 UP | ✅ | Zero errors across all targets |
| 2F.2 | Import Node Exporter Full dashboard (1860) | Grafana → Import → ID 1860 | ⬜ | Ready to import |
| 2F.3 | Verify host metrics for all hosts | Cycle through each host in dashboard dropdown | ⬜ | After dashboard import |
| 2F.4 | Verify log search across fleet | Loki label API → 11 hosts confirmed in `host` label values | ✅ | All 11 host names present |

**✅ CHECKPOINT 3: All 11 Alloy agents reporting. Metrics and logs flowing from every managed host.**

### 2G. Git Commit

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 2G.1 | Commit alloy-agent role + playbook + docs | `Phase 6A-2: Alloy agent deployment to all hosts` | ✅ | Committed as 98db1d1, 10 files, 418 insertions |
| 2G.2 | Push to GitHub | `git push origin master` | ✅ | Branch is `master`, not `main` |

---

## Phase 6A-3: Application Metrics + UniFi Syslog — ⬜ NOT STARTED

### 3A. Traefik Metrics

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 3A.1 | Update Traefik static config | Add `metrics.prometheus` section + port 8082 entrypoint (see design §4.4) | ⬜ | |
| 3A.2 | Run Traefik playbook | `ansible-playbook manage-traefik.yml` | ⬜ | |
| 3A.3 | Verify metrics endpoint | `curl http://10.10.100.55:8082/metrics` → Prometheus text format | ⬜ | |
| 3A.4 | Verify Prometheus scraping Traefik | Targets page → traefik job shows UP | ⬜ | |
| 3A.5 | Import Traefik dashboard (17346) | Grafana → Import → ID 17346 | ⬜ | |
| 3A.6 | Verify Traefik data in dashboard | Request rates, latency, backend status visible | ⬜ | |

### 3B. Pi-hole Metrics

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 3B.1 | Create `roles/pihole-exporter/` | Install pihole6_exporter Python service on CT-311 | ⬜ | |
| 3B.2 | Deploy pihole6_exporter | Run playbook | ⬜ | |
| 3B.3 | Verify exporter running | `curl http://10.10.100.53:9666/metrics` → Pi-hole metrics | ⬜ | |
| 3B.4 | Verify Prometheus scraping Pi-hole | Targets page → pihole job shows UP | ⬜ | |
| 3B.5 | Import Pi-hole dashboard (21043) | Grafana → Import → ID 21043 | ⬜ | |
| 3B.6 | Verify Pi-hole data in dashboard | Queries/sec, block rate, upstream latency visible | ⬜ | |

### 3C. UniFi Syslog

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 3C.1 | Verify Alloy syslog listener on VM-314 | `podman logs alloy` — listening on UDP 514 | ⬜ | |
| 3C.2 | Enable UniFi remote syslog | Settings → System → Remote Logging → `10.10.100.56:514` | ⬜ | **Manual in UniFi UI** |
| 3C.3 | Leave "debug logging" UNCHECKED | Prevents massive volume | ⬜ | |
| 3C.4 | Enable CyberSecure traffic logging | Settings → CyberSecure → Traffic Logging (UniFi 9.x) | ⬜ | **Manual in UniFi UI** |
| 3C.5 | Wait 5 minutes for logs to flow | Allow time for syslog events to accumulate | ⬜ | |
| 3C.6 | Verify UniFi logs in Loki | Grafana Explore → `{job="unifi"}` → results present | ⬜ | |
| 3C.7 | Verify firewall blocks present | `{job="unifi"} |= "BLOCK"` → results | ⬜ | |
| 3C.8 | Verify AP noise FILTERED OUT | `{job="unifi"} |= "hostapd"` → empty results | ⬜ | If results appear, check Alloy filter config |
| 3C.9 | Verify DHCP events KEPT | `{job="unifi"} |~ "(?i)(DHCPACK|DHCPOFFER)"` → results | ⬜ | |
| 3C.10 | Verify IDS/IPS events route | `{job="unifi"} |~ "(?i)(IDS|IPS|threat)"` → check | ⬜ | May be empty if no events; that's OK |

**✅ CHECKPOINT 4: Traefik + Pi-hole metrics flowing. UniFi syslog ingested with correct filtering.**

### 3D. Dashboards

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 3D.1 | Import Loki Logs Overview (13639) | Grafana → Import → ID 13639 | ⬜ | |
| 3D.2 | Build "Colossus Overview" custom dashboard | Row 1: Infra, Row 2: App, Row 3: DB, Row 4: UniFi, Row 5: Logs | ⬜ | See design §11.2 |
| 3D.3 | Test SSH event visibility | `{job="unifi"} |= "SSH"` or `|= "port 22"` in logs panel | ⬜ | |
| 3D.4 | Export all dashboards as JSON | Grafana → Dashboard → Share → Export | ⬜ | |
| 3D.5 | Save JSON to `grafana/dashboards/` in repo | Version-controlled dashboard definitions | ⬜ | |

### 3E. Git Commit

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 3E.1 | Commit pihole-exporter role + Traefik updates | `Phase 6A-3: Application metrics + UniFi syslog` | ⬜ | |
| 3E.2 | Commit exported dashboard JSON files | `Phase 6A-3: Grafana dashboard exports` | ⬜ | |
| 3E.3 | Push to GitHub | `git push origin main` | ⬜ | |

---

## Phase 6A-4: Validation + Closeout — ⬜ NOT STARTED

### 4A. Full Success Criteria

| ID | Criterion | Validation | Status | Operator Notes |
|----|-----------|------------|:------:|----------------|
| 4A.1 | Grafana accessible at `https://grafana.cogmai.com` | Browser test via Traefik | ✅ | Confirmed 6A-1 |
| 4A.2 | Proxmox dashboard — all 3 nodes | Dashboard 10347 | ✅ | Confirmed 6A-1 |
| 4A.3 | Host metrics — all 11 hosts | Dashboard 1860, cycle through dropdown | ⬜ | Dashboard import pending |
| 4A.4 | Traefik request metrics | Dashboard 17346 | ⬜ | Phase 6A-3 |
| 4A.5 | Pi-hole query metrics | Dashboard 21043 | ⬜ | Phase 6A-3 |
| 4A.6 | Logs from all hosts in Loki | `{job="systemd-journal"}` → 11 hosts | ✅ | Confirmed 6A-2 — all 11 hosts in Loki |
| 4A.7 | UniFi firewall logs (filtered) | `{job="unifi"} |= "BLOCK"` → results | ⬜ | Phase 6A-3 |
| 4A.8 | UniFi AP noise absent | `{job="unifi"} |= "hostapd"` → empty | ⬜ | Phase 6A-3 |
| 4A.9 | Colossus Overview dashboard | Single-pane with all 5 rows | ⬜ | Phase 6A-3 |
| 4A.10 | VM-314 in PBS backup schedule | Verify in PBS UI or `manage-pbs-backups.yml` | ✅ | Confirmed 6A-1 |
| 4A.11 | All config in Git | `git status` clean, all pushed | ⬜ | After 6A-2 commit |
| 4A.12 | VM-314 rebuildable from Ignition | Destroy + recreate test (optional but recommended) | ✅ | Validated 6A-1 |

### 4B. Documentation Closeout

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 4B.1 | Update `COLOSSUS_HOMELAB_MASTER_CONTEXT_v5.md` | Add Phase 6A, VM-314, monitoring, Alloy agents | ⬜ | → creates v6 |
| 4B.2 | Update `COLOSSUS_ANSIBLE_RUNBOOK_v2.md` | Add alloy-agent role, deploy-alloy playbook | ⬜ | → creates v3 |
| 4B.3 | Mark design doc phases complete | Update `COLOSSUS_MONITORING_STACK_DESIGN_v2.md` | ⬜ | |
| 4B.4 | Write Phase 6A session transition | For handoff to Phase 6B (Tailscale) | ⬜ | |
| 4B.5 | Final Git commit + push | `Phase 6A: Monitoring stack complete — documentation closeout` | ⬜ | |

**✅ CHECKPOINT 5 — PHASE 6A COMPLETE:** Full observability stack operational.
