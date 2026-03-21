# Colossus Monitoring Stack — Design Document

**Document Type:** Technical Design  
**Phase:** 6A — Observability  
**Author:** Colossus Infrastructure Team  
**Date:** 2026-02-15  
**Status:** DESIGN v2.0 — Substrate changed to CoreOS VM + Podman Quadlet  
**Supersedes:** COLOSSUS_MONITORING_STACK_DESIGN_v1.md (v1.1)  
**Depends on:** Phase 5B (Ansible) ✅ Complete  

---

## 1. Purpose

Deploy a centralized monitoring and logging stack that provides a consolidated dashboard view of the entire Colossus homelab: Proxmox nodes, CoreOS VMs, LXC containers, databases, application services, backups, and network infrastructure.

**The problem today:** There is no visibility into infrastructure health unless you SSH into individual hosts. Backup failures, full disks, crashed containers, and database connection exhaustion are invisible until they cause user-facing impact. Proxmox's built-in summary view covers only the hypervisor layer — not the applications, databases, or containers running inside VMs.

**What this stack provides:**

- Real-time dashboards for all 11 managed hosts in one place
- Historical metrics (CPU, RAM, disk, network) with configurable retention
- Application-level metrics (Traefik request rates, Pi-hole query stats, database health)
- Centralized log search across all hosts (journald, container logs, application logs)
- Foundation for future alerting (disk full, backup failed, container down)

---

## 2. Architecture Decision Record — Substrate Selection

### 2.1 Design Philosophy

The monitoring stack is foundational infrastructure — it is the system you look at when everything else is broken. Its substrate must prioritize debuggability and operational consistency over initial deployment speed. No reputable enterprise deploys embedded (nested) container runtimes in production for critical infrastructure.

### 2.2 Original Substrate: Docker Compose Inside LXC (CT-314) — REJECTED

The v1.0 design specified Docker Compose running inside an LXC container with `features: nesting=1`.

**Why it was rejected:**

- **Nested container runtimes are an anti-pattern.** LXC provides one isolation layer with its own cgroup hierarchy, namespaces, and filesystem overlay. Docker inside it creates a second set. When something fails, you debug through two abstraction layers simultaneously — is the OOM kill from the LXC limit or Docker's? Is the network timeout from Proxmox's bridge, the LXC veth, or Docker's bridge?
- **The `nesting=1` flag is a design smell.** It relaxes security boundaries that LXC was specifically designed to enforce, giving the inner runtime access to capabilities that the outer runtime restricts. An enterprise security review would flag this immediately.
- **Introduces a second container runtime.** The entire Colossus lab standardizes on Podman + Quadlet on CoreOS. Docker Compose inside LXC creates operational drift — different networking model, different logging model, different update model, different debugging tools.
- **Weaker isolation.** LXC containers share the host kernel more directly than VMs. For a service that holds Proxmox API tokens, Grafana admin credentials, and network security logs, VM-level isolation is appropriate.

### 2.3 Considered Alternative: Docker Compose Inside VM — REJECTED

Removes the LXC nesting issues but still introduces Docker as a divergent runtime. Same operational drift problem, just without the nested cgroup complications.

### 2.4 Chosen Substrate: CoreOS VM + Podman + systemd Quadlet — APPROVED

**Rationale:**

- **One container runtime across the entire lab.** Podman everywhere — VM-110, VM-120, VM-210, VM-220, and now VM-314. Muscle memory transfers. Runbooks transfer. Ansible patterns transfer.
- **VM isolation boundary.** Full kernel separation for a service holding API tokens, admin passwords, and security logs.
- **No nested container-runtime hacks.** No `nesting=1`, no overlayfs-inside-overlayfs, no double cgroup trees.
- **systemd-managed lifecycle.** `systemctl status grafana`, `journalctl -u grafana`, `podman logs grafana` — the same tooling as every other host. Predictable start ordering via unit dependencies.
- **Reproducible via Butane/Ignition.** Follows the established Colossus CoreOS VM doctrine — the VM is cattle, not a pet. Rebuild from Ignition config in under 5 minutes.
- **Debuggability is a long-term cost, not a one-time cost.** The Quadlet translation is a one-time effort. Every future incident, upgrade, and 3am troubleshooting session benefits from the consistent substrate.

**Trade-offs accepted:**

- Higher resource footprint than LXC (full VM overhead) — acceptable on pve-3 which has capacity.
- Up-front effort to translate Docker Compose → Quadlet units — one-time cost, already documented in this design.
- Monitoring stack tutorials/examples assume Docker Compose — we adapt, but the patterns are straightforward.

**Decision:** For a foundational platform component, consistency and isolation beat short-term convenience.

---

## 3. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    VM-314 Monitoring (pve-3)                        │
│                    CoreOS + Podman + Quadlet                        │
│                                                                     │
│  ┌──────────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │
│  │ Prometheus   │  │  Loki    │  │ Grafana  │  │ PVE Exporter │   │
│  │ :9090        │  │  :3100   │  │  :3000   │  │  :9221       │   │
│  └──────┬───────┘  └─────┬────┘  └────┬─────┘  └──────────────┘   │
│         │                │            │                             │
│  ┌──────────────┐  ┌──────────────┐                                │
│  │ Alertmanager │  │ Alloy        │   ← UniFi syslog receiver     │
│  │ :9093        │  │ UDP :514     │     (filtered → Loki)          │
│  └──────────────┘  └──────────────┘                                │
│                                                                     │
│  All containers on shared Podman network "monitoring"               │
│  Inter-container: DNS names (prometheus, loki, grafana, etc.)       │
│  External: PublishPort binds to VM IP (10.10.100.56)                │
└─────────┼───────────────┼────────────┼─────────────────────────────┘
          │               │            │
          │               │            │  ← Internal access via
          │               │            │    grafana.cogmai.com
          │               │            │    (Traefik route)
    ┌─────┴───────────────┴────┐
    │    Grafana Alloy agents   │  ← Unified agent on each host
    │    (metrics + logs)       │     replaces node_exporter + Promtail
    ├───────────────────────────┤
    │ pve-1    pve-2    pve-3   │  Proxmox nodes
    │ VM-110   VM-120           │  PROD VMs
    │ VM-210   VM-220           │  DEV VMs
    │ CT-311   CT-312   CT-313  │  Infrastructure CTs
    │ PBS (VM-900)              │  Backup server
    └───────────────────────────┘

    ┌───────────────────────────┐
    │    UniFi Network Gear     │  ← Syslog push (UDP 514)
    │    (UDM, switches, APs)   │     to Alloy on VM-314
    │    Filtered: firewall,    │     (noise dropped at ingestion)
    │    IDS/IPS, DHCP only     │
    └───────────────────────────┘
