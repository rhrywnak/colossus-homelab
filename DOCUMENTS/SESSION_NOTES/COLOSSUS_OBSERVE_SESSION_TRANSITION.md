# Colossus-Observe & Infrastructure Services Research — Session Transition Document

**Date:** 2026-02-24
**Session Type:** Research, Architecture Assessment & Decision-Making
**Status:** Decisions captured — colossus-observe on hold until colossus-legal complete
**Next Action:** Resume colossus-observe development when colossus-legal reaches stable milestone

---

## 1. Session Summary

This session evaluated two infrastructure service categories for the Colossus homelab:

1. **Identity Management** — Application-level login, SSO, and activity tracking for 5-10 users
2. **LLM Observability** — Tracing, benchmarking, and evaluation of LLM calls across colossus-legal and colossus-ai

The evaluation was driven by Roman's requirements: minimal resource footprint, alignment with Colossus infrastructure patterns, and avoidance of heavy Docker Compose mega-stacks that don't fit the homelab scale.

---

## 2. Identity Management — Evaluation & Decision

### 2.1 Problem Statement

Colossus apps (colossus-legal, future colossus-ai) need per-user authentication, session management, and activity tracking. Current perimeter security is Cloudflare Access with OTP on `*.cogmai.com`, which gates access but provides no application-level identity.

### 2.2 Solutions Evaluated

| Solution | Architecture | RAM | Verdict |
|----------|-------------|-----|---------|
| **Authelia** | Single Go binary/container, SQLite default | ~30 MB | ✅ **Leading candidate** |
| **Authentik** | PostgreSQL + Redis + server + worker (4+ containers) | 1-2 GB | ❌ Too heavy for 5-10 users |
| **Keycloak** | Java-based, PostgreSQL (2+ containers) | 1-2 GB | ❌ Enterprise overkill |
| **Zitadel** | Go binary, PostgreSQL or embedded CockroachDB | 256-512 MB | ⚠️ Viable but less mature |

### 2.3 Why Authelia Wins

- **Single container**, compressed image < 20 MB, observed memory usage ~30 MB
- **Native Traefik integration** via `forwardAuth` middleware — Traefik already runs on CT-110/CT-313
- **OpenID Connect 1.0 Provider** (OpenID Certified) — enables OIDC/JWT integration with Axum backends
- **MFA support** — Passkeys, TOTP, WebAuthn, mobile push
- **SQLite default** — no external database dependency for small deployments
- **Audit logging** — authentication events flow into existing Loki stack via container logs
- **Zero changes to Axum backend** for basic perimeter gating; OIDC integration adds deeper app-level identity

### 2.4 Planned Deployment Architecture (When Ready)

```
User → Cloudflare Tunnel → Traefik (CT-313)
                              ├─ forwardAuth → Authelia (auth.cogmai.com)
                              │                  └─ SQLite (local or ZFS mount)
                              ├─ colossus-legal.cogmai.com → VM-120
                              ├─ colossus-legal-api.cogmai.com → VM-120
                              └─ observe.cogmai.com → TBD
```

- Authelia runs as a single container in an LXC on pve-3 (or alongside Traefik in CT-313)
- Traefik gets a `forwardAuth` middleware added to existing routes
- Users hit login portal at `auth.cogmai.com` before accessing any app
- Activity tracking: Authelia audit logs + Traefik access logs → Alloy → Loki → Grafana

### 2.5 Rust Learning Opportunity

For deeper app-level identity (knowing *which user* makes API calls inside colossus-legal), Authelia's OIDC provider enables JWT validation in Axum. Relevant Rust crates:

- `openidconnect` — Full OIDC client implementation
- `jsonwebtoken` — JWT validation
- Axum middleware/extractors for request-level auth

This covers async HTTP, cryptographic verification, type-safe token claims, and tower middleware patterns.

### 2.6 Decision Status

**Decision: Authelia is the leading candidate. Final decision pending — not blocking colossus-legal development.**

---

## 3. LLM Observability — Evaluation & Decision

### 3.1 Problem Statement

Roman needs to track LLM query/response performance, latency, token usage, costs, and metadata across both colossus-legal (document processing) and colossus-ai (arXiv paper analysis/tutorials). All major self-hosted platforms were evaluated against Roman's existing homegrown solution.

### 3.2 Solutions Evaluated

