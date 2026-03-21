# Colossus-Legal — Application Container Requirements

**Requested by:** Colossus-Legal application team  
**Date:** 2026-02-23  
**Version:** 2.0 (supersedes APPLICATION_DEPLOYMENT_REQUIREMENTS.md sections 3-6)  
**Implementation team:** colossus-homelab  
**Purpose:** Everything the infrastructure team needs to build, deploy, and maintain the frontend and backend containers.

---

## 1. Overview

Colossus-Legal consists of two containers running on the App VMs:

| Container | Image base | Port | Persistent mounts |
|-----------|-----------|------|-------------------|
| **Frontend** | nginx:1.27 | 5473 | None |
| **Backend** | debian:bookworm-slim | 3403 | 2 host volumes |

**Principle:** Both containers are fully stateless and rebuildable at will. All persistent data lives on Proxmox host storage mounted at runtime. Destroying and recreating either container results in zero data loss.

---

## 2. Frontend Container

### 2.1 What It Is

An nginx server serving pre-built static files (HTML, JS, CSS). No application runtime — just a web server. A startup script (`docker-entrypoint.sh`) writes a `config.js` file from environment variables before nginx starts, enabling one image to work across DEV and PROD.

### 2.2 Image

Built from `frontend/Dockerfile` in the application repository. Multi-stage build:
- Stage 1: Node.js 20 compiles the React app (`npm ci && npm run build`)
- Stage 2: nginx:1.27-bookworm serves the static output

### 2.3 Runtime Spec

```
Image:      colossus-legal-frontend:<version>
Port:       5473

Volumes:    NONE

Environment:
  VITE_API_URL    — Backend API URL (e.g., http://10.10.100.220:3403 for DEV)

Resources:
  Memory limit:   128 MB
  CPU:            Minimal (static file serving only)
```

### 2.4 Persistent Storage

**None.** The frontend is 100% stateless:
- Static files are baked into the image at build time
- `config.js` is regenerated from `VITE_API_URL` on every container start
- No user uploads, no sessions, no caches on disk
- Logs go to stdout/stderr (nginx default)

### 2.5 Health Check

```bash
curl -f http://<host>:5473/
# Returns HTML containing "Colossus"
```

### 2.6 Rebuild Impact

**Zero.** Rebuild the image, restart the container, everything works immediately.

---

## 3. Backend Container

### 3.1 What It Is

A single compiled Rust binary (`colossus-legal-backend`) serving a REST API. Connects to Neo4j (graph database) and Qdrant (vector database) over the network. Embeds text using an in-process ONNX model (fastembed-rs) for semantic search. Serves legal PDF documents from a mounted volume.

### 3.2 Image

Built from `backend/Dockerfile` in the application repository. Multi-stage build:
- Stage 1: rust:1.84-bookworm compiles the binary (`cargo build --release`)
- Stage 2: debian:bookworm-slim with libssl3 + ca-certificates + the binary

Final image size: ~100-150 MB.

### 3.3 Runtime Spec

```
Image:      colossus-legal-backend:<version>
Port:       3403
User:       appuser (non-root)

Volumes:
  <host-documents>:/data/documents:ro     (REQUIRED — legal PDFs)
  <host-models>:/data/models:rw           (REQUIRED — embedding model cache)

Environment:
  NEO4J_URI                  — bolt://<db-ip>:7687
  NEO4J_USER                 — neo4j
  NEO4J_PASSWORD             — <from vault>
  QDRANT_URL                 — http://<db-ip>:6333
  DOCUMENT_STORAGE_PATH      — /data/documents
  FASTEMBED_CACHE_PATH        — /data/models
  RUST_LOG                   — debug (DEV) | warn (PROD)
  BACKEND_PORT               — 3403
  CORS_ALLOWED_ORIGINS       — <comma-separated allowed origins>

Resources:
  Memory limit:   1 GB (512 MB typical, spikes during model loading)
  CPU:            2 cores recommended (ONNX embedding uses CPU)
```

