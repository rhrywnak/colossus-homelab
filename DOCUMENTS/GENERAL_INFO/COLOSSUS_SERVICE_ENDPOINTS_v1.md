# Colossus — Authoritative Service Endpoints

**Version:** v1.0  
**Date:** 2026-02-23  
**Status:** Living document — update when services are added or IPs change

---

## 1. Network Topology

All services operate on the `10.10.100.0/24` homelab VLAN.  
DNS is served by Pi-hole at `10.10.100.53`.  
External access routes through Cloudflare Tunnel → Traefik.

---

## 2. Host Inventory

### 2.1 Proxmox Nodes

| Host | IP | Role |
|------|----|------|
| pve-1 | 10.10.100.3 | PROD workloads |
| pve-2 | 10.10.100.2 | DEV workloads |
| pve-3 | 10.10.100.5 | Infrastructure services, PBS |

### 2.2 VMs and Containers

| ID | Name | Node | IP | Role |
|----|------|------|----|------|
| VM-110 | colossus-prod-db1 | pve-1 | 10.10.100.110 | PROD databases (Neo4j, PostgreSQL, Qdrant) |
| VM-120 | colossus-prod-app1 | pve-1 | 10.10.100.120 | PROD application (backend + frontend) |
| VM-210 | colossus-dev-db1 | pve-2 | 10.10.100.200 | DEV databases (Neo4j, PostgreSQL, Qdrant) |
| VM-220 | colossus-dev-app1 | pve-2 | 10.10.100.220 | DEV application (backend + frontend) |
| CT-311 | pihole | pve-3 | 10.10.100.53 | DNS |
| CT-312 | cloudflared | pve-3 | 10.10.100.54 | Cloudflare Tunnel |
| CT-313 | traefik | pve-3 | 10.10.100.55 | Reverse proxy + TLS |
| VM-314 | monitoring | pve-3 | 10.10.100.56 | Prometheus, Loki, Grafana |
| CT-315 | semaphore | pve-3 | 10.10.100.57 | Ansible automation UI |
| VM-900 | PBS | pve-3 | 10.10.100.242 | Proxmox Backup Server |

### 2.3 Other Hosts

| Host | IP | Network | Role |
|------|----|---------|------|
| proxima-centauri | 10.10.0.10 | Main VLAN | Workstation |
| TrueNAS | 10.10.0.38 | Main VLAN | NAS / backup replication target |

---

## 3. Database Service Endpoints

All database services run on the DB VMs. Each database has its own ZFS-backed virtiofs dataset for persistent storage.

### 3.1 Neo4j

| Property | DEV | PROD |
|----------|-----|------|
| Host | 10.10.100.200 | 10.10.100.110 |
| Bolt (client) | `bolt://10.10.100.200:7687` | `bolt://10.10.100.110:7687` |
| HTTP (browser) | `http://10.10.100.200:7474` | `http://10.10.100.110:7474` |
| Database | `neo4j` (default) | `neo4j` (default) |
| User | `neo4j` | `neo4j` |
| Password | Ansible vault: `vault_colossus_legal_neo4j_password_dev` | Ansible vault: `vault_colossus_legal_neo4j_password_prod` |
| Version | 5.x | 5.x |

**Connection string for Rust backend:**
```
NEO4J_URI=bolt://10.10.100.200:7687   # DEV
NEO4J_URI=bolt://10.10.100.110:7687   # PROD
```

### 3.2 Qdrant

| Property | DEV | PROD |
|----------|-----|------|
| Host | 10.10.100.200 | 10.10.100.110 |
| HTTP API | `http://10.10.100.200:6333` | `http://10.10.100.110:6333` |
| gRPC | `http://10.10.100.200:6334` | `http://10.10.100.110:6334` |
| Version | Pinned (see Quadlet) | Pinned (see Quadlet) |
| Auth | None (internal network only) | None (internal network only) |

**Connection string for Rust backend:**
```
QDRANT_URL=http://10.10.100.200:6333   # DEV
QDRANT_URL=http://10.10.100.110:6333   # PROD
```

**Note:** Use HTTP API (port 6333) for the `qdrant-client` Rust crate. gRPC (port 6334) is available if you prefer that transport, but the HTTP client is simpler for initial integration.

