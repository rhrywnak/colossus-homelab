# Colossus Monitoring & Observability Platform Design

**Version:** v1.1
**Date:** 2026-03-22
**Status:** Design — approved for phased implementation
**Repo:** `rhrywnak/colossus-observe`
**Previous:** `COLOSSUS_MONITORING_STACK_DESIGN_v2.md` (retired — Prometheus/Grafana/Loki/Alloy stack decommissioned 2026-03-22)

---

## 1. Why This Document Exists

The original monitoring stack (6 containers on VM-314, 12 Alloy agents, 5 Grafana dashboards) was decommissioned because it solved the wrong problem. It collected enormous amounts of data and presented it in detailed dashboards that nobody looked at. Critical signals were lost in noise. When VM-314 was migrated during the pve-3 replacement, all data was lost because it lived inside the VM — violating the golden rule.

This document defines the replacement: an AI-native observability platform that tells you what's wrong, predicts what's about to go wrong, and understands your applications — not just your infrastructure.

---

## 2. Design Principles

1. **Alert-first, not dashboard-first.** The system tells you what needs attention. Dashboards exist for drill-down after an alert, not for routine browsing.
2. **AI as the analysis layer.** Raw metrics and logs feed an LLM that understands context, spots trends, correlates events, and explains findings in plain English.
3. **Minimal moving parts.** One hub, lightweight agents, one AI service. Not six containers and twelve agents.
4. **Data externalized to ZFS.** The golden rule applies to monitoring data too.
5. **60-second intervals are sufficient.** This is a homelab, not a trading floor.
6. **Application awareness.** The platform understands colossus apps — their behavior, their resource patterns, their deployment history — not just the metal they run on.
7. **Incremental value.** Each phase delivers standalone value. Later phases build on earlier ones but don't invalidate them.

---

## 3. What Went Wrong With v1 (Postmortem)

| Problem | Impact |
|---------|--------|
| Dashboard-centric design | 5 pre-built dashboards with dozens of panels. Nobody sat in front of Grafana all day. |
| No meaningful alerts | Alertmanager deployed with a silent default receiver. Data flowed in and waited for a human. |
| Too many moving parts | 6 containers on VM-314, 12 Alloy agents (2 install methods), each with its own config format. |
| Data inside the VM | Violated the golden rule. All Prometheus/Loki/Grafana data lost on pve-3 migration. |
| All data, no intelligence | 18 scrape targets at 15s intervals. Collected everything, understood nothing. |
| Resource overhead | 4GB RAM, 60GB disk, ~50-100MB per Alloy agent across 12 hosts. Delivered: pretty graphs nobody checked. |

---

## 4. Architecture Overview

Three layers, each independently valuable:

```
┌─────────────────────────────────────────────────────────────────┐
│                    LAYER 3: AI Analysis                         │
│              colossus-observe analysis service                  │
│                                                                 │
│  Scheduled analysis ──► Beszel API (metrics history)            │
│  Event-triggered    ──► SSH (targeted logs from affected host)  │
│  Deployment-aware   ──► Semaphore/Git (change events)           │
│  App-aware          ──► Unified telemetry stream (JSONL)        │
│                         │                                       │
│                         ▼                                       │
│              Inference Provider Trait                            │
│              ├── Claude API (deep analysis)                     │
│              ├── Ollama (frequent local checks)                 │
│              └── vLLM (batch analysis)                          │
│                         │                                       │
│                         ▼                                       │
│              Email alerts + daily summaries                     │
└─────────────────────────────────────────────────────────────────┘
                          ▲
                          │ REST API + SSH + file read
                          │
┌─────────────────────────────────────────────────────────────────┐
│              LAYER 1+2: Beszel (off-the-shelf)                  │
│                                                                 │
│  VM-314 ── Beszel Hub (single container, PocketBase backend)    │
│            ├── Web UI (observe.cogmai.com)                      │
│            ├── REST API (metrics query, system status)          │
│            ├── Threshold alerts (SMTP → email)                  │
│            └── Authentik OIDC integration                       │
│                                                                 │
│  13 hosts ── Beszel Agent (single binary per host, ~5MB)        │
│              ├── CPU, memory, disk, disk I/O, network           │
│              ├── Temperatures, SMART, load average              │
│              ├── Podman container stats (CoreOS VMs)            │
│              └── ZFS pool health                                │
└─────────────────────────────────────────────────────────────────┘
                          ▲
                          │ Unified telemetry events
                          │
┌─────────────────────────────────────────────────────────────────┐
│              APPLICATION TELEMETRY (all sources)                 │
│                                                                 │
│  Every event from every source uses the same envelope schema.   │
│  Events organized by function (events, metrics, analysis),      │
│  not by origin. Enables cross-source correlation.               │
│                                                                 │
│  Producers: colossus apps, build scripts, Beszel alert export,  │
│             AI analysis service (self-telemetry)                │
│                                                                 │
│  Output: /data/telemetry/events/{YYYY-MM-DD}.jsonl              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. Layer 1+2: Beszel — Infrastructure Monitoring

### 5.1 Why Beszel

Beszel is a lightweight, open-source server monitoring platform (MIT license) purpose-built for homelabs and small deployments. It replaces our entire 6-container Prometheus/Grafana/Loki stack with a single hub container and lightweight agents.

| Feature | Old Stack | Beszel |
|---------|-----------|--------|
| Central components | 6 containers (Prometheus, Loki, Grafana, Alertmanager, PVE Exporter, Alloy) | 1 container (hub) |
| Per-host agents | Alloy (~50-100MB, 2 install methods) | Beszel agent (~5MB, single binary) |
| Alert configuration | Prometheus rules YAML + Alertmanager config | Web UI threshold config |
| Dashboard | Grafana (external) | Built-in web UI |
| Container monitoring | Requires Alloy + Prometheus scrape | Native Podman/Docker support |
| Auth integration | Manual Grafana config | Native OIDC (Authentik documented) |
| Data query API | PromQL + Loki LogQL | REST API (PocketBase) |
| Configuration | 8+ config files across 3 formats | Single hub, agent takes 1 SSH key |

### 5.2 Beszel Hub Deployment (VM-314)

Reuse VM-314 (destroy and recreate with updated Butane/Ignition).

| Property | Value |
|----------|-------|
| VMID | 314 |
| Name | observe |
| Node | pve-3 |
| IP | 10.10.100.56 |
| Cores | 2 |
| Memory | 2048MB (down from 4096MB — Beszel is much lighter) |
| Disk | 20GB (down from 60GB) |
| Data storage | virtiofs mount to `pbs-zfs/services/observe` on pve-3 |
| URL | `observe.cogmai.com` via Traefik |

**Key difference from v1:** Beszel data lives on the virtiofs-mounted ZFS dataset, not inside the VM. Golden rule respected.

Hub runs as a single Podman Quadlet container:

```ini
[Container]
Image=docker.io/henrygd/beszel:latest
ContainerName=beszel-hub
Volume=/mnt/data/observe/beszel:/beszel_data:rw
PublishPort=8090:8090
```

### 5.3 Beszel Agents

Single Go binary on each host, deployed as a systemd service. Communicates with hub via SSH — no exposed HTTP ports needed on agents.

**Deployment targets (13 hosts):**

| Host | Type | Agent Install Method |
|------|------|---------------------|
| pve-1, pve-2, pve-3 | Proxmox | Binary + systemd service |
| CT-311, CT-312, CT-313, CT-315 | LXC | Binary + systemd service |
| VM-110, VM-120, VM-210, VM-220 | CoreOS | Binary + systemd service (or container) |
| VM-316 (Authentik) | CoreOS | Binary + systemd service (or container) |
| VM-900 (PBS) | Debian | Binary + systemd service |

**Ansible role:** `roles/beszel-agent/` — replaces `roles/alloy-agent/`. Same deployment pattern (detect host type, install appropriately), much simpler config.

### 5.4 Beszel Built-in Alerts

Threshold alerts configured in Beszel web UI. SMTP delivery via Gmail app password.

**Priority alerts (configure immediately):**

| Alert | Threshold | Severity |
|-------|-----------|----------|
| Disk usage | > 85% | Warning |
| Disk usage | > 95% | Critical |
| Memory usage | > 90% sustained 5min | Warning |
| CPU usage | > 95% sustained 10min | Warning |
| System down | Host unreachable | Critical |
| Container stopped | Expected container not running | Critical |
| Temperature | > 80°C | Warning |

### 5.5 TrueNAS Drive Health — Priority Monitoring Target

The TrueNAS drives are aging and represent the weakest link in the backup chain. While Beszel agents can't run on TrueNAS directly (SSH is disabled), TrueNAS exposes SMART data through its web API. The AI analysis service should query TrueNAS SMART data as a first-class data source and flag any deterioration trends aggressively.

Priority SMART attributes to watch: Reallocated Sector Count, Current Pending Sector, Uncorrectable Error Count, Power-On Hours, Temperature, Spin Retry Count, Read Error Rate trends.

**Future consideration:** As TrueNAS drives age, a second NAS appliance may be needed to separate backup replication from telemetry/analysis archive storage. The architecture is designed with a NAS-agnostic warm storage path (see Section 9) to accommodate this without redesign.

### 5.6 Beszel + Authentik Integration

Beszel supports OIDC via PocketBase. Documented integration with Authentik exists. Configure as:

- Provider type: OAuth2/OIDC
- Redirect URI: `https://observe.cogmai.com/api/oauth2-redirect`
- Cookie domain: `.cogmai.com` (SSO with existing Authentik session)

---

## 6. Unified Telemetry Schema

### 6.1 Design Decision: Unified Envelope, Not Per-App Directories

Every telemetry event from every source — applications, build scripts, Beszel alert exports, the AI service itself — uses the same envelope schema and lands in the same event stream. Files are organized by **function** (events, metrics, analysis), not by origin.

**Why:** The AI layer's job is cross-source correlation. "After the v0.8.0 deploy, API latency went up AND pve-2 CPU spiked AND Qdrant query count doubled." If those facts are scattered across per-app directories, the AI service must understand infrastructure topology to assemble context. With a unified stream, one file read for one day gives the complete picture.

### 6.2 Envelope Schema

Every telemetry event has these fields:

```json
{
  "ts": "2026-03-22T14:32:01.123Z",
  "trace_id": "req-a7f3b2c1",
  "source": "colossus-legal",
  "host": "colossus-dev-app1",
  "environment": "dev",
  "version": "0.8.0",
  "category": "request",
  "severity": "info",
  "data": { }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `ts` | ISO 8601 | Event timestamp (UTC) |
| `trace_id` | String, nullable | Correlation ID linking parent request to child spans. All events within one HTTP request share the same `trace_id`. Null for standalone events (alerts, builds, deploys). |
| `source` | String | Producer name: `colossus-legal`, `colossus-ai`, `beszel`, `build`, `observe-service` |
| `host` | String | Host where the event occurred (matches Beszel/Ansible host names) |
| `environment` | String | `dev`, `prod`, `infra`, `build` |
| `version` | String, nullable | Application version (null for non-app events) |
| `category` | Enum | Event type — see Section 6.3 |
| `severity` | Enum | `debug`, `info`, `warn`, `error`, `critical` |
| `data` | JSON object | Category-specific payload — see Section 6.4 |

### 6.3 Event Categories

| Category | Producers | Description |
|----------|-----------|-------------|
| `request` | Colossus apps | HTTP request (method, path, status, duration, user) |
| `db_query` | Colossus apps | Database interaction (db, operation, duration, result count) |
| `llm_call` | Colossus apps | LLM/ONNX inference (model, operation, tokens, duration) |
| `error` | Any app | Structured error (type, message, context) |
| `deploy` | App startup, Semaphore | Deployment marker (version, git SHA, config hash) |
| `build` | Build scripts | Build completion (duration, resources, dependencies, size) |
| `alert` | Beszel export | Threshold breach (metric, value, threshold) |
| `metric` | Periodic export | Metric snapshot (from Beszel API or custom collection) |
| `analysis` | AI analysis service | AI analysis output (stored for history/learning) |
| `hardware` | TrueNAS API, SMART | Hardware health (SMART attributes, drive status, temperatures) |

### 6.4 Category Data Payloads

**`request`** — HTTP request telemetry:
```json
{
  "ts": "2026-03-22T14:32:01.123Z",
  "trace_id": "req-a7f3b2c1",
  "source": "colossus-legal",
  "host": "colossus-dev-app1",
  "environment": "dev",
  "version": "0.8.0",
  "category": "request",
  "severity": "info",
  "data": {
    "method": "POST",
    "path": "/api/documents/synthesize",
    "status": 200,
    "duration_ms": 1847,
    "user": "roman"
  }
}
```

**`db_query`** — Database interaction (child span of a request):
```json
{
  "ts": "2026-03-22T14:32:01.456Z",
  "trace_id": "req-a7f3b2c1",
  "source": "colossus-legal",
  "host": "colossus-dev-app1",
  "environment": "dev",
  "version": "0.8.0",
  "category": "db_query",
  "severity": "info",
  "data": {
    "db": "qdrant",
    "operation": "search",
    "collection": "document_embeddings",
    "duration_ms": 234,
    "result_count": 12
  }
}
```

Note: `trace_id: "req-a7f3b2c1"` links this Qdrant query to its parent HTTP request. The AI layer can reconstruct the full request lifecycle by grouping events on `trace_id`.

**`llm_call`** — LLM/ONNX inference:
```json
{
  "ts": "2026-03-22T14:32:01.789Z",
  "trace_id": "req-a7f3b2c1",
  "source": "colossus-legal",
  "host": "colossus-dev-app1",
  "environment": "dev",
  "version": "0.8.0",
  "category": "llm_call",
  "severity": "info",
  "data": {
    "model": "onnx/bge-small-en-v1.5",
    "operation": "embed",
    "input_tokens": 512,
    "duration_ms": 89
  }
}
```

**`deploy`** — Deployment marker (emitted on app startup):
```json
{
  "ts": "2026-03-22T14:30:00.000Z",
  "trace_id": null,
  "source": "colossus-legal",
  "host": "colossus-dev-app1",
  "environment": "dev",
  "version": "0.8.0",
  "category": "deploy",
  "severity": "info",
  "data": {
    "git_sha": "a1b2c3d",
    "rust_version": "1.88.0",
    "config_hash": "e4f5a6b7"
  }
}
```

**`build`** — Build completion:
```json
{
  "ts": "2026-03-22T15:00:00.000Z",
  "trace_id": null,
  "source": "build",
  "host": "build-legal-dev",
  "environment": "build",
  "version": "0.8.0",
  "category": "build",
  "severity": "info",
  "data": {
    "app": "colossus-legal",
    "duration_sec": 342,
    "peak_memory_mb": 6144,
    "peak_cpu_pct": 95,
    "cargo_profile": "release",
    "crate_count": 287,
    "binary_size_mb": 42,
    "docker_image_size_mb": 112,
    "cache_hit_ratio": 0.73,
    "success": true
  }
}
```

**`alert`** — Beszel threshold breach:
```json
{
  "ts": "2026-03-22T16:45:00.000Z",
  "trace_id": null,
  "source": "beszel",
  "host": "pve-2",
  "environment": "infra",
  "version": null,
  "category": "alert",
  "severity": "warning",
  "data": {
    "metric": "disk_usage_pct",
    "value": 86.2,
    "threshold": 85.0,
    "partition": "/dev-zfs"
  }
}
```

**`error`** — Structured application error:
```json
{
  "ts": "2026-03-22T14:32:02.000Z",
  "trace_id": "req-a7f3b2c1",
  "source": "colossus-legal",
  "host": "colossus-dev-app1",
  "environment": "dev",
  "version": "0.8.0",
  "category": "error",
  "severity": "error",
  "data": {
    "error_type": "database_timeout",
    "db": "neo4j",
    "operation": "query_relationships",
    "timeout_ms": 5000,
    "message": "Neo4j query exceeded timeout",
    "path": "/api/documents/123/relationships"
  }
}
```

**`hardware`** — TrueNAS/SMART health:
```json
{
  "ts": "2026-03-22T06:00:00.000Z",
  "trace_id": null,
  "source": "truenas-health",
  "host": "truenas",
  "environment": "infra",
  "version": null,
  "category": "hardware",
  "severity": "info",
  "data": {
    "drive": "/dev/sda",
    "model": "WDC WD40EFRX-68N32N0",
    "serial": "WD-WCC7K0ABC123",
    "power_on_hours": 48762,
    "temperature_c": 38,
    "reallocated_sectors": 0,
    "pending_sectors": 0,
    "uncorrectable_errors": 0,
    "read_error_rate": 0
  }
}
```

### 6.5 Trace ID (Correlation)

The `trace_id` field links related events within a single logical operation. When an HTTP request arrives at colossus-legal, the `tracing` subscriber generates a unique trace ID and attaches it to the request span. All child spans (database queries, LLM calls, errors) within that request inherit the same trace ID.

This enables the AI layer to reconstruct request lifecycles: "Request req-a7f3b2c1 to /api/documents/synthesize took 1847ms total: 234ms in Qdrant search (12 results), 89ms in ONNX embedding, 1524ms in synthesis generation."

Events that aren't part of a request flow (deploys, builds, alerts, hardware checks) have `trace_id: null`.

### 6.6 Implementation: Rust `tracing` Crate

The Rust `tracing` crate is the ecosystem standard for structured, hierarchical instrumentation. It provides:

- **Spans:** Hierarchical context ("this HTTP request contained these 3 database queries")
- **Events:** Structured log entries with typed fields
- **Subscribers:** Pluggable backends that consume span/event data
- **Layers:** Composable processing (filter, format, export)

Key crates:

| Crate | Purpose |
|-------|---------|
| `tracing` | Core instrumentation API (spans, events, macros) |
| `tracing-subscriber` | Subscriber framework with formatting layers |
| `tracing-appender` | Non-blocking file output (rolling daily files) |
| `serde` / `serde_json` | JSON serialization for the envelope schema |
| `uuid` | Trace ID generation |

The `colossus-observe` library crate provides a custom tracing subscriber that formats spans and events into the unified envelope schema (Section 6.2) and writes them to the telemetry JSONL files.

### 6.7 The `colossus-observe` Cargo Library Crate

A shared Rust library published as a cargo workspace member. Used by all colossus applications for consistent telemetry emission.

```
colossus-observe/
├── Cargo.toml              # Library crate
├── src/
│   ├── lib.rs              # Public API
│   ├── schema.rs           # TelemetryEvent struct, EventCategory, Severity enums
│   ├── telemetry.rs        # tracing subscriber: formats to envelope schema, writes JSONL
│   ├── trace_id.rs         # Trace ID generation and propagation
│   ├── spans.rs            # Pre-defined span helpers (http_request, db_query, llm_call)
│   ├── metrics.rs          # Lightweight metric helpers (counters, histograms)
│   ├── deploy.rs           # Deployment marker emission
│   ├── build.rs            # Build metric collection helpers
│   └── inference/          # Inference provider trait (shared with analysis service)
│       ├── mod.rs
│       ├── claude.rs       # Claude API client
│       ├── ollama.rs       # Ollama client
│       └── vllm.rs         # vLLM client
```

**Core struct (defined in `schema.rs`):**

```rust
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryEvent {
    pub ts: DateTime<Utc>,
    pub trace_id: Option<String>,
    pub source: String,
    pub host: String,
    pub environment: String,
    pub version: Option<String>,
    pub category: EventCategory,
    pub severity: Severity,
    pub data: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventCategory {
    Request,
    DbQuery,
    LlmCall,
    Error,
    Deploy,
    Build,
    Alert,
    Metric,
    Analysis,
    Hardware,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Debug,
    Info,
    Warn,
    Error,
    Critical,
}
```

**Usage in colossus-legal:**

```rust
use colossus_observe::{init_telemetry, emit_deploy_marker};

#[tokio::main]
async fn main() {
    // Initialize structured JSON telemetry
    // Writes to /data/telemetry/events/{date}.jsonl
    init_telemetry("colossus-legal", env!("CARGO_PKG_VERSION"));

    // Emit deployment marker
    emit_deploy_marker("colossus-legal", env!("CARGO_PKG_VERSION"));

    // ... rest of app startup
}
```

**Instrumented handler example:**

```rust
use tracing::instrument;

#[instrument(
    name = "synthesize_document",
    skip(state, body),
    fields(user = %user.username, version = env!("CARGO_PKG_VERSION"))
)]
async fn synthesize(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<SynthesizeRequest>,
) -> Result<Json<SynthesizeResponse>, AppError> {
    // Database spans created automatically by instrumented db clients
    let embeddings = state.qdrant.search(&body.query).await?;
    let context = state.neo4j.get_relationships(&body.doc_id).await?;
    let result = state.synthesizer.run(&embeddings, &context).await?;
    Ok(Json(result))
}
```

The `#[instrument]` macro from the `tracing` crate automatically creates a span that captures entry/exit timing, the user field, and any child spans (database calls, LLM calls) created within the function. The custom subscriber wraps each span in the unified envelope schema with the correct `trace_id`, `source`, `host`, and `category`.