```

### 3.1 Central Stack (VM-314 on pve-3)

All monitoring services run in a single CoreOS VM on pve-3 (Infra node), managed as Podman containers via systemd Quadlet units. Containers communicate over a shared Podman network (`monitoring`) using DNS names.

| Service | Purpose | Port | Container Name | Resource Est. |
|---------|---------|------|----------------|---------------|
| **Prometheus** | Time-series metrics database, scrapes all targets | 9090 | prometheus | 512MB–1GB RAM |
| **Loki** | Log aggregation engine (like Prometheus, but for logs) | 3100 | loki | 256MB–512MB RAM |
| **Grafana** | Dashboard UI, queries Prometheus + Loki | 3000 | grafana | 256MB RAM |
| **PVE Exporter** | Proxmox API → Prometheus metrics translator | 9221 | pve-exporter | 64MB RAM |
| **Alertmanager** | Alert routing and notification (silent until rules tuned) | 9093 | alertmanager | 64MB RAM |
| **Alloy** | UniFi syslog receiver + filter → Loki | UDP 514 | alloy | 128MB RAM |

**Total estimated:** 1.5–2.5GB RAM, 20–40GB disk (depending on retention and log volume).

### 3.2 Podman Network — Inter-Container Communication

**This is critical.** Unlike Docker Compose where containers share a default bridge with DNS, Podman Quadlet containers are isolated by default. Without a shared network, containers can only reach each other via published ports on the host — and from inside a container, `127.0.0.1` refers to that container's own loopback, not the VM host.

**Solution:** Create a Podman network named `monitoring` and attach all six containers to it. Containers then resolve each other by container name (e.g., Grafana reaches Prometheus at `http://prometheus:9090`).

```bash
podman network create monitoring
```

Each Quadlet unit includes `Network=monitoring` in the `[Container]` section.

**Network topology:**

| From | To | Address Used | Purpose |
|------|----|-------------|---------|
| Grafana | Prometheus | `http://prometheus:9090` | Query metrics |
| Grafana | Loki | `http://loki:3100` | Query logs |
| Prometheus | PVE Exporter | `http://pve-exporter:9221` | Scrape Proxmox metrics |
| Prometheus | Alertmanager | `http://alertmanager:9093` | Send alerts |
| Alloy | Loki | `http://loki:3100/loki/api/v1/push` | Push filtered syslog |
| External agents | VM-314 | `http://10.10.100.56:3100` | Push logs (via PublishPort) |
| Prometheus | External targets | `http://10.10.100.X:12345` | Scrape Alloy agents |

### 3.3 Per-Host Agents (Grafana Alloy)

**Why Alloy, not Promtail + node_exporter:**

Promtail (the traditional Loki log shipper) reached End-of-Life on March 2, 2026. Grafana Alloy is its official replacement — a unified agent that handles both metrics collection AND log shipping in a single binary. This means one agent per host instead of two.

Alloy on each managed host:
- Exposes host metrics (CPU, RAM, disk, network) — replaces `node_exporter`
- Ships journald/systemd logs to Loki — replaces `Promtail`
- Ships Podman container logs to Loki (on CoreOS VMs)
- Optionally scrapes application-specific metrics endpoints

| Host Type | Alloy Collects | Notes |
|-----------|---------------|-------|
| Proxmox nodes | Host metrics, journald logs | Also has PVE Exporter for Proxmox API metrics |
| CoreOS VMs | Host metrics, journald + container logs | Podman containers log to journald via Quadlet |
| LXC containers | Host metrics, journald + service logs | Pi-hole, Traefik, cloudflared |
| PBS | Host metrics, journald logs | Backup job status |

---

## 4. Metrics Collection Strategy

### 4.1 Proxmox Cluster Metrics (PVE Exporter)

The `prometheus-pve-exporter` queries the Proxmox API and translates cluster-level data into Prometheus metrics. Runs on VM-314 (monitoring VM), not on the Proxmox nodes themselves.

**What it provides:**
- Node status (up/down), CPU, memory, disk per node
- VM/CT status, resource allocation vs usage per guest
- Storage pool usage and availability
- Backup job information
- Cluster health and quorum status

**Setup requirements:**
- Read-only Proxmox API user (`monitoring@pve` with PVEAuditor role)
- API token (no password needed in config)
- Single exporter instance scrapes all 3 nodes

**Pre-built Grafana dashboard:** ID 10347 ("Proxmox via Prometheus")

### 4.2 Host Metrics (Alloy node integration)

Grafana Alloy includes a built-in `node_exporter`-compatible integration that exposes standard host metrics:

- CPU utilization (per-core, system/user/iowait)
- Memory usage (total, available, cached, buffers)
- Disk I/O (read/write bytes, IOPS, latency)
- Filesystem usage (per-mount, percent full)
- Network I/O (per-interface, bytes in/out, errors)
- System load averages
- Uptime

These metrics are scraped by central Prometheus from each Alloy agent.

### 4.3 Application-Specific Metrics

| Source | Exporter | Metrics Provided |
|--------|----------|-----------------|
| **Traefik** | Built-in (enable in traefik.yml) | Request count, duration, status codes per route |
| **Pi-hole** | `pihole6_exporter` (Python, on CT-311) | Queries/sec, blocked %, cache hit ratio, upstream latency |
| **Neo4j** | Built-in `/metrics` endpoint | Heap usage, transaction count, query execution time |
| **PostgreSQL** | `postgres_exporter` (on DB VMs) | Connections, query duration, table sizes, replication lag |
| **Qdrant** | Built-in `/metrics` endpoint | Collection count, search latency, memory usage |
| **PBS** | PVE Exporter backup collector | Last backup time, size, success/failure per job |

**Phase 6A-1 through 6A-3 (deploy now):** Proxmox, host metrics, Traefik, Pi-hole  
**Phase 6A-4 (add later):** Neo4j, PostgreSQL, Qdrant, PBS backup metrics

### 4.4 Traefik Metrics Configuration