### 3.3 PostgreSQL

| Property | DEV | PROD |
|----------|-----|------|
| Host | 10.10.100.200 | 10.10.100.110 |
| Port | 5432 | 5432 |
| Connection URL | `postgresql://postgres@10.10.100.200:5432/colossus` | `postgresql://postgres@10.10.100.110:5432/colossus` |
| Database | `colossus` | `colossus` |
| User | `postgres` | `postgres` |
| Password | Ansible vault | Ansible vault |
| Version | 17 | 17 |

**Connection string for Rust backend:**
```
DATABASE_URL=postgresql://postgres:<password>@10.10.100.200:5432/colossus   # DEV
DATABASE_URL=postgresql://postgres:<password>@10.10.100.110:5432/colossus   # PROD
```

**Status:** Not currently used by colossus-legal. Reserved for future authentication/session storage.

---

## 4. Application Service Endpoints

### 4.1 Colossus-Legal Backend (Rust/Axum)

| Property | DEV | PROD |
|----------|-----|------|
| Host | 10.10.100.220 | 10.10.100.120 |
| Port | 3403 | 3403 |
| Health check | `http://10.10.100.220:3403/health` | `http://10.10.100.120:3403/health` |
| API base | `http://10.10.100.220:3403` | `http://10.10.100.120:3403` |
| Document storage | `/data/documents` (container path) | `/data/documents` (container path) |

### 4.2 Colossus-Legal Frontend (React/nginx)

| Property | DEV | PROD |
|----------|-----|------|
| Host | 10.10.100.220 | 10.10.100.120 |
| Port | 5473 | 5473 |
| URL | `http://10.10.100.220:5473` | `http://10.10.100.120:5473` |

---

## 5. External Endpoints (Cloudflare / Traefik)

All external access routes through Cloudflare Tunnel (CT-312) → Traefik (CT-313) → backend service. TLS terminates at Cloudflare edge.

### 5.1 Colossus-Legal

| Service | DEV | PROD |
|---------|-----|------|
| Frontend | `https://colossus-legal-dev.cogmai.com` | `https://colossus-legal.cogmai.com` |
| Backend API | `https://colossus-legal-api-dev.cogmai.com` | `https://colossus-legal-api.cogmai.com` |

### 5.2 Infrastructure

| Service | URL |
|---------|-----|
| Semaphore UI | `https://semaphore.cogmai.com` |
| Grafana | `https://grafana.cogmai.com` |
| Neo4j Browser (DEV) | `https://neo4j-dev.cogmai.com` |
| Neo4j Browser (PROD) | `https://neo4j.cogmai.com` |

---

## 6. Infrastructure Service Endpoints

### 6.1 Monitoring Stack (VM-314)

| Service | URL | Purpose |
|---------|-----|---------|
| Prometheus | `http://10.10.100.56:9090` | Metrics collection |
| Loki | `http://10.10.100.56:3100` | Log aggregation |
| Grafana | `http://10.10.100.56:3000` | Dashboards + alerting |

### 6.2 Grafana Alloy Agents

Every managed host runs an Alloy agent that forwards metrics and logs to VM-314.

| Host | Alloy Health URL |
|------|-----------------|
| pve-1 | `http://10.10.100.3:12345` |
| pve-2 | `http://10.10.100.2:12345` |
| pve-3 | `http://10.10.100.5:12345` |
| VM-110 | `http://10.10.100.110:12345` |
| VM-120 | `http://10.10.100.120:12345` |
| VM-210 | `http://10.10.100.200:12345` |
| VM-220 | `http://10.10.100.220:12345` |
| CT-311 | `http://10.10.100.53:12345` |
| CT-312 | `http://10.10.100.54:12345` |
| CT-313 | `http://10.10.100.55:12345` |
| CT-315 | `http://10.10.100.57:12345` |
| VM-314 | `http://10.10.100.56:12345` |

### 6.3 DNS (Pi-hole)

| Property | Value |
|----------|-------|
| DNS Server | `10.10.100.53` |
| Admin UI | `http://10.10.100.53/admin` |

### 6.4 Reverse Proxy (Traefik)

