# COLOSSUS — TrueNAS Monitoring Technical Plan (Phase 6A-3 Addition)

**Date:** 2026-02-16
**Applies to:** COLOSSUS_PHASE6A_EXECUTION_TASK_TRACKER_v2.md — Section 3 (Phase 6A-3)
**Purpose:** Add TrueNAS monitoring to the Phase 6A-3 scope

---

## 1. Problem Statement

The TrueNAS appliance (TerraMaster F4-423) with 4× 4TB HDDs in RAID10 is a critical
storage component — it holds PBS backup replicas and the ISO/template library. The drives
are aging and need proactive monitoring. Currently we have zero visibility into:

- Drive health (SMART attributes, error counts, reallocated sectors)
- Disk temperatures (HDDs in an enclosed NAS chassis run hot)
- Pool health (degraded mirrors, scrub results)
- ZFS ARC cache efficiency
- CPU/memory usage (affects NFS performance)
- Storage capacity trends
- Backup sync success/failure
- System-level errors (drive failures, pool events)

---

## 2. Architecture

Two data paths — no agents installed on TrueNAS, no SSH required:

```
┌──────────────────────────┐       ┌──────────────────────────────────────┐
│  TrueNAS (10.10.0.38)   │       │  VM-314 Monitoring (10.10.100.56)    │
│                          │       │                                      │
│  Netdata (built-in)      │       │  graphite_exporter container         │
│  ├── CPU, RAM, Network   │──TCP──▶  :9109 (Graphite in)                │
│  ├── Disk I/O, Temps     │ 2003  │  :9108 (Prometheus out)  ◀── Prom   │
│  └── ZFS ARC, Pool stats │       │                                      │
│                          │       │                                      │
│  graphite-smart-exporter │       │  (same graphite_exporter instance)   │
│  ├── SMART attributes    │──TCP──▶  :9109                               │
│  ├── Reallocated sectors │ 2003  │                                      │
│  ├── Pending sectors     │       │                                      │
│  ├── Power-on hours      │       │                                      │
│  └── Temperature history │       │                                      │
│                          │       │                                      │
│  Syslog (built-in)       │       │  Alloy syslog listener              │
│  ├── Drive errors        │──UDP──▶  :514 (syslog in)                   │
│  ├── Pool events         │       │  → Loki (logs)                      │
│  └── ZFS alerts          │       │                                      │
└──────────────────────────┘       └──────────────────────────────────────┘
```

**Key principle:** TrueNAS pushes everything to us. We don't touch the appliance
beyond configuring built-in export features in the web UI.

---

## 3. Components

### 3.1 graphite_exporter (new container on VM-314)

**Image:** `prom/graphite-exporter:latest`
**Ports:**
- 9109/TCP — Graphite receiver (TrueNAS pushes here via port mapping to 2003)
- 9108/TCP — Prometheus metrics endpoint (Prometheus scrapes here)

