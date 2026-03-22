# Colossus Monitoring & Observability Platform Design

**Version:** v1.0
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
│  App-aware          ──► Structured app logs (virtiofs)          │
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
                          │ REST API + SSH
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
                          │ Structured JSON logs
                          │
┌─────────────────────────────────────────────────────────────────┐
│              APPLICATION TELEMETRY (instrumented apps)           │
│                                                                 │
│  colossus-legal ── tracing crate + JSON subscriber              │
│  colossus-ai    ── same telemetry library (colossus-observe)    │
│  colossus-observe ── self-instrumented                          │
│  Build VMs      ── build metrics (duration, resources, errors)  │
│                                                                 │
│  Output: structured JSON logs on virtiofs mount                 │
│          /data/telemetry/{app}/{date}.jsonl                     │
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

### 5.5 Beszel + Authentik Integration

Beszel supports OIDC via PocketBase. Documented integration with Authentik exists. Configure as:

- Provider type: OAuth2/OIDC
- Redirect URI: `https://observe.cogmai.com/api/oauth2-redirect`
- Cookie domain: `.cogmai.com` (SSO with existing Authentik session)

---

## 6. Application Telemetry

This is the data that makes the AI layer useful beyond basic infrastructure monitoring. Every colossus application emits structured, machine-parseable telemetry that describes its behavior.

### 6.1 Telemetry Categories

**Category A: Request telemetry**
Every HTTP request produces a structured log entry:

```json
{
  "ts": "2026-03-22T14:32:01.123Z",
  "level": "INFO",
  "span": "http_request",
  "method": "POST",
  "path": "/api/documents/synthesize",
  "status": 200,
  "duration_ms": 1847,
  "user": "roman",
  "version": "0.8.0"
}
```

**Category B: Database interaction**
Each database call within a request is a child span:

```json
{
  "ts": "2026-03-22T14:32:01.456Z",
  "level": "INFO",
  "span": "db_query",
  "parent_span": "http_request",
  "db": "qdrant",
  "operation": "search",
  "collection": "document_embeddings",
  "duration_ms": 234,
  "result_count": 12
}
```

**Category C: LLM / AI operations**
Token counts, inference times, model info:

```json
{
  "ts": "2026-03-22T14:32:01.789Z",
  "level": "INFO",
  "span": "llm_call",
  "parent_span": "http_request",
  "model": "onnx/bge-small-en-v1.5",
  "operation": "embed",
  "input_tokens": 512,
  "duration_ms": 89
}
```

**Category D: Deployment markers**
Emitted on application startup:

```json
{
  "ts": "2026-03-22T14:30:00.000Z",
  "level": "INFO",
  "event": "app_start",
  "version": "0.8.0",
  "git_sha": "a1b2c3d",
  "rust_version": "1.88.0",
  "environment": "dev",
  "host": "colossus-dev-app1"
}
```

**Category E: Error events**
Structured errors with context, not raw stack traces:

```json
{
  "ts": "2026-03-22T14:32:02.000Z",
  "level": "ERROR",
  "span": "http_request",
  "error_type": "database_timeout",
  "db": "neo4j",
  "operation": "query_relationships",
  "timeout_ms": 5000,
  "message": "Neo4j query exceeded timeout",
  "path": "/api/documents/123/relationships"
}
```

### 6.2 Implementation: Rust `tracing` Crate

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
| `serde_json` | JSON serialization for structured output |

**Output destination:** Structured JSON logs written to the virtiofs mount at `/data/telemetry/{app}/{date}.jsonl`. One file per day, newline-delimited JSON. The AI analysis layer reads these files directly — no log shipping infrastructure needed.

### 6.3 The `colossus-observe` Cargo Library Crate

A shared Rust library (`colossus-observe`) published as a cargo workspace member, providing:

```
colossus-observe/
├── Cargo.toml              # Library crate
├── src/
│   ├── lib.rs              # Public API
│   ├── telemetry.rs        # tracing subscriber setup (JSON file output)
│   ├── spans.rs            # Pre-defined span types (http_request, db_query, llm_call)
│   ├── metrics.rs          # Lightweight metric helpers (counters, histograms)
│   ├── deploy.rs           # Deployment marker emission
│   └── inference/          # Inference provider trait (shared with analysis service)
│       ├── mod.rs
│       ├── claude.rs       # Claude API client
│       ├── ollama.rs       # Ollama client
│       └── vllm.rs         # vLLM client
```

**Usage in colossus-legal:**

```rust
use colossus_observe::{init_telemetry, emit_deploy_marker};

#[tokio::main]
async fn main() {
    // Initialize structured JSON logging to /data/telemetry/colossus-legal/
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

The `#[instrument]` macro from the `tracing` crate automatically creates a span that captures entry/exit timing, the user field, and any child spans (database calls, LLM calls) created within the function. No manual log statements needed.

### 6.4 Build Metrics

When builds move to dedicated VMs on pve-2 (and the Dell 7810), the build process itself becomes telemetry:

```json
{
  "ts": "2026-03-22T15:00:00.000Z",
  "event": "build_complete",
  "app": "colossus-legal",
  "version": "0.8.0",
  "build_host": "build-legal-dev",
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
```