**Rust learning opportunity:** The `tracing` crate is one of Rust's best-designed libraries. Its subscriber/layer composition pattern teaches trait objects, dynamic dispatch, and the builder pattern. The `#[instrument]` proc macro teaches how Rust macros generate code. The `TelemetryEvent` struct teaches serde derive macros, enums with `rename_all`, and `serde_json::Value` for flexible payloads.

### 6.8 Build Metrics

When builds move to dedicated VMs on pve-2 (and the Dell 7810), the build process itself emits telemetry using the unified envelope schema (see `build` category in Section 6.4).

The AI layer uses build metrics to detect:
- Build time regressions ("v0.8.0 takes 40% longer to build than v0.7.5 — check new dependencies")
- Resource requirements ("builds now peak at 6GB RAM — the build VM needs an upgrade")
- Dependency bloat ("crate count grew from 240 to 287 in this release")
- Cache effectiveness ("cache hit ratio dropped from 90% to 73% — likely a lockfile change")

Build metrics are emitted by a wrapper script around `build-release.sh` that captures timing and resource usage via `time` and `/proc` stats, then writes the JSON entry to the telemetry directory using the `colossus-observe` library's `emit_build_event()` helper.

---

## 7. Layer 3: AI Analysis Service

### 7.1 Purpose

