# Colossus-Legal Application Deployment Requirements

**Document Type:** Requirements handoff for infrastructure team  
**Application:** Colossus-Legal (legal document analysis system)  
**Author:** Application development team (Opus)  
**Date:** 2026-02-08  
**Status:** DRAFT — awaiting infrastructure team review

---

## 1. Purpose

This document specifies everything the infrastructure team needs to deploy the Colossus-Legal application to DEV and PROD environments. The application team will provide build artifacts; the infrastructure team will handle VM creation, container orchestration, and networking.

---

## 2. Application Overview

Colossus-Legal is a web application for legal case analysis consisting of:

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Backend** | Rust + Axum | REST API server |
| **Frontend** | React + Vite + TypeScript | Single-page web application |

Both components are stateless. All persistent data lives in external databases.

---

## 3. Component Specifications

### 3.1 Backend

| Property | Value |
|----------|-------|
| Language | Rust (edition 2021) |
| Framework | Axum |
| Binary name | `colossus-backend` |
| Listen port | **3403** |
| Listen address | `0.0.0.0` |
| Protocol | HTTP (no TLS termination) |

**Build output:** Single static binary (Linux x86_64)

**Runtime dependencies:**
- OpenSSL libraries (libssl)
- CA certificates
- Network access to Neo4j database

**Health endpoint:** `GET /health` (to be implemented)
- Returns HTTP 200 when healthy
- Returns HTTP 503 when database unreachable

### 3.2 Frontend

| Property | Value |
|----------|-------|
| Build tool | Vite |
| Output | Static files (HTML, JS, CSS, assets) |
| Serve via | nginx (or any static file server) |
| Listen port | **5473** |
| Protocol | HTTP |

**Build output:** Directory of static files (`dist/`)

**Build-time configuration:**
- `VITE_API_URL` must be set at build time (baked into JS bundle)
- Different builds required for DEV vs PROD (different API URLs)

**Runtime dependencies:**
- Static file server (nginx recommended)
- No server-side processing required

---

## 4. Environment Configuration

### 4.1 Backend Environment Variables

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `NEO4J_URI` | Yes | Neo4j Bolt connection string | `bolt://10.10.100.200:7687` |
| `NEO4J_USER` | Yes | Neo4j username | `neo4j` |
| `NEO4J_PASSWORD` | Yes | Neo4j password | `<secret>` |
| `DOCUMENT_STORAGE_PATH` | Yes | Path to legal document PDFs | `/data/documents` |
| `RUST_LOG` | No | Log level | `info` (DEV: `debug`, PROD: `warn`) |
| `BIND_ADDRESS` | No | Listen address | `0.0.0.0:3403` (default) |

### 4.2 Frontend Build-Time Variables

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `VITE_API_URL` | Yes | Backend API base URL | `http://10.10.100.XXX:3403` |

**Note:** This is a BUILD-TIME variable. The frontend must be rebuilt with different values for DEV vs PROD.

### 4.3 Environment-Specific Values

| Variable | DEV | PROD |
|----------|-----|------|
| `NEO4J_URI` | `bolt://10.10.100.200:7687` | `bolt://<prod-db-ip>:7687` |
| `VITE_API_URL` | `http://<dev-app-ip>:3403` | `http://<prod-app-ip>:3403` |
| `RUST_LOG` | `debug` | `warn` |
| `DOCUMENT_STORAGE_PATH` | `/data/documents` | `/data/documents` |

---

## 5. Database Dependencies

### 5.1 Neo4j (Required)

| Property | Value |
|----------|-------|
| Version | 5.x |
| Protocol | Bolt |
| Port | 7687 |
| Database name | `neo4j` (default) |

**Connection pattern:** Backend connects to Neo4j on startup. If Neo4j is unavailable, backend will fail health checks but continue retrying.

**Current state:**
- DEV: VM-210 (`colossus-dev-db1`) at 10.10.100.200
- PROD: To be provisioned

### 5.2 PostgreSQL (Future)

Not currently used by the application. Reserved for future authentication/session storage.

### 5.3 Qdrant (Future)

Not currently used by the application. Reserved for future RAG/document search features.

---

## 6. Storage Requirements

### 6.1 Legal Documents

| Property | Value |
|----------|-------|
| Content | PDF files (legal documents) |
| Access pattern | Read-only from backend |
| Size estimate | ~100MB currently, may grow to 1GB |
| Mount point (container) | `/data/documents` |

**Source files location:** Currently on Roman's workstation at `/home/roman/colossus-legal-data/`

**Requirement:** These files must be copied to both DEV and PROD environments and mounted into the backend container.