Traefik has native Prometheus support. Add to the static configuration (`traefik.yml` on CT-313):

```yaml
metrics:
  prometheus:
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
    entryPoint: metrics

entryPoints:
  metrics:
    address: ":8082"
```

This exposes metrics at `http://10.10.100.55:8082/metrics` — no sidecar exporter needed.

**Key Traefik metrics:**
- `traefik_entrypoint_requests_total` — request count by entrypoint, method, code
- `traefik_service_request_duration_seconds` — latency histogram per service
- `traefik_service_server_up` — backend health (1=up, 0=down)
- `traefik_entrypoint_open_connections` — active connections

**Pre-built Grafana dashboard:** ID 17346 ("Traefik Official")

---

## 5. Log Collection Strategy

### 5.1 Why Grafana Alloy (Not Promtail)

| Factor | Promtail | Grafana Alloy |
|--------|----------|---------------|
| Status | EOL March 2, 2026 | Actively developed |
| Scope | Logs only | Logs + metrics + traces |
| Agents per host | 2 (Promtail + node_exporter) | 1 (Alloy) |
| journald support | Yes | Yes |
| Container log support | Yes | Yes |
| Configuration | YAML | HCL (River) |
| Migration path | → Alloy | N/A (current) |

Since we're building greenfield, go directly to Alloy. No migration needed.

### 5.2 What Gets Collected

**Proxmox nodes (pve-1, pve-2, pve-3):**
- All journald entries (systemd units, kernel, pveproxy, pvedaemon, corosync)
- Labels: `host`, `unit`, `priority`

**CoreOS VMs (VM-110, VM-120, VM-210, VM-220):**
- journald entries including Podman container output (Quadlet services log to journald)
- Covers: Neo4j, PostgreSQL, Qdrant, colossus-backend, colossus-frontend, nginx
- Labels: `host`, `unit`, `priority`, `container_name`

**LXC Containers (CT-311, CT-312, CT-313):**
- journald entries for service-specific units
- CT-311: pihole-FTL (DNS queries, blocking)
- CT-312: cloudflared (tunnel status, connection events)
- CT-313: traefik (access logs, errors)
- Labels: `host`, `unit`, `priority`

**PBS (VM-900):**
- journald entries for backup operations
- Labels: `host`, `unit`, `priority`

### 5.3 Alloy Agent Configuration Pattern

Each remote host runs Alloy with a configuration that:
1. Reads journald entries (source)
2. Relabels to extract `unit`, `host`, `priority` (processor)
3. Pushes to central Loki at `http://10.10.100.56:3100/loki/api/v1/push` (writer)
4. Exposes node metrics on `:12345/metrics` for Prometheus scraping

Example Alloy config (HCL/River syntax):

```hcl
// — Metrics: expose host metrics for Prometheus scraping —
prometheus.exporter.unix "host" { }

prometheus.scrape "host_metrics" {
  targets    = prometheus.exporter.unix.host.targets
  forward_to = [prometheus.remote_write.default.receiver]
}

prometheus.remote_write "default" {
  endpoint {
    url = "http://10.10.100.56:9090/api/v1/write"
  }
}

// — Logs: ship journald to Loki —
loki.source.journal "journal" {
  max_age    = "24h"
  forward_to = [loki.relabel.journal.receiver]
  labels     = { job = "systemd-journal" }
}

loki.relabel "journal" {
  forward_to = [loki.write.default.receiver]

  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal__hostname"]
    target_label  = "host"
  }
  rule {
    source_labels = ["__journal__priority_keyword"]
    target_label  = "priority"
  }
}

loki.write "default" {
  endpoint {
    url = "http://10.10.100.56:3100/loki/api/v1/push"
  }
}
```

### 5.4 Alloy Deployment per Host Type

| Host Type | Install Method | Config Management |
|-----------|---------------|-------------------|
| Proxmox nodes (Debian) | APT repo + systemd | Ansible `alloy-agent` role |
| CoreOS VMs (Fedora) | Podman container with `/var/log/journal` bind-mount | Ansible `alloy-agent` role |
| LXC containers (Debian) | APT repo + systemd | Ansible `alloy-agent` role |
| PBS (Proxmox BS) | APT repo + systemd | Ansible `alloy-agent` role |

**CoreOS consideration:** Alloy runs as a Podman container (avoiding rpm-ostree layer). Bind-mount `/var/log/journal` read-only into the container. This is cleaner for an immutable OS.

### 5.5 UniFi Network Syslog (Filtered)

UniFi gear (UDM, switches, APs) supports native remote syslog. The entire UniFi site pushes syslog to a configured IP:port. The problem is volume — AP client roaming events alone generate thousands of lines per hour on an active network.

**Solution:** Alloy on VM-314 receives syslog on UDP 514 and applies aggressive filtering before forwarding to Loki. Noise never touches storage.

**What we keep:**

| Category | Why | Example Log Patterns |
|----------|-----|---------------------|
| Firewall blocks/rejects | Diagnose connectivity issues (SSH mystery) | `kernel: [UFW BLOCK]`, `iptables-dropped` |
| IDS/IPS alerts | Security events from CyberSecure/Threat Mgmt | `IDS`, `IPS`, `threat`, `alert` |
| DHCP lease events | Track "what IP did device X get?" | `dnsmasq-dhcp`, `DHCPACK`, `DHCPOFFER` |
| Device reboots/failures | Infrastructure stability | `restarted`, `firmware`, `adoption` |
| Admin/auth events | Who logged into the controller | `admin`, `login`, `logout`, `auth` |

**What we drop (before Loki):**

| Category | Why Drop | Volume Impact |
|----------|----------|---------------|
| AP client association/disassociation | Massive volume, no diagnostic value | ~80% of total syslog |
| Wireless channel/power changes | Noise | High on busy networks |
| Switch port state flaps | Routine | Moderate |
| Heartbeat/status polls | Routine keep-alives | Moderate |
| Debug-level messages | Verbose internals | High if enabled |

**UniFi Controller Configuration:**

In UniFi Network Application:
1. Settings → System → Advanced Features → Remote Logging
2. Enable Remote Syslog Server
3. Server address: `10.10.100.56` (VM-314)
4. Port: `514`
5. Leave "Enable debug logging" **unchecked**

For UniFi 9.x, also enable under Settings → CyberSecure → Traffic Logging for IDS/IPS events.