Transform raw observability data into actionable operational intelligence. The AI layer doesn't just report metrics — it understands the infrastructure, the applications, and the relationships between them.

The pinnacle goal: understand colossus application behavior and user patterns. When a new version is deployed, detect resource changes compared to earlier versions. Correlate infrastructure metrics with application telemetry with deployment events. Suggest improvements to code or infrastructure configuration based on observed patterns.

### 7.2 Data Sources

| Source | Access Method | Data Type |
|--------|---------------|-----------|
| Beszel metrics | REST API (PocketBase) | CPU, memory, disk, network, container stats, temperatures, SMART |
| Unified telemetry | File read (JSONL on virtiofs) | All app events, builds, deploys, errors — unified envelope |
| System logs | SSH + `journalctl` (on-demand) | Service failures, OOM kills, kernel messages, container exits |
| Deployment history | Semaphore API or Git log | Version changes, timestamps, commit messages |
| TrueNAS health | TrueNAS REST API | SMART data, pool status, drive temperatures |
| Beszel alerts | Webhook or SMTP parse | Threshold breaches (trigger for deep analysis) |

### 7.3 Analysis Modes

**Mode 1: Scheduled summary (daily or every 6 hours)**

The analysis service queries all data sources, assembles a comprehensive context window, and sends it to the LLM with a system prompt that says: "You are the operations advisor for the Colossus homelab. Here is the current state of all systems. Identify anything that needs attention, predict upcoming issues, and recommend actions."

Output: email with sections for "Healthy," "Warnings," "Action Required," and "Predictions."

Example output:
```
COLOSSUS DAILY HEALTH REPORT — 2026-03-23 06:00

HEALTHY (10/13 hosts nominal)
  All PROD services running. No errors in colossus-legal logs.
  PBS backups completed for all 10 guests. TrueNAS sync verified.
  ZFS pool health: all pools ONLINE, no errors.

WARNINGS
  ⚠ pve-2 disk usage at 72% (was 68% last week, 63% two weeks ago).
    Growth rate: ~2.5%/week. At this rate, 85% threshold in ~5 weeks.
    Recommendation: Review dev-zfs dataset usage. `zfs list -o name,used,avail`
    shows dev-zfs/models at 340GB — consider pruning old ONNX cache.

  ⚠ colossus-legal-dev: average API response time increased from 180ms to
    310ms after v0.8.0 deployment (2026-03-22 14:30). The increase is
    concentrated in /api/documents/synthesize (was 420ms, now 890ms).
    Telemetry shows Qdrant search calls per request doubled from 2 to 4.
    Likely cause: commit a1b2c3d "add multi-vector search for hybrid retrieval."
    Recommendation: Review batch query optimization or add caching layer.

  ⚠ TrueNAS drive /dev/sdb: Power-On Hours at 52,341. Reallocated sector
    count increased from 0 to 2 over the past 30 days. Not critical yet,
    but trend warrants close monitoring. Consider planning drive replacement
    within 6 months.

ACTION REQUIRED
  None.

PREDICTIONS
  PBS backup duration for VM-210 has increased linearly over 30 days
  (32s → 91s). Will exceed the 5-minute vzdump timeout in ~45 days.
  Cause: dev-zfs/postgres dataset growing at ~1GB/day.
  Recommendation: Review PostgreSQL vacuum and WAL retention settings.
```

**Mode 2: Event-triggered deep analysis**

When Beszel fires a threshold alert (e.g., "VM-110 memory > 90%"), the AI service:
1. Pulls 24-hour metrics history for the affected host from Beszel API
2. SSHes into the host and grabs recent journal entries for relevant services
3. Pulls application telemetry events from the same time window (grep by `host`)
4. Checks Semaphore/Git for recent deployments
5. Sends all context to Claude with: "This host just triggered a memory alert. Here's the full context. What happened and what should be done?"

Output: enriched alert email with root cause analysis and recommendation — not just "memory > 90%."

**Mode 3: Deployment comparison**

Triggered after each Semaphore deployment completes. The service:
1. Identifies the deployment from the `deploy` category events in the telemetry stream
2. Pulls 2-hour windows of telemetry from before and after the deployment (filter by `host` + `source`)
3. Pulls Beszel metrics for the same windows
4. Sends to Claude with: "Compare the before/after. Did this deployment change resource usage, latency, error rates, or behavior patterns?"

Output: deployment impact report. Catches regressions before users notice them.

### 7.4 Inference Provider Trait

The analysis service uses a trait abstraction for LLM inference, allowing different providers for different use cases:

```rust
#[async_trait]
pub trait InferenceProvider: Send + Sync {
    async fn complete(&self, prompt: &str, system: &str) -> Result<String>;
    fn name(&self) -> &str;
    fn model(&self) -> &str;
}
```

| Provider | Use Case | Cost | Latency |
|----------|----------|------|---------|
| Claude API | Deep analysis, deployment comparison, root cause | Per-token | ~10-30s |
| Ollama (local) | Frequent health checks, log parsing, anomaly detection | Free | ~5-60s depending on model |
| vLLM (local) | Batch analysis, historical trend processing | Free | Variable |

Start with Claude API only. Add local models when the Dell 7810 becomes a dev/inference node.

### 7.5 Analysis Service Architecture

The analysis service is a Rust binary (part of the `colossus-observe` workspace) that runs on VM-314 alongside the Beszel hub.