| Platform | Containers | RAM | Storage Backend | Verdict |
|----------|-----------|-----|----------------|---------|
| **Opik** | 8 | 4-8 GB | MySQL + ClickHouse + Redis + ZooKeeper + MinIO | ❌ Too heavy |
| **Langfuse v3** | 6 | 4-16 GB | PostgreSQL + ClickHouse + Redis + MinIO | ❌ Too heavy |
| **Helicone** | 1-4 | 2-4 GB | PostgreSQL + ClickHouse + MinIO (bundled) | ❌ Still heavy for homelab |
| **colossus-observe** | 2 (backend + frontend) | < 512 MB | PostgreSQL (existing) | ✅ **Roman's own solution** |

### 3.3 Key Finding: Convergence on Heavy Stacks

All three commercial/open-source platforms have converged on the same architecture: ClickHouse for analytics, an RDBMS for metadata, MinIO/S3 for blob storage, Redis for caching. This makes sense at scale (billions of traces), but is massive overkill for a homelab generating hundreds to thousands of traces.

**Opik's MinIO specifically** stores LLM trace attachments — large prompt/response payloads, experiment artifacts, exported datasets. For homelab volumes, PostgreSQL JSONB or filesystem storage handles this easily.

**Langfuse moved to ClickHouse** because PostgreSQL's row-based storage became inefficient at billions of rows. At Roman's scale, PostgreSQL is more than adequate.

### 3.4 Why colossus-observe Wins

Roman already has a purpose-built solution: **colossus-observe** (GitHub: `rhrywnak/colossus-llm-observe`).

**What's already built (v0.1.0 "Scenario Scaffold"):**

| Component | Technology | Status |
|-----------|-----------|--------|
| Backend API | Rust/Axum + SQLx | ✅ Working |
| Frontend | React 19 + Vite SPA | ✅ Working (migrated from Leptos) |
| CLI | Rust (`baseline-cli`) with clap | ✅ Working |
| Database | PostgreSQL | ✅ Working |
| Evaluation pipeline | Auto-scoring + manual review hooks | ✅ Working |
| Observation ingestion | Latency, TTFT, tokens in/out, tokens/sec, GPU snapshots | ✅ Working |
| Scenario/dataset management | CRUD API + CLI commands | ✅ Working |
| Leaderboard/comparison | Variant ranking by evaluation score | ✅ Working |
| Experiment config | YAML-driven declarative configs | ✅ Working |
| Docker builds | Multi-stage Dockerfiles (backend + frontend) | ✅ Working |

**Repository layout:**

```
colossus-llm-observe/
├── backend/             Rust (Axum + SQLx) API
├── baseline-cli/        Scenario-aware CLI (launch, logs, catalog)
├── frontend/            React 19 + Vite SPA
├── shared/              Reusable config/domain crates
├── infra/               Compose stacks (dev/llm/postgres)
├── docs/                Architecture briefs, trackers, release notes
├── env/                 Environment templates
└── .githooks/pre-commit Backend quality gate (fmt, clippy, tests)
```

### 3.5 Opik Features to Adopt

While rejecting Opik's infrastructure weight, several of its design patterns are worth adopting into colossus-observe:

| Opik Feature | Value for Colossus | Adoption Priority |
|-------------|-------------------|------------------|
| **`@track` decorator pattern** | Zero-friction instrumentation for colossus-ai Python code | High |
| **LLM-as-a-judge evaluation** | Hallucination detection, factuality, relevance scoring | High |
| **Span/trace hierarchy** | Critical for colossus-ai's multi-step paper analysis pipelines | High |
| **Prompt versioning + playground** | Iterate on prompts with A/B comparisons | Medium |
| **Automated prompt optimization** | 6 algorithms (Few-shot Bayesian, evolutionary, MetaPrompt, etc.) | Medium |
| **Guardrails** | PII screening, off-topic detection, content blocking | Low (future) |
| **CI/CD integration** | LLM unit tests in PyTest for regression detection | Low (future) |

### 3.6 Architecture Refresh Needed

The current colossus-observe code predates the Colossus infrastructure buildout. When development resumes, the following must be updated:

| Area | Current State | Target State |
|------|--------------|-------------|
| **Deployment model** | Docker Compose (docker-compose.dev.yml / prod.yml) | Podman + Quadlet on CoreOS VM |
| **Database** | Local Docker PostgreSQL or `10.10.100.50` | Externalized ZFS dataset via virtiofs (Colossus pattern) |
| **Reverse proxy** | None / nginx in frontend container | Traefik route at `observe.cogmai.com` |
| **DNS** | Manual / not configured | Pi-hole CNAME → Traefik |
| **External access** | Not configured | Cloudflare Tunnel route |
| **CI/CD** | GitHub Actions (basic) | build-release.sh + Ansible deploy-app role + Semaphore |
| **Container registry** | Local builds | ghcr.io (matching colossus-legal pattern) |
| **Monitoring** | Self-contained Prometheus/Grafana in compose | Alloy agent → centralized Prometheus/Loki on VM-314 |
| **Authentication** | None | Authelia forwardAuth + optional OIDC JWT |
| **Backups** | None | PBS daily schedule (matching all other VMs) |
| **Infrastructure-as-code** | Docker Compose files | Ansible role + Butane/Ignition config |