**Alloy syslog receiver config (on VM-314):**

```hcl
logging {
  level = "info"
}

// — Write endpoint (local Loki via Podman network) —
loki.write "default" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}

// — UniFi syslog receiver —
loki.source.syslog "unifi" {
  listener {
    address  = "0.0.0.0:514"
    protocol = "udp"
    labels   = { job = "unifi" }
  }
  forward_to = [loki.process.unifi_filter.receiver]
}

// — Drop noise, keep security-relevant logs —
loki.process "unifi_filter" {
  forward_to = [loki.write.default.receiver]

  // Drop AP association/disassociation (biggest volume offender)
  stage.match {
    selector = "{job=\"unifi\"}"
    pipeline_name = "drop_ap_noise"
    stage.regex {
      expression = "(?i)(hostapd|ieee 802\\.11|associated|disassociated|deauthenticated|WPA_GROUP)"
    }
    stage.drop {
      longer_than = "0"
    }
    action = "drop"
  }

  // Drop wireless channel/power adjustments
  stage.match {
    selector = "{job=\"unifi\"}"
    pipeline_name = "drop_wireless_tuning"
    stage.regex {
      expression = "(?i)(channel|chanspec|radar|dfs|txpower)"
    }
    stage.drop {
      longer_than = "0"
    }
    action = "drop"
  }

  // Drop switch port flap noise
  stage.match {
    selector = "{job=\"unifi\"}"
    pipeline_name = "drop_switch_noise"
    stage.regex {
      expression = "(?i)(STP|BPDU|link.*(up|down).*port)"
    }
    stage.drop {
      longer_than = "0"
    }
    action = "drop"
  }

  // Everything else passes through to Loki
  // (firewall blocks, IDS/IPS, DHCP, admin, reboots)
}
```

**Estimated volume after filtering:** ~5–20MB/day (down from potentially 500MB+/day unfiltered).

**Useful Grafana queries for UniFi logs:**
- Firewall blocks: `{job="unifi"} |= "BLOCK"` or `|= "dropped"`
- IDS/IPS events: `{job="unifi"} |~ "(?i)(IDS|IPS|threat|alert)"`
- DHCP leases: `{job="unifi"} |~ "(?i)(DHCPACK|DHCPOFFER|DHCPREQUEST)"`
- Device reboots: `{job="unifi"} |~ "(?i)(restart|reboot|firmware|adoption)"`
- SSH-related: `{job="unifi"} |= "SSH"` or `|= "port 22"`

---

## 6. VM-314 Specification

### 6.1 Proxmox VM Spec

| Property | Value |
|----------|-------|
| VMID | 314 |
| Name | monitoring |
| Hostname | monitoring |
| Node | pve-3 |
| IP | 10.10.100.56/24 |
| Gateway | 10.10.100.1 |
| DNS | 10.10.100.53 (Pi-hole) |
| Cores | 2 |
| Memory | 4096MB |
| Disk | 60GB (local-lvm) |
| Machine | q35 |
| OS | Fedora CoreOS (latest stable) |
| Bridge | vmbr0 |

**Why 4GB RAM (up from 2GB in v1):** A CoreOS VM has higher base overhead than an LXC container. Six Podman containers (Prometheus, Loki, Grafana, PVE Exporter, Alertmanager, Alloy) each carry their own process overhead. 4GB provides headroom for Prometheus during heavy scrape periods and Loki during log ingestion spikes.

**Why 60GB disk (up from 32GB in v1):** Prometheus 30-day retention at 15s intervals for ~15 targets generates 2–5GB. Loki 30-day retention with 11 hosts + UniFi filtered syslog generates 7–14GB compressed. The additional headroom covers CoreOS base image, Podman image cache, upgrades, and operational mistakes (forgotten log rotation, etc.).

**Why VM, not LXC:** See Section 2 (Architecture Decision Record). Summary: VM isolation boundary, no nested container runtimes, one Podman runtime across the lab, Butane/Ignition reproducibility.

### 6.2 Network & DNS

| Record | IP | Purpose |
|--------|-----|---------|
| `monitoring.cogmai.com` | 10.10.100.56 | Direct VM access |
| `grafana.cogmai.com` | 10.10.100.55 (Traefik) | Dashboard access via reverse proxy (preferred) |

Grafana accessed via Traefik (HTTPS, internal only — no Cloudflare Tunnel exposure).

### 6.3 Firewall / Port Summary

| From | To | Port | Protocol | Purpose |
|------|----|------|----------|---------|
| VM-314 (Prometheus) | All Alloy agents | 12345 | HTTP | Scrape host metrics |
| VM-314 (Prometheus) | CT-313 (Traefik) | 8082 | HTTP | Scrape Traefik metrics |
| VM-314 (Prometheus) | CT-311 (Pi-hole) | 9666 | HTTP | Scrape Pi-hole metrics |
| VM-314 (PVE Exporter) | pve-1/2/3 | 8006 | HTTPS | Proxmox API queries |
| All Alloy agents | VM-314 (Loki) | 3100 | HTTP | Push logs |
| UniFi devices (UDM, switches) | VM-314 (Alloy) | 514 | UDP | Syslog push (filtered) |
| Traefik (CT-313) | VM-314 (Grafana) | 3000 | HTTP | Reverse proxy to dashboard |
| Browser | Traefik (CT-313) | 443 | HTTPS | User accesses Grafana |

---

## 7. Storage & Retention

### 7.1 Storage Layout

All persistent data lives on the VM filesystem under dedicated paths:

```
/var/lib/monitoring/
├── prometheus/       # TSDB data (metrics)
├── loki/             # Log chunks, index, cache, compactor
│   ├── chunks/
│   ├── index/
│   ├── cache/
│   ├── compactor/
│   └── rules/
└── grafana/          # Dashboard configs, sqlite DB

/etc/monitoring/
├── prometheus/
│   ├── prometheus.yml
│   └── rules/        # Alert rules (future)
├── loki/
│   └── loki-config.yml
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── datasources.yml
│       └── dashboards/
│           └── dashboards.yml
├── pve-exporter/
│   └── pve.yml
├── alertmanager/
│   └── alertmanager.yml
├── alloy/
│   └── config.alloy
└── secrets.env        # Grafana admin password (mode 0600)
```

### 7.2 Prometheus Retention