### 3.4 Persistent Storage — Mount 1: Legal Documents

| Property | Value |
|----------|-------|
| Container path | `/data/documents` |
| Access mode | **Read-only** (`:ro`) |
| Content | PDF files — legal case documents |
| Current size | ~85 MB (16 files) |
| Growth rate | Slow — new files only when new court filings occur |
| Source of truth | Application repository / Roman's workstation |
| Backup required? | Low priority — originals exist in source control and on workstation |

**Current file inventory (16 files):**
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

### 3.5 Persistent Storage — Mount 2: Embedding Models

| Property | Value |
|----------|-------|
| Container path | `/data/models` |
| Access mode | **Read-write** (`:rw`) |
| Content | ONNX model files for text embedding (fastembed-rs) |
| Current size | ~270 MB (`nomic-embed-text-v1.5`) |
| Growth rate | Rare — only changes when embedding model is swapped |
| First-run behavior | Backend auto-downloads model from HuggingFace (~270 MB) on first embedding call |
| After first run | Loads from disk, no network needed |
| Backup required? | **No** — freely re-downloadable from HuggingFace |

**How it works:** The Rust backend includes the `fastembed` crate, which uses the ONNX runtime to run embedding models. On first startup (or first embedding request), if the model isn't in the cache directory, fastembed downloads it from HuggingFace and stores it at the configured cache path. On all subsequent runs, it loads from disk. The model survives container rebuilds because it's on the host-mounted volume.

**First deployment note:** The first embedding request after a fresh volume will take 30-60 seconds as the model downloads. All subsequent requests take 10-50ms. The backend requires outbound internet access to `huggingface.co` for this one-time download. After that, the container can run fully air-gapped.

### 3.6 What the Backend Does NOT Store

| Data | Where it actually lives |
|------|------------------------|
| Graph database | Neo4j on DB VM (network) |
| Vector embeddings | Qdrant on DB VM (network) |
| User sessions | None — API is stateless |
| Uploaded files | None — no upload feature |
| Application logs | stdout/stderr → podman/journald |
| Temp files | `/tmp` — truly ephemeral, not needed across restarts |

### 3.7 Health Check

```bash
# Basic liveness
curl -f http://<host>:3403/health
# Returns HTTP 200 "OK"

# Functional check
curl -f http://<host>:3403/case | grep -q "awad-v-cfs"
# Returns case data from Neo4j
```

### 3.8 Rebuild Impact

**Minimal.** After rebuilding the backend container:
- API starts immediately (health check passes)
- Document serving works immediately (mounted volume)
- Embedding model is already cached on the mounted volume (unless volume was also wiped)
- If model volume was wiped: first embedding request auto-downloads (~30-60 seconds), then normal

---

## 4. Host Storage Provisioning

### 4.1 Per-Environment Layout

```
Proxmox host storage (ZFS dataset or directory)
│
├── colossus-documents/              → Backend mount: /data/documents:ro
│   ├── Awad_v_Catholic_Family_Complaint_11113.pdf
│   ├── ... (16 PDF files total)
│   └── court_of_appeals_ruling_01122012.pdf
│
└── colossus-models/                 → Backend mount: /data/models:rw
    └── (auto-populated by fastembed on first run)
```

### 4.2 Disk Space Budget

| Mount | Current | Growth Ceiling | Recommended Allocation |
|-------|---------|---------------|----------------------|
| `colossus-documents` | 85 MB | 500 MB (many new filings) | **500 MB** |
| `colossus-models` | 270 MB | 1.5 GB (2-3 models) | **2 GB** |
| **Total per environment** | **355 MB** | | **2.5 GB** |

### 4.3 Both Environments

| | DEV (pve-2) | PROD (pve-1) | Total |
|---|-------------|-------------|-------|
| Documents | 500 MB | 500 MB | 1 GB |
| Models | 2 GB | 2 GB | 4 GB |
| **Total** | **2.5 GB** | **2.5 GB** | **5 GB** |