```
colossus-observe-service/
├── Cargo.toml
├── src/
│   ├── main.rs              # CLI entry point (subcommands: run, analyze, report)
│   ├── config.rs            # TOML config (Beszel URL, SMTP, Claude API, SSH keys,
│   │                        #   storage paths, retention, warm storage endpoint)
│   ├── scheduler.rs         # Cron-like scheduled analysis triggers
│   ├── collector/
│   │   ├── beszel.rs        # Beszel REST API client
│   │   ├── telemetry.rs     # Unified JSONL reader (filter by category, host, time)
│   │   ├── logs.rs          # SSH + journalctl log retriever
│   │   ├── deployments.rs   # Semaphore API / Git log reader
│   │   └── truenas.rs       # TrueNAS REST API client (SMART data, pool status)
│   ├── analyzer/
│   │   ├── daily.rs         # Daily summary analysis prompt assembly
│   │   ├── event.rs         # Event-triggered deep analysis
│   │   ├── deployment.rs    # Deployment comparison analysis
│   │   └── prompts/         # System prompts (versioned, tunable)
│   ├── notifier/
│   │   ├── email.rs         # SMTP email delivery (lettre crate)
│   │   └── formatter.rs     # Markdown → email HTML formatting
│   ├── storage/
│   │   ├── retention.rs     # Hot→warm tiering, cleanup job
│   │   └── warm.rs          # NAS-agnostic warm storage access (NFS/SSH)
│   └── inference/           # Re-exports from colossus-observe library
```

---

## 8. Data Flow Summary

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  Proxmox     │    │  CoreOS VMs  │    │  LXC / PBS   │
│  Hosts (3)   │    │  (5 VMs)     │    │  (5 hosts)   │
└──────┬───────┘    └──────┬───────┘    └──────┬───────┘
       │                   │                   │
       │  Beszel agent     │  Beszel agent     │  Beszel agent
       │  (binary)         │  (binary)         │  (binary)
       │                   │                   │
       └─────────┬─────────┴─────────┬─────────┘
                 │    SSH (metrics)   │
                 ▼                    │
          ┌──────────────┐           │
          │  Beszel Hub  │           │
          │  (VM-314)    │           │
          │  REST API    │──── Threshold alerts ──► Email (SMTP)
          └──────┬───────┘
                 │
                 │  REST API (metrics history)
                 ▼
          ┌──────────────┐    ┌───────────────────────────┐
          │  AI Analysis │◄───│  Unified Telemetry (JSONL) │
          │  Service     │    │  events/{date}.jsonl        │
          │  (VM-314)    │    │  on virtiofs mount          │
          │              │    └───────────────────────────┘
          │              │    ┌───────────────────────────┐
          │              │◄───│  SSH → journalctl          │
          │              │    │  (on-demand, targeted)      │
          │              │    └───────────────────────────┘
          │              │    ┌───────────────────────────┐
          │              │◄───│  TrueNAS REST API          │
          │              │    │  (SMART, pool health)       │
          │              │    └───────────────────────────┘
          │              │    ┌───────────────────────────┐
          │              │◄───│  Semaphore API / Git       │
          │              │    │  (deployment events)        │
          └──────┬───────┘    └───────────────────────────┘
                 │
                 │  Claude API / Ollama
                 ▼
          ┌──────────────┐
          │  Email       │
          │  Summary     │
          │  + Alerts    │
          └──────────────┘
```

---

## 9. Storage Architecture

### 9.1 Two-Tier Storage Model

Telemetry data lives in two tiers based on age:

| Tier | Location | Media | Retention | Access Pattern |
|------|----------|-------|-----------|----------------|
| **Hot** | pve-3 SSD (`pbs-zfs/services/observe`) | SSD | 7–30 days | Real-time: daily summaries, event-triggered analysis |
| **Warm** | NAS (configurable endpoint) | HDD | 90–365 days | Batch: trend prediction, historical comparison, long-term patterns |

**Hot → Warm transition:** ZFS replication already copies pve-3 datasets to TrueNAS daily. A retention cleanup job on pve-3 removes JSONL files older than the hot retention window. The warm copies persist on the NAS for the longer retention period.

**NAS-agnostic design:** The warm storage path is configured as an endpoint in the analysis service config (NFS mount path or SSH target), not hardcoded to TrueNAS. When a second NAS is added — to separate backup replication from telemetry archive, or to replace aging drives — only the config changes. No code changes.

### 9.2 ZFS Datasets

**New dataset on pve-3:**
```
pbs-zfs/services/observe/          # Parent — virtiofs mounted into VM-314
├── beszel/                        # Beszel hub data (PocketBase DB)
└── telemetry/                     # Unified telemetry stream
    └── events/                    # {YYYY-MM-DD}.jsonl files