| Setting | Value | Rationale |
|---------|-------|-----------|
| Retention time | 30 days | Sufficient for homelab trend analysis |
| Retention size | 10GB max | Safety cap to prevent disk fill |
| Scrape interval | 15s | Standard, balances granularity vs storage |

30 days at 15s intervals for ~15 scrape targets generates approximately 2–5GB of data.

### 7.3 Loki Retention

| Setting | Value | Rationale |
|---------|-------|-----------|
| Retention period | 30 days (720h) | Matches Prometheus for consistent troubleshooting window |
| Storage backend | Filesystem (local) | Simplest for single-node; S3-compatible if needed later |
| Max ingestion rate | 16MB/s | Sufficient for 11 hosts + UniFi syslog |
| Ingestion burst | 32MB/s | Handles log spikes |

Log volume estimate: 11 hosts × ~1MB/hour average + UniFi filtered syslog (~20MB/day) ≈ 4.5GB/day uncompressed. Loki compresses aggressively — expect ~500MB–1GB/day on disk. 30 days ≈ 15–30GB.

### 7.4 Backup Strategy

VM-314 gets added to the PBS backup schedule (same as all other infrastructure):

```yaml
# Add to inventory/group_vars/proxmox.yml
- name: backup-monitoring
  vmid: 314
  notes: "Monitoring stack scheduled backup"
```

Grafana dashboards should also be exported as JSON and committed to the `colossus-ansible` repo for version control. Prometheus and Loki data is ephemeral — it can be regenerated by running the stack. Only Grafana configuration (dashboards, datasources) needs durable backup.

---

## 8. Quadlet Container Definitions

All Quadlet `.container` files are placed in `/etc/containers/systemd/` and declared via Butane/Ignition for reproducible provisioning.

**Important Quadlet notes:**
- Every container includes `Network=monitoring` for inter-container DNS resolution.
- Image tags are pinned to specific versions, not `:latest` — a bad pull should never take down observability during an incident.
- Prometheus and Alertmanager require all CLI flags on a single `Exec=` line (Quadlet uses only the last `Exec=` directive, unlike Docker Compose which concatenates command arrays).
- Data volumes use `:Z` for SELinux relabeling on CoreOS.

### 8.1 Podman Network Unit: monitoring.network

```ini
[Network]
NetworkName=monitoring
Driver=bridge
```

Place at `/etc/containers/systemd/monitoring.network`. Systemd will create this network before any containers that reference it start.

### 8.2 prometheus.container

```ini
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/prom/prometheus:v3.2.1
ContainerName=prometheus
Network=monitoring
PublishPort=9090:9090
Volume=/etc/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro,Z
Volume=/etc/monitoring/prometheus/rules:/etc/prometheus/rules:ro,Z
Volume=/var/lib/monitoring/prometheus:/prometheus:Z
Exec=--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=30d --storage.tsdb.retention.size=10GB --web.enable-lifecycle --web.enable-remote-write-receiver

[Install]
WantedBy=multi-user.target
```

### 8.3 loki.container

```ini
[Unit]
Description=Loki
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/grafana/loki:3.4.2
ContainerName=loki
Network=monitoring
PublishPort=3100:3100
Volume=/etc/monitoring/loki/loki-config.yml:/etc/loki/config.yml:ro,Z
Volume=/var/lib/monitoring/loki:/loki:Z
Exec=-config.file=/etc/loki/config.yml

[Install]
WantedBy=multi-user.target
```

### 8.4 grafana.container

```ini
[Unit]
Description=Grafana
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/grafana/grafana:11.5.2
ContainerName=grafana
Network=monitoring
PublishPort=3000:3000
Volume=/var/lib/monitoring/grafana:/var/lib/grafana:Z
Volume=/etc/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro,Z
EnvironmentFile=/etc/monitoring/secrets.env
Environment=GF_AUTH_ANONYMOUS_ENABLED=false
Environment=GF_USERS_ALLOW_SIGN_UP=false
Environment=GF_SECURITY_DISABLE_GRAVATAR=true
Environment=GF_SECURITY_COOKIE_SECURE=true

[Install]
WantedBy=multi-user.target
```

### 8.5 pve-exporter.container

```ini
[Unit]
Description=Prometheus PVE Exporter
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/prompve/prometheus-pve-exporter:3.5.0
ContainerName=pve-exporter
Network=monitoring
PublishPort=9221:9221
Volume=/etc/monitoring/pve-exporter/pve.yml:/etc/prometheus/pve.yml:ro,Z

[Install]
WantedBy=multi-user.target
```

### 8.6 alertmanager.container

```ini
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/prom/alertmanager:v0.28.1
ContainerName=alertmanager
Network=monitoring
PublishPort=9093:9093
Volume=/etc/monitoring/alertmanager:/etc/alertmanager:ro,Z
Exec=--config.file=/etc/alertmanager/alertmanager.yml

[Install]
WantedBy=multi-user.target
```

### 8.7 alloy.container

```ini
[Unit]
Description=Grafana Alloy (UniFi Syslog Receiver)
Wants=network-online.target
After=network-online.target

[Container]
Image=docker.io/grafana/alloy:v1.6.1
ContainerName=alloy
Network=monitoring
PublishPort=514:514/udp
PublishPort=12346:12346
Volume=/etc/monitoring/alloy/config.alloy:/etc/alloy/config.alloy:ro,Z
Exec=run --server.http.listen-addr=0.0.0.0:12346 --config.file=/etc/alloy/config.alloy

[Install]
WantedBy=multi-user.target
```

---

## 9. Configuration Files

### 9.1 Prometheus: /etc/monitoring/prometheus/prometheus.yml

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