The AI layer uses this to detect:
- Build time regressions ("v0.8.0 takes 40% longer to build than v0.7.5 — check new dependencies")
- Resource requirements ("builds now peak at 6GB RAM — the build VM needs an upgrade")
- Dependency bloat ("crate count grew from 240 to 287 in this release")
- Cache effectiveness ("cache hit ratio dropped from 90% to 73% — likely a lockfile change")

Build metrics are emitted by a wrapper script around `build-release.sh` that captures timing and resource usage via `time` and `/proc` stats, then writes the JSON entry to the telemetry directory.

---

## 7. Layer 3: AI Analysis Service

### 7.1 Purpose

Transform raw observability data into actionable operational intelligence. The AI layer doesn't just report metrics — it understands the infrastructure, the applications, and the relationships between them.

### 7.2 Data Sources

| Source | Access Method | Data Type |
|--------|---------------|-----------|
| Beszel metrics | REST API (PocketBase) | CPU, memory, disk, network, container stats, temperatures, SMART |
| Application telemetry | File read (virtiofs JSONL) | Request durations, DB queries, LLM calls, errors, deployment markers |
| System logs | SSH + `journalctl` (on-demand) | Service failures, OOM kills, kernel messages, container exits |
| Deployment history | Semaphore API or Git log | Version changes, timestamps, commit messages |
| Build metrics | File read (virtiofs JSONL) | Build duration, resource usage, dependency changes |
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
3. Pulls application telemetry logs from the same time window
4. Checks Semaphore/Git for recent deployments
5. Sends all context to Claude with: "This host just triggered a memory alert. Here's the full context. What happened and what should be done?"

Output: enriched alert email with root cause analysis and recommendation — not just "memory > 90%."

**Mode 3: Deployment comparison**

Triggered after each Semaphore deployment completes. The service:
1. Identifies the deployment (app, version, environment, timestamp)
2. Pulls 2-hour windows of telemetry from before and after the deployment
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
│   ├── config.rs            # TOML config (Beszel URL, SMTP, Claude API, SSH keys)
│   ├── scheduler.rs         # Cron-like scheduled analysis triggers
│   ├── collector/
│   │   ├── beszel.rs        # Beszel REST API client
│   │   ├── telemetry.rs     # Application telemetry JSONL reader
│   │   ├── logs.rs          # SSH + journalctl log retriever
│   │   └── deployments.rs   # Semaphore API / Git log reader
│   ├── analyzer/
│   │   ├── daily.rs         # Daily summary analysis prompt assembly
│   │   ├── event.rs         # Event-triggered deep analysis
│   │   ├── deployment.rs    # Deployment comparison analysis
│   │   └── prompts/         # System prompts (versioned, tunable)
│   ├── notifier/
│   │   ├── email.rs         # SMTP email delivery (lettre crate)
│   │   └── formatter.rs     # Markdown → email HTML formatting
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
          ┌──────────────┐    ┌───────────────────────┐
          │  AI Analysis │◄───│  App Telemetry (JSONL) │
          │  Service     │    │  on virtiofs mounts    │
          │  (VM-314)    │    └───────────────────────┘
          │              │    ┌───────────────────────┐
          │              │◄───│  SSH → journalctl     │
          │              │    │  (on-demand logs)      │
          │              │    └───────────────────────┘
          │              │    ┌───────────────────────┐
          │              │◄───│  Semaphore API / Git  │
          │              │    │  (deployment events)   │
          └──────┬───────┘    └───────────────────────┘
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

## 9. Storage Layout

### 9.1 ZFS Dataset

New dataset on pve-3:

```
pbs-zfs/services/observe/          # Parent dataset
├── beszel/                        # Beszel hub data (PocketBase DB, agent configs)
└── telemetry/                     # Application telemetry JSONL files
    ├── colossus-legal/            # Written by app VMs via virtiofs
    ├── colossus-ai/               # Future
    ├── colossus-observe/          # Self-telemetry
    └── builds/                    # Build metrics from dev VMs
```

### 9.2 Telemetry File Convention

```
/data/telemetry/{app}/{YYYY-MM-DD}.jsonl
```

One file per app per day. Newline-delimited JSON. Rotated daily. Retention: 90 days (configurable). Files are append-only — safe for concurrent writes from the application and reads from the analysis service.

### 9.3 virtiofs Mounts

Application VMs need a new virtiofs mount for telemetry output. This uses the existing mount pattern — ZFS dataset on host, directory mapping, virtiofs device, systemd mount unit in Butane.

| VM | Host | ZFS Dataset | Mapping ID | Guest Mount |
|----|------|-------------|------------|-------------|
| VM-220 (DEV app) | pve-2 | `dev-zfs/telemetry` | `dev-telemetry` | `/var/mnt/data/telemetry` |
| VM-120 (PROD app) | pve-1 | `prod-zfs/telemetry` | `prod-telemetry` | `/var/mnt/data/telemetry` |
| VM-314 (observe) | pve-3 | `pbs-zfs/services/observe` | `observe-data` | `/var/mnt/data/observe` |