---

## 5. Environment Variables — Complete Reference

### 5.1 DEV

**Backend (`colossus-legal-backend.env`):**
```bash
NEO4J_URI=bolt://10.10.100.200:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=<vault: vault_colossus_legal_neo4j_password_dev>
QDRANT_URL=http://10.10.100.200:6333
DOCUMENT_STORAGE_PATH=/data/documents
FASTEMBED_CACHE_PATH=/data/models
RUST_LOG=debug
BACKEND_PORT=3403
CORS_ALLOWED_ORIGINS=https://colossus-legal-dev.cogmai.com,http://localhost:5473
```

**Frontend (`colossus-legal-frontend.env`):**
```bash
VITE_API_URL=http://10.10.100.220:3403
```

### 5.2 PROD

**Backend (`colossus-legal-backend.env`):**
```bash
NEO4J_URI=bolt://10.10.100.110:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=<vault: vault_colossus_legal_neo4j_password_prod>
QDRANT_URL=http://10.10.100.110:6333
DOCUMENT_STORAGE_PATH=/data/documents
FASTEMBED_CACHE_PATH=/data/models
RUST_LOG=warn
BACKEND_PORT=3403
CORS_ALLOWED_ORIGINS=https://colossus-legal.cogmai.com,http://localhost:5473
```

**Frontend (`colossus-legal-frontend.env`):**
```bash
VITE_API_URL=http://10.10.100.120:3403
```

---

## 6. Ansible Integration

### 6.1 Group Variables

Add to `group_vars/dev.yml`:
```yaml
colossus_legal_qdrant_url: "http://10.10.100.200:6333"
colossus_legal_fastembed_cache_path: "/data/models"
colossus_legal_document_storage_path: "/data/documents"
```

Add to `group_vars/prod.yml`:
```yaml
colossus_legal_qdrant_url: "http://10.10.100.110:6333"
colossus_legal_fastembed_cache_path: "/data/models"
colossus_legal_document_storage_path: "/data/documents"
```

### 6.2 Backend Environment Template (`colossus-legal-backend.env.j2`)

Add:
```
QDRANT_URL={{ colossus_legal_qdrant_url }}
FASTEMBED_CACHE_PATH={{ colossus_legal_fastembed_cache_path }}
```

### 6.3 Volume Mounts

Backend Quadlet/systemd unit needs:
```ini
[Container]
Volume=colossus-documents.volume:/data/documents:ro
Volume=colossus-models.volume:/data/models:rw
```

Frontend Quadlet/systemd unit needs:
```ini
[Container]
# No volumes required
```

---

## 7. Network Requirements

### 7.1 Ports

| Container | Port | Protocol | Direction |
|-----------|------|----------|-----------|
| Frontend | 5473 | HTTP | Inbound (browser → nginx) |
| Backend | 3403 | HTTP | Inbound (browser/frontend → API) |

### 7.2 Backend Outbound Connections

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| DB VM (Neo4j) | 7687 | Bolt | Graph database queries |
| DB VM (Qdrant) | 6333 | HTTP | Vector search and upserts |
| huggingface.co | 443 | HTTPS | Model download (first run only) |

### 7.3 Network Flow Diagram