scrape_configs:
  # — Proxmox cluster (via PVE Exporter) —
  - job_name: 'proxmox'
    metrics_path: /pve
    params:
      module: [default]
      cluster: ['1']
      node: ['1']
    static_configs:
      - targets:
          - 10.10.100.3   # pve-1
          - 10.10.100.2   # pve-2
          - 10.10.100.5   # pve-3
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: pve-exporter:9221

  # — Alloy agents (host metrics) —
  - job_name: 'alloy'
    static_configs:
      - targets:
          - 10.10.100.3:12345     # pve-1
          - 10.10.100.2:12345     # pve-2
          - 10.10.100.5:12345     # pve-3
          - 10.10.100.110:12345   # colossus-prod-db1
          - 10.10.100.120:12345   # colossus-prod-app1
          - 10.10.100.200:12345   # colossus-dev-db1
          - 10.10.100.220:12345   # colossus-dev-app1
          - 10.10.100.53:12345    # pihole
          - 10.10.100.54:12345    # cloudflared
          - 10.10.100.55:12345    # traefik
          - 10.10.100.242:12345   # pbs

  # — Traefik (built-in Prometheus endpoint) —
  - job_name: 'traefik'
    static_configs:
      - targets: ['10.10.100.55:8082']

  # — Pi-hole (pihole6_exporter) —
  - job_name: 'pihole'
    static_configs:
      - targets: ['10.10.100.53:9666']

  # — Prometheus self-monitoring —
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

**Note on addresses:** Internal references (PVE Exporter, Alertmanager) use Podman network DNS names. External scrape targets use real IPs because they're outside the VM.

### 9.2 Loki: /etc/monitoring/loki/loki-config.yml

```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150
  delete_request_store: filesystem

limits_config:
  retention_period: 720h
  ingestion_rate_mb: 16
  ingestion_burst_size_mb: 32
```

### 9.3 Grafana Datasource Provisioning: /etc/monitoring/grafana/provisioning/datasources/datasources.yml

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
```

**Note:** These URLs use Podman network DNS names, not `127.0.0.1`. Grafana runs inside a container — `127.0.0.1` from inside that container is Grafana's own loopback, not the VM host. The `monitoring` Podman network provides DNS resolution so `prometheus` resolves to the Prometheus container's IP.

### 9.4 Grafana Dashboard Provisioning: /etc/monitoring/grafana/provisioning/dashboards/dashboards.yml

```yaml
apiVersion: 1
providers:
  - name: 'colossus'
    orgId: 1
    folder: 'Colossus'
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /etc/grafana/provisioning/dashboards
```

### 9.5 PVE Exporter: /etc/monitoring/pve-exporter/pve.yml

```yaml
default:
  user: monitoring@pve
  token_name: monitoring
  token_value: <ANSIBLE_VAULT_SECRET>
  verify_ssl: false
```

The token secret is stored in Ansible Vault and templated during deployment.

### 9.6 Alertmanager: /etc/monitoring/alertmanager/alertmanager.yml

```yaml
route:
  receiver: 'default'
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: 'default'
    # Silent until alert rules are tuned.
    # Add email/webhook receivers when baseline metrics are established.
```

### 9.7 Secrets: /etc/monitoring/secrets.env

```bash
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=<ANSIBLE_VAULT_SECRET>
GF_SERVER_ROOT_URL=https://grafana.cogmai.com
GF_SERVER_DOMAIN=grafana.cogmai.com
```

File permissions: `0600`, owned by `root:root`. Templated by Ansible from vault-encrypted values.

---

## 10. Butane/Ignition Provisioning

VM-314 follows the established Colossus CoreOS VM doctrine: all filesystem layout, configuration files, Quadlet units, and secrets are declared in a Butane YAML file, transpiled to Ignition JSON, and applied at VM creation time.

**This means:**
- No manual `mkdir` or `cat` commands on the VM.
- The VM is cattle, not a pet — destroy and rebuild from Ignition in under 5 minutes.
- Configuration drift is impossible because the Ignition config is the source of truth.
- The Butane file lives in `colossus-ansible/butane/monitoring.bu` under version control.

**Butane config includes:**
- Hostname (`monitoring`)
- Static IP configuration
- SSH authorized key
- All directory structures under `/etc/monitoring/` and `/var/lib/monitoring/`
- All configuration files (Sections 9.1–9.7)
- All Quadlet `.container` files (Section 8)
- The Podman `.network` file (Section 8.1)
- Secrets environment file (permissions locked to 0600)

**SELinux considerations for CoreOS:**
- Data volumes use `:Z` in Quadlet definitions for automatic SELinux relabeling.
- Config file bind-mounts use `:ro,Z` (read-only with relabeling).
- No virtiofs mounts are needed for VM-314 (all data is local to the VM disk), so the `context=` mount option pattern from DB VMs does not apply here.

**Transpile and deploy:**

```bash
# On control node (proxima-centauri)
butane --pretty --strict butane/monitoring.bu -o ignition/monitoring.ign

# VM creation uses the standard create-vm.yml playbook
ansible-playbook playbooks/create-vm.yml -e @vars/vm-314-monitoring.yml
```

---

## 11. Grafana Dashboards

### 11.1 Pre-built Dashboards (Import on Day 1)

| Dashboard | Grafana ID | Data Source | What It Shows |
|-----------|-----------|-------------|---------------|
| Proxmox Cluster | 10347 | Prometheus | Node CPU/RAM/disk, VM/CT status, storage |
| Node Exporter Full | 1860 | Prometheus | Deep host metrics (per Alloy agent) |
| Traefik | 17346 | Prometheus | Request rates, latency, error rates per route |
| Pi-hole v6 | 21043 | Prometheus | Queries/sec, block rate, upstream latency |
| Loki Logs Overview | 13639 | Loki | Log search, filtering, live tail |

### 11.2 Custom "Colossus Overview" Dashboard (Build)

A single-pane overview showing:

**Row 1 — Infrastructure Health:**
- Proxmox node status (3 stat panels: green/red)
- VM/CT status (up/down indicators for all guests)
- PBS last backup status (per job)
- Disk usage bars for all ZFS pools

**Row 2 — Application Layer:**
- Traefik requests/sec (time series)
- Traefik error rate (percentage gauge)
- Active backend services (up/down from `traefik_service_server_up`)
- Pi-hole queries/sec and block percentage

**Row 3 — Database Health:**
- Neo4j heap usage (PROD + DEV)
- PostgreSQL active connections (PROD + DEV)
- Qdrant collection sizes

**Row 4 — Network & Security (UniFi):**
- Firewall blocks/sec (Loki query: `rate({job="unifi"} |= "BLOCK" [5m])`)
- Recent IDS/IPS alerts (Loki table panel)
- DHCP lease activity
- SSH-related events (the diagnostic view we wished we had)

**Row 5 — Logs Panel:**
- Recent error logs across all hosts (Loki query: `{priority="err"}`)
- Container restart events
- UniFi firewall blocks (last 24h)

---

## 12. Ansible Integration

### 12.1 New Roles

| Role | Target | Purpose |
|------|--------|---------|
| `monitoring-stack` | VM-314 | Deploy config files, Quadlet units, secrets (via Butane/Ignition + Ansible) |
| `alloy-agent` | All managed hosts | Install and configure Grafana Alloy (templated per host type) |
| `pihole-exporter` | CT-311 | Install pihole6_exporter Python service |

### 12.2 New Playbooks

```bash
# Deploy or update the monitoring stack configuration
ansible-playbook playbooks/deploy-monitoring.yml