```

**New datasets on pve-1 and pve-2 (for app telemetry writes):**
```
prod-zfs/telemetry/                # PROD apps write here via virtiofs
dev-zfs/telemetry/                 # DEV apps write here via virtiofs
```

App VMs write telemetry events to their local virtiofs-mounted telemetry dataset. The AI analysis service on VM-314 reads these files via SSH or NFS (not virtiofs — VM-314 can't mount pve-1/pve-2 datasets directly). Alternatively, a lightweight sync job copies JSONL files from pve-1/pve-2 telemetry datasets to the central `pbs-zfs/services/observe/telemetry/events/` directory on pve-3.

### 9.3 File Layout

```
/data/telemetry/events/
├── 2026-03-20.jsonl     # All events from all sources, March 20
├── 2026-03-21.jsonl     # All events from all sources, March 21
├── 2026-03-22.jsonl     # Today's events (actively written)
```

One file per day, newline-delimited JSON. Append-only. Safe for concurrent writes (multiple app instances) and reads (analysis service).

### 9.4 Storage Growth Estimates

| Data Source | Daily Volume | 30-Day Volume | 365-Day Volume |
|-------------|-------------|---------------|----------------|
| App telemetry (current usage) | ~1 MB | ~30 MB | ~365 MB |
| App telemetry (10x growth) | ~10 MB | ~300 MB | ~3.6 GB |
| Build metrics | ~10 KB | ~300 KB | ~3.6 MB |
| Beszel alert exports | ~50 KB | ~1.5 MB | ~18 MB |
| Hardware/SMART checks | ~100 KB | ~3 MB | ~36 MB |
| AI analysis outputs | ~500 KB | ~15 MB | ~180 MB |
| **Total (current)** | **~2 MB** | **~50 MB** | **~600 MB** |
| **Total (10x growth)** | **~11 MB** | **~320 MB** | **~4 GB** |

Telemetry storage is not the bottleneck. Even at 10x growth, a full year fits in under 5GB. The real storage pressure on pve-3 is PBS backup staging (separate dataset, separate concern).

### 9.5 Retention Policy

| Tier | Retention | Cleanup Method |
|------|-----------|---------------|
| Hot (pve-3 SSD) | 30 days | systemd timer runs `find /data/telemetry/events/ -name "*.jsonl" -mtime +30 -delete` |
| Warm (NAS) | 365 days | ZFS replication preserves data; NAS-side cleanup via TrueNAS snapshot policy or manual |
| Beszel metrics (PocketBase) | 90 days | Beszel built-in retention config |

Retention values are configurable in the analysis service TOML config.

### 9.6 virtiofs Mounts

| VM | Host | ZFS Dataset | Mapping ID | Guest Mount |
|----|------|-------------|------------|-------------|
| VM-220 (DEV app) | pve-2 | `dev-zfs/telemetry` | `dev-telemetry` | `/var/mnt/data/telemetry` |
| VM-120 (PROD app) | pve-1 | `prod-zfs/telemetry` | `prod-telemetry` | `/var/mnt/data/telemetry` |
| VM-314 (observe) | pve-3 | `pbs-zfs/services/observe` | `observe-data` | `/var/mnt/data/observe` |

Add `dev-zfs/telemetry` and `prod-zfs/telemetry` to ZFS replication dataset lists in host_vars.

---

## 10. Phased Implementation

### Phase 1: Beszel Deploy (1 session, ~3 hours)

**Goal:** Infrastructure monitoring live with threshold alerts. Zero application changes.

| Step | Task |
|------|------|
| 1 | Create ZFS dataset `pbs-zfs/services/observe` on pve-3 |
| 2 | Create Proxmox directory mapping `observe-data` |
| 3 | Write Butane config for VM-314 (Beszel hub container, virtiofs mount) |
| 4 | Destroy old VM-314, create new VM-314 from updated Butane/Ignition |
| 5 | Configure Beszel hub (admin account, SMTP for alerts) |
| 6 | Create Ansible role `beszel-agent` |
| 7 | Deploy agents to all 13 hosts |
| 8 | Configure threshold alerts in Beszel UI |
| 9 | Add Traefik route for `observe.cogmai.com` |
| 10 | Configure Authentik OIDC for Beszel |
| 11 | Add VM-314 to PBS backup schedule, ZFS replication |
| 12 | Verify: all hosts reporting, alerts fire on test, email delivered |

**Exit gate:** 13/13 hosts monitored, threshold alerts working, Beszel accessible via Traefik with Authentik SSO.

### Phase 2: Application Structured Logging (1-2 sessions)

**Goal:** colossus-legal emits structured JSON telemetry using the unified envelope schema.

| Step | Task |
|------|------|
| 1 | Create `colossus-observe` library crate in workspace |
| 2 | Implement `TelemetryEvent` struct and enums (`schema.rs`) |
| 3 | Implement custom tracing subscriber that writes unified envelope JSONL (`telemetry.rs`) |
| 4 | Implement trace ID generation and propagation (`trace_id.rs`) |
| 5 | Implement span helpers: `http_request`, `db_query`, `llm_call` (`spans.rs`) |
| 6 | Implement `emit_deploy_marker()` (`deploy.rs`) |
| 7 | Add `colossus-observe` dependency to colossus-legal backend |
| 8 | Instrument Axum handlers with `#[instrument]` |
| 9 | Instrument database clients (Neo4j, PostgreSQL, Qdrant) with tracing spans |
| 10 | Create ZFS datasets for telemetry on pve-1 and pve-2 |
| 11 | Add virtiofs mounts to app VM Butane configs |
| 12 | Rebuild and deploy colossus-legal with telemetry enabled |
| 13 | Verify: JSONL files appearing with correct envelope schema, trace IDs linking parent/child |

**Exit gate:** colossus-legal producing unified envelope telemetry on both DEV and PROD. Files on ZFS, replicated to TrueNAS.

### Phase 3: AI Analysis MVP (1-2 sessions)

**Goal:** Daily email summary from Beszel metrics + unified telemetry. First taste of AI-powered operations.

| Step | Task |
|------|------|
| 1 | Implement Beszel REST API client (`collector/beszel.rs`) |
| 2 | Implement unified JSONL reader with category/host/time filters (`collector/telemetry.rs`) |
| 3 | Implement TrueNAS SMART data collector (`collector/truenas.rs`) |
| 4 | Implement inference provider trait + Claude API client |
| 5 | Implement daily analysis prompt assembly (`analyzer/daily.rs`) |
| 6 | Implement email delivery (lettre crate, Gmail SMTP) |
| 7 | Create systemd timer for daily analysis (06:00) |
| 8 | Deploy to VM-314 as Podman Quadlet container |
| 9 | Tune prompts based on first week of daily reports |