| Property | Value |
|----------|-------|
| Dashboard | `http://10.10.100.55:8080/dashboard/` |
| HTTP entrypoint | `10.10.100.55:80` |
| HTTPS entrypoint | `10.10.100.55:443` |

### 6.5 Semaphore

| Property | Value |
|----------|-------|
| Internal | `http://10.10.100.57:3000` |
| External | `https://semaphore.cogmai.com` |

### 6.6 Proxmox Backup Server

| Property | Value |
|----------|-------|
| Web UI | `https://10.10.100.242:8007` |

---

## 7. Backend Environment Variables — Quick Reference

This section provides the complete set of environment variables the colossus-legal backend needs, per environment. Passwords are stored in Ansible vault.

### 7.1 DEV

```bash
NEO4J_URI=bolt://10.10.100.200:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=<vault: vault_colossus_legal_neo4j_password_dev>
QDRANT_URL=http://10.10.100.200:6333
DOCUMENT_STORAGE_PATH=/data/documents
RUST_LOG=debug
BACKEND_PORT=3403
CORS_ALLOWED_ORIGINS=https://colossus-legal-dev.cogmai.com,http://localhost:5473
```

### 7.2 PROD

```bash
NEO4J_URI=bolt://10.10.100.110:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=<vault: vault_colossus_legal_neo4j_password_prod>
QDRANT_URL=http://10.10.100.110:6333
DOCUMENT_STORAGE_PATH=/data/documents
RUST_LOG=warn
BACKEND_PORT=3403
CORS_ALLOWED_ORIGINS=https://colossus-legal.cogmai.com,http://localhost:5473
```

**Note:** `DATABASE_URL` (PostgreSQL) is omitted — add when the application integrates PostgreSQL.

---

## 8. Port Allocation Summary

| Port | Protocol | Service | Hosts |
|------|----------|---------|-------|
| 3403 | HTTP | Colossus-Legal backend API | VM-120, VM-220 |
| 5432 | TCP | PostgreSQL | VM-110, VM-210 |
| 5473 | HTTP | Colossus-Legal frontend | VM-120, VM-220 |
| 6333 | HTTP | Qdrant REST API | VM-110, VM-210 |
| 6334 | gRPC | Qdrant gRPC API | VM-110, VM-210 |
| 7474 | HTTP | Neo4j Browser/HTTP API | VM-110, VM-210 |
| 7687 | Bolt | Neo4j Bolt protocol | VM-110, VM-210 |
| 3000 | HTTP | Grafana / Semaphore | VM-314 / CT-315 |
| 3100 | HTTP | Loki | VM-314 |
| 9090 | HTTP | Prometheus | VM-314 |
| 12345 | HTTP | Grafana Alloy agent | All managed hosts |

---

## 9. Ansible Integration

Backend environment variables are managed through Ansible group_vars and templates:

| Variable | Set in | Used by |
|----------|--------|---------|
| `colossus_legal_neo4j_uri` | `group_vars/dev.yml`, `group_vars/prod.yml` | `colossus-legal-backend.env.j2` |
| `colossus_legal_qdrant_url` | `group_vars/dev.yml`, `group_vars/prod.yml` | `colossus-legal-backend.env.j2` |
| `colossus_legal_api_url` | `group_vars/dev.yml`, `group_vars/prod.yml` | `config.js.j2` (frontend) |
| `colossus_legal_cors_origins` | `group_vars/dev.yml`, `group_vars/prod.yml` | `colossus-legal-backend.env.j2` |
| `vault_colossus_legal_neo4j_password_dev` | `group_vars/all/vault.yml` | `colossus-legal-backend.env.j2` |
| `vault_colossus_legal_neo4j_password_prod` | `group_vars/all/vault.yml` | `colossus-legal-backend.env.j2` |

**When adding a new service endpoint (e.g., Qdrant):**
1. Add the variable to `group_vars/dev.yml` and `group_vars/prod.yml`
2. Add the `{{ variable }}` reference to `colossus-legal-backend.env.j2`
3. Add any secrets to `group_vars/all/vault.yml`
4. Deploy via Ansible/Semaphore

---

## 10. Change Log

| Date | Change | Author |
|------|--------|--------|
| 2026-02-23 | Initial version | Roman + Claude |