**File list (current):**
```
Awad_v_Catholic_Family_Complaint_11113.pdf
Awad_v_Catholic_Family_Motion_for_Default_and_Default_Judgment_as_to_CFS.pdf
Awad_v_Catholic_Family__Motion_for_Default_and_Default_Judgment_as_to_Phillips.pdf
CFS_INTERROGATORY_RESPONSE_080816.pdf
COAAPPELLANTSREPLYBRIEFPART1.pdf
COAAPPELLANTSREPLYBRIEFPART2.pdf
Complaint005_Traceability_Diagram.pdf
GEORGE_PHILLIPS_RESPONSE_TO_DISCOVERY.pdf
GEORGEPHILLIPSCOARESPONSE04112011.pdf
GEORGEPHILLIPSMOTIONFORSUMMARYDISPOSITIONANDSACTIONS12202013.pdf
JEFFREYHUMPHREYAFFIDAVIT.pdf
Judge_Tighe_Opinon_and_Order_041212.pdf
PENZEINCOABRIEF03142011.pdf
SABRINAMORRISAFFIDAVIT.pdf
court_of_appeals_reconsideration_ruling_04252013.pdf
court_of_appeals_ruling_01122012.pdf
```

### 6.2 Application State

The application is **stateless**. No persistent storage is required for the containers themselves beyond the document mount.

---

## 7. Network Requirements

### 7.1 Ports

| Component | Port | Protocol | Exposure |
|-----------|------|----------|----------|
| Backend | 3403 | HTTP | Internal network + workstation access |
| Frontend | 5473 | HTTP | Internal network + workstation access |
| Neo4j | 7687 | Bolt | Backend → DB only |

### 7.2 Network Flows

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│  Browser        │         │  App VM         │         │  DB VM          │
│  (Workstation)  │         │                 │         │                 │
│                 │  :5473  │  ┌───────────┐  │         │                 │
│                 │────────▶│  │ Frontend  │  │         │                 │
│                 │         │  └───────────┘  │         │                 │
│                 │         │        │        │         │                 │
│                 │  :3403  │  ┌─────▼─────┐  │  :7687  │  ┌───────────┐  │
│                 │────────▶│  │ Backend   │──┼────────▶│  │  Neo4j    │  │
│                 │         │  └───────────┘  │         │  └───────────┘  │
│                 │         │        │        │         │                 │
│                 │         │  ┌─────▼─────┐  │         │                 │
│                 │         │  │ /data/    │  │         │                 │
│                 │         │  │ documents │  │         │                 │
│                 │         │  └───────────┘  │         │                 │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

### 7.3 CORS Configuration

The backend includes CORS headers allowing requests from:
- `http://localhost:5473` (local dev)
- `http://<dev-app-ip>:5473` (DEV)
- `http://<prod-app-ip>:5473` (PROD)

**Note:** CORS allowed origins are currently hardcoded. May need backend rebuild or environment variable for new IPs.

---

## 8. Build Artifacts

### 8.1 What the Application Team Provides

| Artifact | Description | Format |
|----------|-------------|--------|
| `colossus-backend` | Compiled Rust binary | Linux x86_64 ELF |
| `frontend-dist/` | Built frontend files | Directory (HTML, JS, CSS) |
| `Dockerfile.backend` | Backend container build instructions | Dockerfile |
| `Dockerfile.frontend` | Frontend container build instructions | Dockerfile |

### 8.2 Container Images

The application team will provide Dockerfiles. The infrastructure team may:
- Build images directly on target hosts, OR
- Build images on workstation and transfer as tar archives

**Recommended image names:**
- `colossus-backend:<version>`
- `colossus-frontend:<version>`

**Version format:** `YYYYMMDD-HHMMSS` or semantic version (e.g., `1.0.0`)

### 8.3 Source Code Location

| Repository | Location |
|------------|----------|
| GitHub | (private repo - URL TBD) |
| Local | `/home/roman/Projects/colossus-legal/` |

---

## 9. Release Process (Application Team Responsibilities)

### 9.1 Build Commands

**Backend:**
```bash
cd backend
cargo build --release
# Output: target/release/colossus-backend
```

**Frontend (DEV):**
```bash
cd frontend
VITE_API_URL=http://<dev-app-ip>:3403 npm run build
# Output: dist/
```

**Frontend (PROD):**
```bash
cd frontend
VITE_API_URL=http://<prod-app-ip>:3403 npm run build
# Output: dist/
```

### 9.2 Container Build Commands

```bash
# Backend
podman build -f Dockerfile.backend -t colossus-backend:$(date +%Y%m%d) .

# Frontend (must set build arg)
podman build -f Dockerfile.frontend \
  --build-arg VITE_API_URL=http://<target-ip>:3403 \
  -t colossus-frontend:$(date +%Y%m%d) .
```

### 9.3 Release Package

The application team will provide a release package containing:

```
colossus-legal-release-YYYYMMDD/
├── images/
│   ├── colossus-backend-YYYYMMDD.tar.gz
│   ├── colossus-frontend-dev-YYYYMMDD.tar.gz
│   └── colossus-frontend-prod-YYYYMMDD.tar.gz
├── config/
│   ├── env.dev.template
│   └── env.prod.template
├── documents/
│   └── (all PDF files)
└── RELEASE_NOTES.md
```

---

## 10. Deployment Workflow (High-Level)

```
DESKTOP                           DEV (pve-2)                    PROD (pve-1)
────────                          ──────────                     ────────────

1. Develop & test locally
   (cargo run, npm run dev)
              │
2. Build release package
   (backend binary, frontend dist,
    container images)
              │
3. Transfer to DEV ──────────────▶ 4. Load images
                                   5. Start containers
                                   6. Validate
                                         │
                                    Tests pass?
                                         │
                                   ┌─────┴─────┐
                                  YES          NO
                                   │            │
7. Transfer to PROD ◀──────────────┘       Fix & retry
              │
              └──────────────────────────▶ 8. Load images
                                           9. Start containers
                                          10. Validate
                                          11. Notify users
```

---

## 11. Validation Requirements

### 11.1 Health Checks

| Check | Endpoint | Expected |
|-------|----------|----------|
| Backend alive | `GET /health` | HTTP 200 |
| Case data loads | `GET /case` | JSON with `awad-v-cfs` |
| Schema accessible | `GET /schema` | JSON with node counts |
| Frontend serves | `GET /` | HTML containing "Colossus" |

### 11.2 Minimum Validation Script

```bash
#!/bin/bash
HOST=$1
echo "Checking backend..."
curl -sf http://${HOST}:3403/health || exit 1
curl -sf http://${HOST}:3403/case | grep -q "awad-v-cfs" || exit 1

echo "Checking frontend..."
curl -sf http://${HOST}:5473/ | grep -q "Colossus" || exit 1

echo "All checks passed"
```

### 11.3 Manual Validation Checklist

After each deployment:
- [ ] Frontend loads in browser
- [ ] Case title displays correctly
- [ ] Navigation works (all dropdown menus)
- [ ] Documents page shows 16 documents
- [ ] At least one PDF opens successfully
- [ ] Analysis page loads with 18 allegations

---

## 12. Security Considerations

### 12.1 Credentials

| Secret | Storage |
|--------|---------|
| Neo4j password | Environment file (not in container image) |

**Requirement:** Environment files with credentials must not be committed to git or baked into container images.

### 12.2 Network Access

Current deployment is **internal network only**. No public internet exposure.

Future consideration: If external access is needed, add:
- TLS termination (reverse proxy)
- Authentication layer
- Password protection for frontend

### 12.3 Container Security

- Containers should run as non-root user where possible
- Backend container: can run as non-root
- Frontend (nginx): typically runs as root but drops privileges

---

## 13. Monitoring & Logging

### 13.1 Log Output

| Component | Log destination | Format |
|-----------|-----------------|--------|
| Backend | stdout/stderr | Text (configurable via RUST_LOG) |
| Frontend (nginx) | stdout/stderr | nginx access/error logs |

**Requirement:** Container runtime should capture stdout/stderr (podman logs or journald).

### 13.2 Metrics (Future)

Not currently implemented. Future consideration:
- Prometheus metrics endpoint on backend
- Request timing, error rates, database connection health

---

## 14. Backup Considerations

### 14.1 What Needs Backup

| Data | Location | Backup method |
|------|----------|---------------|
| Neo4j database | DB VM | Handled by DB infrastructure |
| Legal documents | `/data/documents` | File copy (static, rarely changes) |
| Application code | Git repository | Git + GitHub |

### 14.2 What Does NOT Need Backup

- Container images (rebuildable from source)
- Container state (stateless)
- Frontend build output (rebuildable)

---

## 15. Outstanding Items (Application Team)

Before first deployment, the application team must:

- [ ] Implement `GET /health` endpoint in backend
- [ ] Create `Dockerfile.backend`
- [ ] Create `Dockerfile.frontend`
- [ ] Create nginx.conf for frontend
- [ ] Update CORS configuration to accept new IPs (or make configurable)
- [ ] Test container builds locally
- [ ] Create first release package
- [ ] Document exact CORS allowed origins needed

---

## 16. Questions for Infrastructure Team

1. What IPs will be assigned to the app VMs (DEV and PROD)?
2. Should documents be a separate virtiofs mount or bundled in the container?
3. Preferred method for transferring release packages (scp, shared storage, other)?
4. Container runtime preference (Quadlet recommended per Colossus patterns)?
5. Any naming conventions for VMIDs?

---

## 17. Version History

| Date | Version | Changes |
|------|---------|---------|
| 2026-02-08 | 1.0 | Initial requirements document |