**Exit gate:** Receiving daily email with health summary, warnings, predictions. AI correctly identifies at least one non-obvious trend in the first week.

### Phase 4: Event-Triggered Analysis (1 session)

**Goal:** Beszel threshold alerts trigger deep AI analysis with log correlation.

| Step | Task |
|------|------|
| 1 | Implement SSH log retriever (`collector/logs.rs`) |
| 2 | Implement event-triggered analysis mode (`analyzer/event.rs`) |
| 3 | Connect Beszel alerts → AI service (webhook or SMTP parse) |
| 4 | Implement enriched alert email formatting |
| 5 | Test with simulated alerts (fill a test disk, stop a test container) |

**Exit gate:** Alert emails include root cause analysis and recommendations, not just threshold notifications.

### Phase 5: Deployment Comparison (1 session)

**Goal:** Automatic before/after analysis on every Semaphore deployment.

| Step | Task |
|------|------|
| 1 | Implement deployment event detection from telemetry stream (`deploy` category) |
| 2 | Implement Semaphore API client or Git log parser (`collector/deployments.rs`) |
| 3 | Implement deployment comparison prompt — before/after metrics + telemetry (`analyzer/deployment.rs`) |
| 4 | Implement deployment impact report email |

**Exit gate:** Every deployment to DEV or PROD generates an impact report. Regressions caught before users notice.

### Phase 6: Build Metrics (when dev VMs are operational)

**Goal:** Build processes emit telemetry using the unified envelope. AI tracks build health.

| Step | Task |
|------|------|
| 1 | Implement `emit_build_event()` in `colossus-observe` library (`build.rs`) |
| 2 | Create build metrics wrapper script (wraps build-release.sh) |
| 3 | Add build metrics to daily analysis prompt |
| 4 | Add build VM telemetry datasets to ZFS replication |

**Exit gate:** Build regressions (time, size, resource usage) detected and reported automatically.

### Phase 7: LLM Observability (future — colossus-observe full scope)

**Goal:** Full LLM call tracing, prompt versioning, eval benchmarks, LLM-as-judge.

This phase transforms colossus-observe from a monitoring add-on into a full observability platform serving all colossus applications. Design deferred until Phases 1-5 are operational and learnings are incorporated.

---

## 11. Repository Structure

colossus-observe is a Cargo workspace:

```
colossus-observe/                    # rhrywnak/colossus-observe
├── Cargo.toml                       # Workspace root
├── crates/
│   ├── colossus-observe/            # Library crate (used by all colossus apps)
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── schema.rs            # TelemetryEvent, EventCategory, Severity
│   │       ├── telemetry.rs         # tracing subscriber (unified envelope output)
│   │       ├── trace_id.rs          # Trace ID generation + propagation
│   │       ├── spans.rs             # Pre-defined span helpers
│   │       ├── metrics.rs           # Metric helpers
│   │       ├── deploy.rs            # Deployment markers
│   │       ├── build.rs             # Build metric helpers
│   │       └── inference/           # Inference provider trait
│   │           ├── mod.rs
│   │           ├── claude.rs
│   │           ├── ollama.rs
│   │           └── vllm.rs
│   └── colossus-observe-service/    # Binary crate (analysis service on VM-314)
│       ├── Cargo.toml
│       └── src/
│           ├── main.rs
│           ├── config.rs
│           ├── scheduler.rs
│           ├── collector/
│           │   ├── beszel.rs
│           │   ├── telemetry.rs
│           │   ├── logs.rs
│           │   ├── deployments.rs
│           │   └── truenas.rs
│           ├── analyzer/
│           │   ├── daily.rs
│           │   ├── event.rs
│           │   ├── deployment.rs
│           │   └── prompts/
│           ├── notifier/
│           │   ├── email.rs
│           │   └── formatter.rs
│           ├── storage/
│           │   ├── retention.rs
│           │   └── warm.rs
│           └── inference/
├── frontend/                        # React UI (future — Phase 7)
└── prompts/                         # Versioned analysis prompts
    ├── daily_summary.md
    ├── event_analysis.md
    └── deployment_comparison.md
```

---

## 12. Naming Changes

| Old Name | New Name | Reason |
|----------|----------|--------|
| colossus-llm-observe | colossus-observe | Scope expanded beyond LLM tracing to full platform observability |
| VM-314 "monitoring" | VM-314 "observe" | Reflects new purpose and project name |
| grafana.cogmai.com | observe.cogmai.com | Beszel UI replaces Grafana |
| roles/alloy-agent | roles/beszel-agent | New agent technology |

---

## 13. Success Criteria

| # | Criterion | Phase |
|---|-----------|-------|
| 1 | All 13 hosts monitored in Beszel with zero gaps | 1 |
| 2 | Threshold alerts fire and email arrives within 5 minutes | 1 |
| 3 | colossus-legal produces unified envelope JSONL telemetry with trace IDs | 2 |
| 4 | Daily AI health report identifies at least one actionable insight per week | 3 |
| 5 | TrueNAS drive health trends tracked and reported in daily summary | 3 |
| 6 | Event-triggered alerts include root cause analysis | 4 |
| 7 | Deployment comparison catches a version regression | 5 |
| 8 | Build metric trends visible in AI reports | 6 |
| 9 | No monitoring data lost on VM rebuild (golden rule) | All |
| 10 | Hot/warm storage tiering working with configurable retention | All |

---

## 14. Final Note

> The old stack failed because it answered the question "what are my metrics?" Nobody asked that question. The new platform answers: "what do I need to know right now, what's coming next, and why is my app behaving differently after that last deploy?" That's the only question that matters for a one-person homelab operation.