**Note:** Telemetry data on pve-1/pve-2 gets replicated to TrueNAS via the existing ZFS replication setup. Add `dev-zfs/telemetry` and `prod-zfs/telemetry` to the replication dataset lists.

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

**Goal:** colossus-legal emits structured JSON telemetry. Data available for AI analysis.

| Step | Task |
|------|------|
| 1 | Create `colossus-observe` library crate in workspace |
| 2 | Implement `init_telemetry()` — JSON file subscriber with daily rotation |
| 3 | Implement span types: `http_request`, `db_query`, `llm_call`, `error_event` |
| 4 | Implement `emit_deploy_marker()` |
| 5 | Add `colossus-observe` dependency to colossus-legal backend |
| 6 | Instrument Axum handlers with `#[instrument]` |
| 7 | Instrument database clients (Neo4j, PostgreSQL, Qdrant) with tracing spans |
| 8 | Create ZFS datasets for telemetry on pve-1 and pve-2 |
| 9 | Add virtiofs mounts to app VM Butane configs |
| 10 | Rebuild and deploy colossus-legal with telemetry enabled |
| 11 | Verify: JSONL files appearing on virtiofs mount, readable, correctly structured |

**Exit gate:** colossus-legal producing structured telemetry on both DEV and PROD. Files on ZFS, replicated to TrueNAS.

**Rust learning opportunity:** The `tracing` crate is one of Rust's best-designed libraries. Its subscriber/layer composition pattern teaches trait objects, dynamic dispatch, and the builder pattern. The `#[instrument]` proc macro teaches how Rust macros generate code.

### Phase 3: AI Analysis MVP (1-2 sessions)

**Goal:** Daily email summary from Beszel metrics + application telemetry. First taste of AI-powered operations.

| Step | Task |
|------|------|
| 1 | Implement Beszel REST API client (query metrics history) |
| 2 | Implement telemetry JSONL reader (parse app logs) |
| 3 | Implement inference provider trait + Claude API client |
| 4 | Implement daily analysis prompt assembly |
| 5 | Implement email delivery (lettre crate, Gmail SMTP) |
| 6 | Create systemd timer for daily analysis (06:00) |
| 7 | Deploy to VM-314 as Podman Quadlet container |
| 8 | Tune prompts based on first week of daily reports |

**Exit gate:** Receiving daily email with health summary, warnings, and predictions. AI correctly identifies at least one non-obvious trend in the first week.

### Phase 4: Event-Triggered Analysis (1 session)

**Goal:** Beszel threshold alerts trigger deep AI analysis with log correlation.

| Step | Task |
|------|------|
| 1 | Implement SSH log retriever (connect to host, run journalctl, parse output) |
| 2 | Implement event-triggered analysis mode |
| 3 | Connect Beszel alerts → AI service (webhook or SMTP parse) |
| 4 | Implement enriched alert email formatting |
| 5 | Test with simulated alerts (fill a test disk, stop a test container) |

**Exit gate:** Alert emails include root cause analysis and recommendations, not just threshold notifications.

### Phase 5: Deployment Comparison (1 session)

**Goal:** Automatic before/after analysis on every Semaphore deployment.

| Step | Task |
|------|------|
| 1 | Implement Semaphore API client (or Git log parser) for deployment events |
| 2 | Implement deployment comparison prompt (before/after metrics + telemetry) |
| 3 | Hook into Semaphore post-deploy webhook or poll for completed runs |
| 4 | Implement deployment impact report email |

**Exit gate:** Every deployment to DEV or PROD generates an impact report. Regressions caught before users notice.

### Phase 6: Build Metrics (when dev VMs are operational)

**Goal:** Build processes emit telemetry. AI tracks build health over time.

| Step | Task |
|------|------|
| 1 | Create build metrics wrapper script (wraps build-release.sh) |
| 2 | Emit structured JSON build events to telemetry directory |
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
│   │       ├── telemetry.rs         # tracing subscriber setup
│   │       ├── spans.rs             # Pre-defined span types
│   │       ├── metrics.rs           # Metric helpers
│   │       ├── deploy.rs            # Deployment markers
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
│           ├── analyzer/
│           └── notifier/
├── frontend/                        # React UI (future — Phase 7)
└── prompts/                         # Versioned analysis prompts
    ├── daily_summary.md
    ├── event_analysis.md
    └── deployment_comparison.md
```

---

## 12. Naming Changes

Per this design session:

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
| 3 | colossus-legal produces structured JSONL telemetry | 2 |
| 4 | Daily AI health report identifies at least one actionable insight per week | 3 |
| 5 | Event-triggered alerts include root cause analysis | 4 |
| 6 | Deployment comparison catches a version regression | 5 |
| 7 | Build metric trends visible in AI reports | 6 |
| 8 | No monitoring data lost on VM rebuild (golden rule) | All |

---

## 14. Final Note

> The old stack failed because it answered the question "what are my metrics?" Nobody asked that question. The new platform answers: "what do I need to know right now, and what's coming next?" That's the only question that matters for a one-person homelab operation.