```
┌─────────────────┐         ┌─────────────────────────────┐         ┌──────────────────┐
│  Browser         │         │  App VM                     │         │  DB VM           │
│  (Workstation/   │         │                             │         │                  │
│   Cloudflare)    │         │                             │         │                  │
│                  │  :5473  │  ┌───────────────────┐      │         │                  │
│                  │────────►│  │ Frontend (nginx)  │      │         │                  │
│                  │         │  └───────────────────┘      │         │                  │
│                  │         │                             │         │                  │
│                  │  :3403  │  ┌───────────────────┐      │  :7687  │  ┌────────────┐  │
│                  │────────►│  │ Backend (Rust)    │──────┼────────►│  │ Neo4j      │  │
│                  │         │  │                   │      │         │  └────────────┘  │
│                  │         │  │  ┌─────────────┐  │      │  :6333  │  ┌────────────┐  │
│                  │         │  │  │ fastembed   │  │──────┼────────►│  │ Qdrant     │  │
│                  │         │  │  │ (in-process)│  │      │         │  └────────────┘  │
│                  │         │  │  └─────────────┘  │      │         │                  │
│                  │         │  │                   │      │         │                  │
│                  │         │  │  /data/documents ─┼──► [host mount: PDFs, read-only] │
│                  │         │  │  /data/models ────┼──► [host mount: ONNX, read-write]│
│                  │         │  └───────────────────┘      │         │                  │
└─────────────────┘         └─────────────────────────────┘         └──────────────────┘
```

---

## 8. Security

| Concern | Approach |
|---------|----------|
| Credentials | Neo4j password in env file, NOT in image. Managed via Ansible vault. |
| Container user | Backend runs as `appuser` (non-root). Frontend nginx runs as root but drops privileges. |
| Document access | Read-only mount — backend cannot modify PDFs. |
| Model cache | Read-write but contains only publicly available ONNX files. |
| Network exposure | Internal network only by default. External access via Cloudflare Tunnel → Traefik. |

---

## 9. Monitoring & Logging

| Container | Log destination | Format | Capture method |
|-----------|-----------------|--------|----------------|
| Frontend | stdout/stderr | nginx access/error logs | podman logs / journald |
| Backend | stdout/stderr | Configurable via `RUST_LOG` | podman logs / journald |

No log files written to disk. All observability data flows through the standard container logging pipeline to the Grafana/Loki stack via Alloy agents.

---

## 10. Validation Checklist (Post-Deployment)

```bash
#!/bin/bash
HOST=$1

echo "=== Frontend ==="
curl -sf http://${HOST}:5473/ | grep -q "Colossus" && echo "PASS: Frontend serves" || echo "FAIL"

echo "=== Backend ==="
curl -sf http://${HOST}:3403/health && echo "PASS: Health check" || echo "FAIL"
curl -sf http://${HOST}:3403/case | grep -q "awad-v-cfs" && echo "PASS: Neo4j connected" || echo "FAIL"
curl -sf http://${HOST}:3403/documents | grep -q "Complaint" && echo "PASS: Documents loaded" || echo "FAIL"

echo "=== Mounts ==="
# Document serving (tests /data/documents mount)
DOC_ID=$(curl -sf http://${HOST}:3403/documents | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)
if [ -n "$DOC_ID" ]; then
  curl -sf -o /dev/null http://${HOST}:3403/documents/${DOC_ID}/file && echo "PASS: PDF serving" || echo "FAIL: PDF serving"
fi

echo "=== Complete ==="
```

---

## 11. Local Development Setup

For developing on desktop (`proxima-centauri`) before deploying to VMs:

```bash
# Create the mount point directories
mkdir -p ~/colossus-legal-data/documents
mkdir -p ~/colossus-legal-data/models

# Copy PDFs (if not already present)
# cp /path/to/pdfs/*.pdf ~/colossus-legal-data/documents/

# Set in backend/.env
DOCUMENT_STORAGE_PATH=/home/roman/colossus-legal-data/documents
FASTEMBED_CACHE_PATH=/home/roman/colossus-legal-data/models
QDRANT_URL=http://10.10.100.200:6333
```

First `cargo run` with an embedding request will auto-download the model to the local cache directory. No manual model download step needed.

---

## 12. Change Log

| Date | Version | Changes |
|------|---------|---------|
| 2026-02-08 | 1.0 | Initial APPLICATION_DEPLOYMENT_REQUIREMENTS.md |
| 2026-02-23 | 2.0 | Consolidated frontend/backend requirements. Added Phase H mount points (embedding models). Replaced Ollama service with in-process fastembed-rs. Added storage audit, disk budget, Ansible integration, validation script. |