### 3.7 Planned VM Allocation

Following the Colossus naming convention:

| VMID | Name | Node | Role |
|------|------|------|------|
| TBD (130?) | colossus-prod-observe | pve-1 or pve-3 | PROD observe host |
| TBD (230?) | colossus-dev-observe | pve-2 | DEV observe host |

Or, if resource-constrained, colossus-observe could share app VMs with colossus-legal (VM-120/VM-220) using different ports — the same Option A/B decision from the Phase 5B design.

### 3.8 Decision Status

**Decision: colossus-observe replaces Opik/Langfuse/Helicone. Development resumes after colossus-legal reaches a stable milestone. Opik's design patterns will be studied and selectively adopted.**

---

## 4. colossus-ai — Context Captured

colossus-ai is a planned application for reading, analyzing, and providing tutorials on arXiv papers focused on AI and Deep Learning. It is on hold until colossus-legal is done. When active, it will instrument against colossus-observe for LLM tracing, benchmarking, and evaluation — not against an external platform.

---

## 5. Decisions Summary

| Decision | Rationale | Status |
|----------|-----------|--------|
| Authelia for identity management | Single container, ~30MB RAM, native Traefik forwardAuth, OIDC certified. All others too heavy for 5-10 users. | Pending (not blocking) |
| Reject Authentik/Keycloak | 4+ containers, 1-2GB RAM, PostgreSQL + Redis dependencies — overkill for homelab scale | Final |
| Reject Opik self-hosted | 8 containers, 4-8GB RAM (ClickHouse + MySQL + Redis + ZooKeeper + MinIO) | Final |
| Reject Langfuse v3 self-hosted | 6 containers, 4-16GB RAM (PostgreSQL + ClickHouse + Redis + MinIO) | Final |
| Reject Helicone self-hosted | 1-4 containers, 2-4GB RAM — lightest option but still heavier than needed | Final |
| colossus-observe for LLM observability | Already built (Rust/Axum + React + CLI), fits Colossus patterns, serves both colossus-legal and colossus-ai | Final |
| Adopt Opik design patterns | @track decorator, LLM-as-judge, span/trace hierarchy, prompt versioning, automated optimization | Final (when resuming) |

---

## 6. References

| Document | Purpose |
|----------|---------|
| GitHub: `rhrywnak/colossus-llm-observe` | colossus-observe source code |
| `docs/ARCH-DESIGN-V1/BASELINE-RESET-DESIGN.md` (in repo) | Core architecture and data model |
| `docs/RELEASES/v0.1.0.md` (in repo) | v0.1.0 "Scenario Scaffold" release scope |
| `docs/DEPLOYMENT.md` (in repo) | Current Docker-based deployment guide |
| `COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md` | Original Opik/Helicone evaluation and LXC deployment plan |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v7.md` | Current infrastructure state |
| `APP_DEPLOY_PIPELINE_SESSION_TRANSITION.md` | build-release.sh + Ansible deploy pattern to follow |
| [Authelia docs](https://www.authelia.com/) | Identity management candidate |
| [Opik docs](https://www.comet.com/docs/opik/) | Design patterns to study for adoption |

---

## 7. Resume Protocol — When Picking Up colossus-observe

1. **Read this document** for full context
2. **Clone/pull** `rhrywnak/colossus-llm-observe` and review current state on `feature/scenario-scaffold` branch
3. **Read** `docs/ARCH-DESIGN-V1/BASELINE-RESET-DESIGN.md` for the data model and system topology
4. **Study Opik's design** — particularly `@track` decorator, LLM-as-judge evals, span/trace hierarchy, prompt versioning
5. **Create architecture refresh design doc** — map current Docker Compose deployment to Colossus patterns (Podman Quadlet, Traefik, Ansible, PBS backups)
6. **Decide VM allocation** — dedicated VMs vs shared with colossus-legal
7. **Update Butane/Ignition config** — following the CoreOS VM creation runbook pattern
8. **Create Ansible role** — `colossus-observe` app role matching the `colossus-legal` role pattern
9. **Update application code** — remove Docker Compose dependencies, align env vars with Colossus conventions
10. **Deploy to DEV** — validate end-to-end via Semaphore

---

**Created:** 2026-02-24
**Author:** Roman & Claude
**Session Type:** Research & Decision-Making