**Mapping file:** From [Supporterino/truenas-graphite-to-prometheus](https://github.com/Supporterino/truenas-graphite-to-prometheus)
— provides proper Prometheus label mapping for TrueNAS Netdata metrics.

**Port mapping note:** TrueNAS Graphite exporter sends to port 2003 by default.
The graphite_exporter container listens on 9109 internally. We publish 2003:9109
on VM-314 so TrueNAS can send to `10.10.100.56:2003`.

**Quadlet unit:** New file at `/etc/containers/systemd/graphite-exporter.container`
on VM-314 (added to monitoring.bu Butane config).

### 3.2 graphite-smart-exporter (cron script on TrueNAS)

**Source:** [Salvoxia/graphite-smart-exporter](https://github.com/Salvoxia/graphite-smart-exporter)
— A Python script that runs on TrueNAS, reads `smartctl` output, and pushes
tagged Graphite metrics to the same graphite_exporter endpoint.

**Why this approach:** TrueNAS CE 25.x stripped the SMART scheduling UI and only
monitors one attribute (uncorrected errors, ID 187). For aging drives, we need
comprehensive SMART attribute tracking:

| SMART Attribute | ID | Why It Matters |
|----------------|----|----------------|
| Reallocated Sector Count | 5 | **Primary failure predictor** — sectors moved to spare area |
| Spin Retry Count | 10 | Motor struggling = mechanical wear |
| Reallocated Event Count | 196 | How many reallocation operations occurred |
| Current Pending Sector Count | 197 | Sectors waiting to be remapped — **active problem indicator** |
| Offline Uncorrectable | 198 | Sectors that can't be read or written |
| UDMA CRC Error Count | 199 | Cable or controller issues |
| Power-On Hours | 9 | Total runtime — context for other metrics |
| Temperature | 194 | Drive overheating = accelerated failure |
| Raw Read Error Rate | 1 | Media surface degradation |
| Seek Error Rate | 7 | Head positioning issues |

**Installation:** Copy the script to TrueNAS, set up a cron job (every 5 minutes).
No pip installs needed — uses only Python stdlib + `smartctl` (already on TrueNAS).

**Important:** TrueNAS updates may overwrite `/etc/netdata/netdata.conf` (needed
for the Supporterino mapping). The graphite-smart-exporter script is placed in a
dataset directory that survives updates.

### 3.3 TrueNAS syslog (to existing Alloy on VM-314)

**Configuration:** TrueNAS UI → System → Advanced → Syslog
- Remote Syslog Server: `10.10.100.56`
- Transport: UDP
- Level: Warning (avoids noise, captures drive/pool errors)

**What flows to Loki:**
- ZFS pool events (degraded, resilvering, scrub errors)
- Drive errors (I/O errors, SMART alerts)
- System alerts
- Authentication events

### 3.4 TrueNAS Graphite exporter (built-in Netdata)

**Configuration:** TrueNAS UI → Reporting → Exporters → Add
- Type: GRAPHITE
- Destination: `10.10.100.56`
- Port: `2003`
- Prefix: `truenas`
- Hostname: `truenas`
- Update Every: `15` (seconds)
- Send Names Instead of IDs: *(leave blank, defaults to true)*
- Enabled: ✅

---

## 4. Storage Impact Assessment

### 4.1 Prometheus Metrics Storage

| Source | Time Series | Scrape Interval | Samples/Day | Storage/Day |
|--------|-------------|-----------------|-------------|-------------|
| Base Netdata (CPU, RAM, disk I/O, network, ZFS) | ~250 | 15s | 1,440,000 | ~2.9 MB |
| SMART attributes (4 drives × ~30 attrs) | ~125 | 5 min | 36,000 | ~72 KB |
| **Total** | **~375** | — | **~1,476,000** | **~3 MB** |

### 4.2 Projected Storage Over Time

| Period | Prometheus (compressed) | Loki (syslog) | Total |
|--------|------------------------|---------------|-------|
| Per day | ~3 MB | ~1–5 MB | ~4–8 MB |
| Per month | ~90 MB | ~30–150 MB | ~120–240 MB |
| Per year | ~1.1 GB | ~360 MB–1.8 GB | ~1.5–3 GB |

**Verdict: Negligible.** Even "aggressive" SMART monitoring (every 5 minutes for all
attributes on all drives) adds only ~72 KB/day to Prometheus. The base Netdata metrics
are the larger contributor at ~3 MB/day, still trivial compared to the 11 Alloy agents
already shipping data.

VM-314 has 60GB disk. Current monitoring data uses a small fraction. TrueNAS metrics
add <3 GB/year — plenty of headroom for years of retention.

---

## 5. Grafana Dashboards

### 5.1 Pre-built

The Supporterino repo includes ready-made Grafana dashboard JSON files for:
- System overview (CPU, memory, network, disk I/O)
- ZFS ARC statistics
- Disk temperature and I/O

### 5.2 Custom: TrueNAS Drive Health Dashboard

Build a custom dashboard with:
- **Row 1: Pool Health** — Pool status, used/available space, scrub last run, scrub errors
- **Row 2: Drive SMART** — Per-drive reallocated sectors (trend), pending sectors, power-on hours, temperature
- **Row 3: Performance** — Disk I/O throughput, IOPS, ZFS ARC hit rate
- **Row 4: System** — CPU, memory, network throughput

### 5.3 Alerting Rules (Future — Phase 6A-4)

| Alert | Condition | Severity |
|-------|-----------|----------|
| Reallocated sectors increasing | `delta(smart_reallocated_sector_count[1d]) > 0` | Critical |
| Pending sectors > 0 | `smart_current_pending_sector_count > 0` | Warning |
| Drive temperature > 50°C | `smart_temperature_celsius > 50` | Warning |
| Drive temperature > 55°C | `smart_temperature_celsius > 55` | Critical |
| Pool degraded | Loki alert on `{job="truenas-syslog"} |= "DEGRADED"` | Critical |
| ZFS ARC hit rate < 80% | `zfs_arc_hit_rate < 0.80` | Info |
| Pool usage > 80% | `pool_used_percent > 80` | Warning |
| SMART test failed | Via syslog or SMART attribute | Critical |

---

## 6. Implementation Steps

### 6.1 VM-314 Side (graphite_exporter container)

1. Download mapping file from Supporterino repo
2. Create Quadlet `.container` file for graphite_exporter
3. Add to Butane config (monitoring.bu v2.2) for rebuild persistence
4. Publish ports: `2003:9109` (Graphite in), `9108:9108` (Prometheus out)
5. Add `truenas` scrape job to Prometheus config
6. Restart Prometheus to pick up new target

### 6.2 TrueNAS Side (manual, web UI only)

1. **Reporting → Exporters → Add** — Configure Graphite exporter to push to VM-314:2003
2. **System → Advanced → Syslog** — Configure remote syslog to VM-314:514 (UDP)
3. **Download graphite-smart-exporter** — Copy script to `/mnt/Pool-1/scripts/`
4. **Create cron job** — Run SMART exporter every 5 minutes, sending to VM-314:2003
5. **Verify data flowing** — Check Prometheus targets, Grafana dashboards, Loki logs

### 6.3 Note on SSH

TrueNAS currently has SSH disabled. Steps 3–4 require either:
- **Option A:** Enable SSH temporarily, copy script, set cron, disable SSH
- **Option B:** Use TrueNAS web UI Shell (System → Shell) to download and configure
- **Option C:** Place script on NFS share from workstation, then set cron via TrueNAS Shell

Option B or C avoids needing to enable SSH at all.

---

## 7. Updated Task Tracker — Phase 6A-3 Additions

Insert as section **3D** (renumber existing 3D Dashboards → 3E, etc.):

### 3D. TrueNAS Monitoring

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 3D.1 | Download graphite mapping file | From Supporterino/truenas-graphite-to-prometheus repo | ⬜ | |
| 3D.2 | Create graphite-exporter Quadlet unit | New container on VM-314: ports 2003:9109, 9108:9108 | ⬜ | |
| 3D.3 | Deploy graphite_exporter mapping file | `/etc/monitoring/graphite-exporter/graphite_mapping.conf` | ⬜ | |
| 3D.4 | Start graphite-exporter container | `systemctl start graphite-exporter.service` | ⬜ | |
| 3D.5 | Add `truenas` scrape job to Prometheus | Target: `localhost:9108`, `honor_labels: true`, interval: 1m | ⬜ | |
| 3D.6 | Reload Prometheus config | `curl -X POST http://localhost:9090/-/reload` | ⬜ | |
| 3D.7 | Configure TrueNAS Graphite exporter | UI: Reporting → Exporters → Add → `10.10.100.56:2003` | ⬜ | **Manual in TrueNAS UI** |
| 3D.8 | Verify base metrics in Prometheus | `truenas_cpu_*`, `truenas_memory_*`, `truenas_disk_*` present | ⬜ | |
| 3D.9 | Configure TrueNAS syslog | UI: System → Advanced → Syslog → `10.10.100.56:514` UDP | ⬜ | **Manual in TrueNAS UI** |
| 3D.10 | Verify TrueNAS logs in Loki | `{job="syslog"} |= "truenas"` or host label | ⬜ | |
| 3D.11 | Download graphite-smart-exporter | From Salvoxia/graphite-smart-exporter repo | ⬜ | |
| 3D.12 | Deploy SMART script to TrueNAS | Place in `/mnt/Pool-1/scripts/` (survives updates) | ⬜ | Via TrueNAS Shell (web UI) |
| 3D.13 | Create TrueNAS cron job | Every 5 min: `python3 /mnt/Pool-1/scripts/smart_exporter.py --host 10.10.100.56 --port 2003` | ⬜ | Via TrueNAS UI → System → Advanced → Cron |
| 3D.14 | Verify SMART metrics in Prometheus | `smart_*` metrics present, 4 drives visible | ⬜ | |
| 3D.15 | Import TrueNAS dashboard | From Supporterino repo JSON or build custom | ⬜ | |
| 3D.16 | Verify drive health visible | Temperature, reallocated sectors, power-on hours per drive | ⬜ | |
| 3D.17 | Update monitoring.bu (Butane v2.2) | Add graphite-exporter container + mapping file for rebuild persistence | ⬜ | |

---

## 8. Updated Phase 6A-4 Success Criteria Additions

| ID | Criterion | Validation | Status |
|----|-----------|------------|:------:|
| 4A.13 | TrueNAS base metrics in Prometheus | `truenas_cpu_*`, `truenas_disk_*` queries return data | ⬜ |
| 4A.14 | TrueNAS SMART data in Prometheus | All 4 drives reporting `smart_*` metrics | ⬜ |
| 4A.15 | TrueNAS syslog in Loki | `{host="truenas"}` or similar returns results | ⬜ |
| 4A.16 | TrueNAS dashboard operational | CPU, memory, disk I/O, drive health visible | ⬜ |
| 4A.17 | Drive temperature trending | Historical temperature graph shows data for all 4 drives | ⬜ |
| 4A.18 | Reallocated sector baseline | Current count visible for all 4 drives (likely 0 — establishes baseline) | ⬜ |

---

## 9. Updated Git Commit Task (2G)

| ID | Task | Details | Status | Operator Notes |
|----|------|---------|:------:|----------------|
| 2G.1 | Commit alloy-agent role + playbook + docs | `Phase 6A-2: Alloy agent deployment to all hosts` | ✅ | Committed as 98db1d1 |
| 2G.2 | Push to GitHub | `git push origin master` | ✅ | Branch is `master`, not `main` |

---

## 10. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Netdata config overwritten by TrueNAS update | High (per Supporterino docs) | Lose metrics until re-applied | Store copy in `/mnt/Pool-1/scripts/`; reapply after updates |
| graphite-smart-exporter script loss | Low | Lose SMART metrics | Script in Pool-1 dataset, backed up by PBS + ZFS snapshots |
| TrueNAS sends massive metric volume | Low | Prometheus storage growth | 1-min scrape interval; mapping file filters to useful metrics |
| Cross-subnet routing failure | Very Low | Lose all TrueNAS telemetry | Same path already validated for NFS mounts |
| SMART data shows concerning trends | Variable | Drive replacement needed | This is the entire point — early warning beats sudden failure |