# Deploy Alloy agents to all hosts
ansible-playbook playbooks/deploy-alloy.yml
```

### 12.3 Inventory Updates

**New host in `inventory/hosts.yml`:**

```yaml
infrastructure:
  hosts:
    monitoring:
      ansible_host: 10.10.100.56
      ansible_user: core
      vmid: 314
```

**New vars file `vars/vm-314-monitoring.yml`:**

```yaml
vm_id: 314
vm_name: monitoring
vm_node: pve-3
vm_cores: 2
vm_memory: 4096
vm_disk_size: "60G"
vm_ip: "10.10.100.56/24"
vm_gateway: "10.10.100.1"
vm_nameserver: "10.10.100.53"
vm_machine: q35
vm_description: "Monitoring stack: Prometheus + Loki + Grafana + Alloy"
ignition_file: "ignition/monitoring.ign"
```

**New entries in `inventory/host_vars/traefik.yml`:**

```yaml
- name: grafana
  host: "grafana.{{ domain }}"
  backend_url: "http://10.10.100.56:3000"
```

**New entries in `inventory/host_vars/pihole.yml`:**

```yaml
- "10.10.100.56 monitoring.cogmai.com"
- "10.10.100.55 grafana.cogmai.com"  # via Traefik
```

**New backup job in `inventory/group_vars/proxmox.yml`:**

```yaml
- name: backup-monitoring
  vmid: 314
  notes: "Monitoring stack scheduled backup"
```

---

## 13. Execution Plan

### Phase 6A-1: Core Stack (VM-314)

| Step | Task | Method |
|------|------|--------|
| 1 | Create Butane config for VM-314 | `butane/monitoring.bu` — all configs, Quadlet units, secrets |
| 2 | Transpile Butane → Ignition | `butane --pretty --strict monitoring.bu -o monitoring.ign` |
| 3 | Create Proxmox API monitoring user + token | Manual via Proxmox UI (see Section 14) |
| 4 | Store PVE token + Grafana password in Ansible Vault | `ansible-vault encrypt_string` |
| 5 | Create VM-314 on pve-3 | `ansible-playbook create-vm.yml -e @vars/vm-314-monitoring.yml` |
| 6 | Validate VM boot + all 6 containers running | `ssh core@10.10.100.56 'podman ps'` |
| 7 | Validate Prometheus targets | Browse `http://10.10.100.56:9090/targets` |
| 8 | Validate Grafana datasources | Browse `http://10.10.100.56:3000`, check Prometheus + Loki connected |
| 9 | Add Traefik route for `grafana.cogmai.com` | Update `host_vars/traefik.yml`, run `manage-traefik.yml` |
| 10 | Add Pi-hole DNS records | Update `host_vars/pihole.yml`, run `manage-pihole.yml` |
| 11 | Add PBS backup job | Update `group_vars/proxmox.yml`, run `manage-pbs-backups.yml` |
| 12 | Validate Grafana via Traefik | Browse `https://grafana.cogmai.com` |

**Validation gate:** Grafana accessible via Traefik, Prometheus scraping PVE Exporter, Loki accepting test queries.

### Phase 6A-2: Alloy Agents (Per-Host)

| Step | Task | Method |
|------|------|--------|
| 1 | Create `alloy-agent` Ansible role | Templates Alloy config per host type |
| 2 | Deploy Alloy to LXC containers (CT-311, 312, 313) | APT install + systemd |
| 3 | Deploy Alloy to Proxmox nodes (pve-1, 2, 3) | APT install + systemd |
| 4 | Deploy Alloy to CoreOS VMs (VM-110, 120, 210, 220) | Podman container with journal bind-mount |
| 5 | Deploy Alloy to PBS (VM-900) | APT install + systemd |
| 6 | Verify all targets appear in Prometheus UI | Browse `http://10.10.100.56:9090/targets` |
| 7 | Verify logs flowing to Loki | Grafana Explore → Loki → `{job="systemd-journal"}` |
| 8 | Import Node Exporter Full dashboard (ID 1860) | Grafana import |

**Note:** CT-312 and CT-313 may need memory bump to 512MB to accommodate Alloy agent (~30–50MB).

### Phase 6A-3: Application Metrics + UniFi Syslog

| Step | Task | Method |
|------|------|--------|
| 1 | Enable Traefik Prometheus entrypoint | Update Traefik static config (Section 4.4) |
| 2 | Install pihole6_exporter on CT-311 | New `pihole-exporter` Ansible role |
| 3 | Enable remote syslog in UniFi Controller | Manual: Settings → System → Remote Logging → `10.10.100.56:514` |
| 4 | Enable CyberSecure traffic logging (UniFi 9.x) | Manual: Settings → CyberSecure → Traffic Logging |
| 5 | Verify UniFi logs in Loki | Grafana Explore → `{job="unifi"}` |
| 6 | Verify noise filtering working | Confirm no AP association spam: `{job="unifi"} |= "hostapd"` returns empty |
| 7 | Import Traefik + Pi-hole Grafana dashboards | Dashboard IDs 17346 and 21043 |
| 8 | Build custom "Colossus Overview" dashboard | Manual in Grafana (includes UniFi row) |
| 9 | Export dashboards as JSON → commit to Git | `grafana/dashboards/` in ansible repo |

### Phase 6A-4: Future Additions (Not in Initial Build)

| Item | When |
|------|------|
| Neo4j metrics endpoint | When dashboard proves value |
| PostgreSQL exporter | When dashboard proves value |
| Qdrant metrics | When dashboard proves value |
| Alertmanager notification receivers | When baseline metrics are established |
| PBS backup monitoring | When exporter integration confirmed |
| TrueNAS SNMP/Graphite | When TrueNAS VLAN strategy decided |

---

## 14. Proxmox API User Setup

Create a dedicated read-only user for the PVE Exporter:

```bash
# On any Proxmox node (cluster-wide)
pveum user add monitoring@pve --password "TEMP_PASSWORD"
pveum acl modify / -user monitoring@pve -role PVEAuditor
pveum user token add monitoring@pve monitoring --comment "Prometheus monitoring"
# Save the token secret — it cannot be retrieved later
```

Store the token value in Ansible Vault immediately:

```bash
ansible-vault encrypt_string '<TOKEN_VALUE>' --name 'pve_monitoring_token'
```

---

## 15. Security Considerations

- **Grafana:** Password-protected admin account. No anonymous access. No sign-ups. Gravatar disabled. Secure cookies enabled. Accessed via Traefik (HTTPS). Not exposed via Cloudflare Tunnel (internal only).
- **Prometheus:** Not exposed externally. Published port on VM for admin access only. Lifecycle API enabled for config reloads.
- **Loki:** Not exposed externally. Alloy agents push logs over internal network (HTTP, not HTTPS). Acceptable for same-VLAN traffic.
- **PVE Exporter:** Uses read-only API token (PVEAuditor role). Cannot modify cluster state.
- **Alertmanager:** Internal only. Silent default receiver until alert rules are tuned.
- **Alloy agents:** Run as systemd services with no inbound access required (Prometheus scrapes them, they push to Loki). Minimal attack surface.
- **Secrets:** Grafana admin password and PVE API token stored in Ansible Vault, templated into Butane config at build time. Secrets file on VM is mode 0600.
- **VM isolation:** Full kernel boundary between monitoring stack and host. Credentials and security logs are not accessible from the hypervisor layer (unlike LXC shared-kernel model).
- **UniFi syslog:** UDP 514 listener on VM-314 only. Filtered at ingestion — sensitive network topology details in firewall logs stay within the monitoring VM. Not exposed externally.

---

## 16. Resource Impact Assessment

| Host | Additional Load | Acceptable? |
|------|----------------|-------------|
| pve-3 | VM-314 uses ~4GB RAM, 60GB disk | Yes — pve-3 has capacity (Infra node) |
| pve-1, pve-2, pve-3 | Alloy agent: ~50MB RAM each | Negligible |
| CoreOS VMs | Alloy container: ~50–100MB RAM each | Acceptable — VMs have 4GB+ |
| LXC containers | Alloy agent: ~30–50MB RAM each | Tight on 256MB CTs — may need to bump CT-312, CT-313 to 512MB |
| PBS | Alloy agent: ~50MB RAM | Negligible |

**Total additional RAM across cluster:** ~4.5GB (mostly VM-314). No hardware upgrades needed.

---

## 17. Success Criteria

| # | Criterion | Validation |
|---|-----------|------------|
| 1 | Grafana accessible at `https://grafana.cogmai.com` | Browser test via Traefik |
| 2 | Proxmox dashboard showing all 3 nodes | Dashboard ID 10347 |
| 3 | Host metrics for all 11 managed hosts | Node Exporter dashboard ID 1860 |
| 4 | Traefik request metrics visible | Dashboard ID 17346 |
| 5 | Pi-hole query metrics visible | Dashboard ID 21043 |
| 6 | Logs from all hosts searchable in Loki | Grafana Explore → `{host=~".+"}` |
| 7 | UniFi firewall logs in Loki (filtered) | `{job="unifi"} |= "BLOCK"` returns results |
| 8 | UniFi AP noise absent from Loki | `{job="unifi"} |= "hostapd"` returns empty |
| 9 | "Colossus Overview" custom dashboard built | Single-pane view with UniFi row |
| 10 | VM-314 included in PBS backup schedule | `manage-pbs-backups.yml` |
| 11 | All config in Ansible + Git | `colossus-ansible` repo |
| 12 | VM-314 rebuildable from Ignition | Destroy + recreate test passes |

---

## 18. Rollback Plan

Because VM-314 is provisioned via Butane/Ignition, rollback is straightforward:

| Scenario | Action |
|----------|--------|
| Bad config deployed | SSH in, fix config file, `systemctl restart <service>` |
| Container image broken | Update Quadlet to previous pinned version, `systemctl daemon-reload && systemctl restart <service>` |
| VM corrupted | Destroy VM, recreate from Ignition (`create-vm.yml`). Metrics/log history is lost but regenerates automatically. Grafana dashboards restore from Git-committed JSON exports. |
| Need to revert to v1 design | Not applicable — v1 was never deployed. |

Prometheus and Loki data is ephemeral by design. The only durable artifacts are Grafana dashboard JSON files (committed to Git) and the Ansible Vault secrets.

---

## 19. References

| Resource | Purpose |
|----------|---------|
| [prometheus-pve-exporter](https://github.com/prometheus-pve/prometheus-pve-exporter) | Proxmox metrics |
| [Grafana Alloy docs](https://grafana.com/docs/alloy/latest/) | Unified agent (replaces Promtail + node_exporter) |
| [Loki documentation](https://grafana.com/docs/loki/latest/) | Log aggregation |
| [pihole6_exporter](https://github.com/bazmonk/pihole6_exporter) | Pi-hole v6 Prometheus exporter |
| [Traefik Prometheus metrics](https://doc.traefik.io/traefik/observability/metrics/prometheus/) | Built-in metrics configuration |
| [Podman Quadlet docs](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) | Quadlet .container and .network reference |
| [Grafana Dashboard 10347](https://grafana.com/grafana/dashboards/10347) | Proxmox via Prometheus |
| [Grafana Dashboard 1860](https://grafana.com/grafana/dashboards/1860) | Node Exporter Full |
| [Grafana Dashboard 17346](https://grafana.com/grafana/dashboards/17346) | Traefik Official |
| [Grafana Dashboard 21043](https://grafana.com/grafana/dashboards/21043) | Pi-hole v6 Stats |
| [Grafana Dashboard 13639](https://grafana.com/grafana/dashboards/13639) | Loki Logs Overview |
| [Migrate Promtail → Alloy](https://grafana.com/docs/alloy/latest/set-up/migrate/from-promtail/) | Migration guide (reference) |
| [Alloy syslog source](https://grafana.com/docs/alloy/latest/) | `loki.source.syslog` component for UniFi ingestion |
| [UniFi Remote Logging](https://logcentral.io/blog/how-to-configure-syslog-servers-in-unifi) | UniFi syslog configuration guide |
