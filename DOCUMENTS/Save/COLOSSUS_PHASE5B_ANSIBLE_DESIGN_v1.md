# COLOSSUS Phase 5B — Ansible Automation & Application Pipeline Design

**Document Type:** Technical Design & Implementation Plan
**Phase:** 5B — Configuration Management & Automation
**Author:** Colossus Infrastructure Team
**Date:** 2026-02-12
**Status:** DESIGN — Ready for review and execution
**Depends on:** Phase 5A (Traefik) ✅ Complete

---

## 1. Purpose

This document defines the strategy for introducing Ansible as the configuration management backbone for Colossus. The scope extends beyond "install Ansible" to address a fundamental operational question:

> **How do we deploy the next application — and the one after that — without re-inventing the process each time?**

Colossus-Legal took roughly 8 hours of interactive sessions across Phases 4A, 4B, and 5A to go from "container images exist" to "accessible via HTTPS internally and externally with TLS." That process must become a 20-minute playbook execution.

This document covers the current state, desired state, implementation plan, validation strategy, and the future tooling roadmap including deployment of Colossus-AI, Opik, and Helicone.

---

## 2. Current State — What Exists Today

### 2.1 Infrastructure Inventory

```
pve-1 (PROD)              pve-2 (DEV)               pve-3 (Infra)
├── VM-110 PROD DB         ├── VM-200 Frozen ref      ├── VM-900 PBS
├── VM-120 PROD App        ├── VM-210 DEV DB          ├── CT-311 Pi-hole
                           ├── VM-220 DEV App         ├── CT-312 cloudflared
                                                      ├── CT-313 Traefik
```

### 2.2 How Things Are Deployed Today

Every VM and container was deployed through a combination of:

1. **Shell scripts** — `01-create-*.sh`, `02-install-*.sh` run manually on Proxmox hosts
2. **Butane/Ignition** — CoreOS VMs provisioned via Ignition files compiled from `.bu` sources
3. **Manual steps** — Cloudflare dashboard tunnel routes, Pi-hole DNS records via web UI, PBS backup jobs via Proxmox UI
4. **Ad-hoc SSH** — Environment variable fixes, service restarts, troubleshooting

This approach works but has compounding problems:

| Problem | Impact |
|---------|--------|
| **No idempotency** | Running a script twice can fail or create duplicates |
| **No drift detection** | Live state diverges from source files (proven: Butane files were stale for days) |
| **Manual DNS/routing** | Pi-hole records and Traefik routes added by hand each time |
| **No dry-run** | Can't preview what a deployment will change |
| **Copy-paste scaling** | Deploying colossus-ai means duplicating and editing colossus-legal scripts |
| **Secrets scattered** | Passwords in env files on VMs, API tokens in CT configs, tunnel tokens in Cloudflare |

### 2.3 Application Deployment Steps (Current Process)

Deploying a new application currently requires these manual steps:

```
 1. Write Butane file with Quadlet containers, env files, systemd config
 2. Transpile .bu → .ign
 3. Copy .ign to Proxmox node /var/coreos/snippets/
 4. Create VM via qm commands (or shell script)
 5. Start VM, SSH in, verify containers running
 6. Add DNS records in Pi-hole UI (hostname → Traefik IP)
 7. Add HTTPS router in Traefik dynamic config
 8. Add HTTP router for tunnel traffic (if externally accessible)
 9. Reload Traefik (or wait for hot-reload)
10. Add tunnel route in Cloudflare dashboard (if externally accessible)
11. Update Cloudflare Access policy (if externally accessible)
12. Test from LAN (HTTPS) and cellular (tunnel)
13. Create PBS backup job
14. Update master context documentation
```

That's 14 manual steps with 4 different UIs (SSH, Pi-hole, Cloudflare, Proxmox).

---

## 3. Desired State — What Ansible Should Deliver

### 3.1 The Goal

Deploying a new application should require:

```bash
# One command to deploy a new app to DEV
ansible-playbook deploy-app.yml -e "app=colossus-ai env=dev" --diff --check  # dry-run
ansible-playbook deploy-app.yml -e "app=colossus-ai env=dev"                 # execute

# One command to promote to PROD
ansible-playbook deploy-app.yml -e "app=colossus-ai env=prod"
```

Behind that single command, Ansible handles all 14 steps automatically and idempotently.

### 3.2 Desired Properties

| Property | Description |
|----------|-------------|
| **Idempotent** | Run the same playbook 10 times, get the same result |
| **Declarative inventory** | All hosts, IPs, roles defined in one place |
| **Dry-run capable** | `--check --diff` shows what would change without touching anything |
| **Role-based** | Reusable roles: `coreos-app-vm`, `lxc-service`, `traefik-route`, `pihole-dns` |
| **Environment-aware** | Same playbook, different variables for DEV vs PROD |
| **Secrets centralized** | Ansible Vault encrypts all credentials in one file |
| **Self-documenting** | The playbook IS the documentation — no separate runbook to maintain |
| **Validated** | Built-in verification tasks confirm success after each step |

### 3.3 Inventory Structure (Target)

```ini
# inventory/hosts.yml
all:
  children:
    proxmox:
      hosts:
        pve-1:
          ansible_host: 10.10.100.1
          role: prod
        pve-2:
          ansible_host: 10.10.100.2
          role: dev
        pve-3:
          ansible_host: 10.10.100.3
          role: infra

    coreos_vms:
      children:
        db_vms:
          hosts:
            colossus-prod-db1:
              ansible_host: 10.10.100.110
              proxmox_node: pve-1
              vmid: 110
            colossus-dev-db1:
              ansible_host: 10.10.100.200
              proxmox_node: pve-2
              vmid: 210
        app_vms:
          hosts:
            colossus-prod-app1:
              ansible_host: 10.10.100.120
              proxmox_node: pve-1
              vmid: 120
            colossus-dev-app1:
              ansible_host: 10.10.100.220
              proxmox_node: pve-2
              vmid: 220

    infrastructure:
      hosts:
        pihole:
          ansible_host: 10.10.100.53
          ctid: 311
        cloudflared:
          ansible_host: 10.10.100.54
          ctid: 312
        traefik:
          ansible_host: 10.10.100.55
          ctid: 313
```

### 3.4 Role Library (Target)

| Role | Purpose | Applies To |
|------|---------|-----------|
| `proxmox-vm` | Create CoreOS VM (qm commands, Ignition) | Proxmox hosts |
| `proxmox-lxc` | Create LXC container | Proxmox hosts |
| `coreos-app` | Deploy Quadlet containers on CoreOS | App VMs |
| `traefik-route` | Add/update routers and services in dynamic config | CT-313 |
| `pihole-dns` | Manage local DNS records | CT-311 |
| `pbs-backup` | Create/verify PBS backup jobs | Proxmox hosts |
| `ansible-vault-secrets` | Manage encrypted secrets | Control node |

---

## 4. Application Pipeline — Repeatable Deployment Pattern

### 4.1 Application Definition Model

Each application is defined by a variable file that Ansible consumes:

```yaml
# apps/colossus-legal.yml
app_name: colossus-legal
app_display_name: "Colossus Legal"

containers:
  backend:
    image: ghcr.io/rhrywnak/colossus-backend:v0.1.0
    port: 3403
    env:
      NEO4J_URI: bolt://{{ db_host }}:7687
      NEO4J_USER: neo4j
      NEO4J_PASSWORD: "{{ vault_neo4j_password }}"
      CORS_ALLOWED_ORIGINS: "{{ cors_origins }}"
  frontend:
    image: ghcr.io/rhrywnak/colossus-frontend:v0.1.0
    port: 5473
    env:
      COLOSSUS_API_URL: "https://{{ api_hostname }}"

dns_records:
  - hostname: colossus-legal
    target: "{{ traefik_ip }}"
  - hostname: colossus-legal-api
    target: "{{ traefik_ip }}"

traefik_routes:
  - name: colossus-legal-frontend
    host: "colossus-legal.{{ domain }}"
    backend: "http://{{ app_ip }}:5473"
  - name: colossus-legal-api
    host: "colossus-legal-api.{{ domain }}"
    backend: "http://{{ app_ip }}:3403"

external_access: true   # creates tunnel routes + HTTP routers
tunnel_routes:
  - hostname: "colossus-legal.{{ domain }}"
  - hostname: "colossus-legal-api.{{ domain }}"
```

### 4.2 Colossus-AI — Next Application

Colossus-AI (arXiv LLM paper analysis with summary, insights, and tutorial capabilities) follows the identical pattern:

```yaml
# apps/colossus-ai.yml
app_name: colossus-ai
app_display_name: "Colossus AI"

containers:
  backend:
    image: ghcr.io/rhrywnak/colossus-ai-backend:v0.1.0
    port: 3404                              # unique port
    env:
      NEO4J_URI: bolt://{{ db_host }}:7687
      NEO4J_USER: neo4j
      NEO4J_PASSWORD: "{{ vault_neo4j_password }}"
      CORS_ALLOWED_ORIGINS: "{{ cors_origins }}"
      # LLM-specific config
      OPIK_BASE_URL: "http://{{ opik_host }}:5173"
      ANTHROPIC_API_KEY: "{{ vault_anthropic_api_key }}"
  frontend:
    image: ghcr.io/rhrywnak/colossus-ai-frontend:v0.1.0
    port: 5474                              # unique port
    env:
      COLOSSUS_API_URL: "https://{{ api_hostname }}"

dns_records:
  - hostname: colossus-ai
    target: "{{ traefik_ip }}"
  - hostname: colossus-ai-api
    target: "{{ traefik_ip }}"

traefik_routes:
  - name: colossus-ai-frontend
    host: "colossus-ai.{{ domain }}"
    backend: "http://{{ app_ip }}:5474"
  - name: colossus-ai-api
    host: "colossus-ai-api.{{ domain }}"
    backend: "http://{{ app_ip }}:3404"

external_access: true
tunnel_routes:
  - hostname: "colossus-ai.{{ domain }}"
  - hostname: "colossus-ai-api.{{ domain }}"
```

The key insight: **the deployment playbook doesn't change.** Only the variable file changes. Same roles, same validation, same process. This is what makes the 10th application as easy as the 2nd.

### 4.3 VM Allocation Strategy

Two options for hosting multiple applications:

**Option A: Shared App VMs (recommended for now)**
- Colossus-Legal and Colossus-AI share VM-120 (PROD) and VM-220 (DEV)
- Different ports, same Quadlet/systemd management
- Lower resource overhead, simpler backup
- Works well until apps need isolation or different resource profiles

**Option B: Dedicated App VMs (future)**
- Each app gets its own VM pair (e.g., VM-130/VM-230 for colossus-ai)
- Better isolation, independent scaling and updates
- Ansible makes this trivial — just change `vmid` and `app_ip` in variables

Start with Option A. Ansible makes switching to Option B a variable change, not a re-architecture.

---

## 5. LLM Analysis Tooling — Opik & Helicone

### 5.1 Opik — LLM Tracing & Evaluation

**What it does:** Debug, evaluate, and monitor LLM applications. Traces every LLM call with inputs, outputs, latency, token usage. Automated evaluation with LLM-as-a-judge metrics (hallucination detection, relevance scoring). Production dashboards.

**Architecture (self-hosted Docker Compose):**

| Service | Purpose | Resource Notes |
|---------|---------|---------------|
| **Backend** (Java/Dropwizard) | REST API, trace ingestion | Port 8080 |
| **Python Backend** | Evaluation engine, code execution | Port 8000 |
| **Frontend** (React/nginx) | Web UI | Port 5173 |
| **ClickHouse** | Analytics storage (columnar) | Memory-hungry: 4GB+ recommended |
| **MySQL** | Transactional storage | Standard |
| **Redis** | Cache, distributed locks, streaming | Standard |
| **ZooKeeper** | ClickHouse coordination | Lightweight |
| **MinIO** | Object storage (file attachments) | Lightweight |

**Resource estimate:** 4-8GB RAM total for all services. ClickHouse is the biggest consumer.

**Integration with Colossus-AI:**
```python
from opik.integrations.openai import track_openai
# or for Anthropic:
import opik
opik.configure(use_local=True)  # points to self-hosted Opik
```

Colossus-AI backend adds the Opik Python SDK. Every LLM call (arXiv paper analysis, summary generation, tutorial creation) is automatically traced and visible in the Opik dashboard.

### 5.2 Helicone — LLM Gateway & Observability

**What it does:** AI gateway that sits between your app and LLM providers. Logs every request, tracks costs, enables caching, rate limiting, and model fallbacks. One-line integration (change `base_url` in your OpenAI/Anthropic client).

**Architecture (self-hosted Docker):**

| Service | Purpose | Resource Notes |
|---------|---------|---------------|
| **All-in-one container** | Gateway + Dashboard + API | Ports 3000, 8585, 9080 |
| **PostgreSQL** | Request/response storage | Included in all-in-one |
| **ClickHouse** | Analytics aggregation | Included in all-in-one |
| **MinIO** | Object storage | Included in all-in-one |

Helicone recently simplified from 12 containers to 4 (or a single all-in-one image). Much lighter than Opik.

**Resource estimate:** 2-4GB RAM for the all-in-one container.

**Integration with Colossus-AI:**
```python
from openai import OpenAI
client = OpenAI(
    base_url="http://helicone-host:8585/v1/gateway/anthropic/v1/messages",
    api_key=os.getenv("ANTHROPIC_API_KEY"),
)
```

### 5.3 Opik vs Helicone — Complementary, Not Competing

| Capability | Opik | Helicone |
|-----------|------|----------|
| **Primary role** | Tracing & evaluation | Gateway & cost optimization |
| LLM call tracing | ✅ Deep (spans, nested traces) | ✅ Request-level |
| Automated evaluation | ✅ LLM-as-a-judge, datasets | ❌ |
| Cost tracking | ✅ Token-level | ✅ Per-request + aggregated |
| Caching | ❌ | ✅ Response caching |
| Rate limiting | ❌ | ✅ Per-key, per-model |
| Model fallback/routing | ❌ | ✅ Automatic failover |
| Prompt management | ✅ Playground | ✅ Prompt versioning |
| Self-hosted complexity | Medium (8 containers) | Low (1-4 containers) |
| RAM requirement | 4-8 GB | 2-4 GB |

**Recommendation:** Start with Opik (higher value for development and debugging of Colossus-AI). Add Helicone later when you need gateway features (caching, cost optimization, multi-model routing). Both deploy as Ansible-managed Docker Compose stacks.

### 5.4 Deployment Strategy for LLM Tooling

These are multi-container Docker Compose applications — they don't fit the CoreOS + Quadlet model used for Colossus apps. Best approach:

**Option A: Dedicated LXC container(s) on pve-3** (recommended)
- CT-314 for Opik (Debian 12 + Docker Compose)
- CT-315 for Helicone (if/when added)
- Traefik routes: `opik.cogmai.com`, `helicone.cogmai.com`
- Follows the same LXC pattern as Pi-hole, cloudflared, Traefik
- Ansible manages the full lifecycle

**Option B: Dedicated VM on pve-2 (DEV tools VM)**
- Single VM running Docker with both Opik and Helicone
- More resources available, but heavier

Option A aligns with the Colossus principle of "infrastructure services on pve-3."

---

## 6. Implementation Plan — Phased Approach

### Phase 5B-1: Ansible Foundation (Day 1)

**Goal:** Ansible installed, inventory working, first playbook runs successfully.

| Step | Action | Validation |
|------|--------|-----------|
| 1 | Install Ansible on workstation | `ansible --version` returns 2.16+ |
| 2 | Install `proxmoxer` Python library | `python3 -c "import proxmoxer"` succeeds |
| 3 | Install `community.proxmox` collection | `ansible-galaxy collection list` shows it |
| 4 | Create inventory file with all hosts | `ansible all -m ping` succeeds for all hosts |
| 5 | Create `ansible.cfg` with defaults | SSH key, inventory path, vault config |
| 6 | Create Ansible Vault file for secrets | `ansible-vault view secrets.yml` decrypts |
| 7 | Write `ping-all.yml` playbook | Validates connectivity to every host |

**Deliverables:** Working Ansible control node, inventory, vault, connectivity proven.

### Phase 5B-2: Codify Existing Infrastructure (Day 2)

**Goal:** Convert existing manual processes to Ansible roles. Don't deploy anything new — just make the current state reproducible.

| Role | Codifies | Source |
|------|----------|--------|
| `traefik-route` | Adding routers/services to Traefik dynamic config | Manual SSH + file edit |
| `pihole-dns` | Adding DNS records to Pi-hole | Manual web UI clicks |
| `coreos-app` | Deploying Quadlet containers + env files to CoreOS | Butane files + manual SSH |
| `pbs-backup` | Creating PBS backup jobs | Manual Proxmox UI |
| `proxmox-vm` | Creating CoreOS VMs via qm | Shell scripts |
| `proxmox-lxc` | Creating LXC containers | Shell scripts |

**Approach:** Start with the roles that affect running services (traefik-route, pihole-dns) since they're the most frequently needed and can be validated immediately against live state.

**Deliverables:** Role library that can reproduce the current infrastructure from scratch.

### Phase 5B-3: Application Deployment Playbook (Day 3)

**Goal:** The `deploy-app.yml` playbook that deploys any application defined by a variable file.

```
deploy-app.yml
├── Include app variables (apps/colossus-legal.yml)
├── Role: proxmox-vm (create VM if not exists)
├── Role: coreos-app (deploy containers + env files)
├── Role: pihole-dns (add DNS records)
├── Role: traefik-route (add Traefik routers)
├── Role: pbs-backup (create backup job)
└── Validation tasks (curl health endpoints, verify DNS, check Traefik dashboard)
```

**Validation:** Run against DEV with `colossus-legal.yml` variables. Confirm it's fully idempotent — running twice changes nothing.

**Deliverables:** Working `deploy-app.yml` + `colossus-legal.yml` app definition.

### Phase 5B-4: Deploy Colossus-AI (Day 4+)

**Goal:** First real test of the pipeline — deploy a new application using only Ansible.

| Step | Action |
|------|--------|
| 1 | Create `apps/colossus-ai.yml` variable file |
| 2 | Build and push colossus-ai container images to ghcr.io |
| 3 | Run `deploy-app.yml -e "app=colossus-ai env=dev"` |
| 4 | Validate: `https://colossus-ai-dev.cogmai.com` loads |
| 5 | Run again — confirm idempotent (0 changes) |
| 6 | Promote: `deploy-app.yml -e "app=colossus-ai env=prod"` |
| 7 | Validate: external access via cellular |

**Success criteria:** The entire deployment is one command. No manual steps. No SSH.

### Phase 5B-5: Deploy Opik (Day 5+)

**Goal:** Self-hosted Opik running on CT-314, accessible via `opik.cogmai.com`.

| Step | Action |
|------|--------|
| 1 | Create `deploy-lxc-service.yml` playbook for Docker Compose services |
| 2 | Create `services/opik.yml` variable file (ports, volumes, compose profile) |
| 3 | Run playbook to create CT-314, install Docker, deploy Opik |
| 4 | Role: traefik-route adds `opik.cogmai.com` |
| 5 | Role: pihole-dns adds DNS record |
| 6 | Validate: `https://opik.cogmai.com` shows Opik dashboard |
| 7 | Configure Colossus-AI backend to point to Opik |

**Resource allocation for CT-314:**
- 8 GB RAM (ClickHouse needs breathing room)
- 4 CPU cores
- 32 GB disk (ClickHouse analytics data grows)

### Phase 5B-6: Deploy Helicone (Optional, Day 6+)

Same pattern as Opik but lighter:
- CT-315, 4 GB RAM, 2 cores, 16 GB disk
- `helicone.cogmai.com` via Traefik
- All-in-one Docker image (simplest deployment)

---

## 7. Validation Strategy

### 7.1 Per-Playbook Validation

Every playbook includes built-in validation tasks that run after deployment:

```yaml
# Example validation block (included in every playbook)
- name: Validate deployment
  block:
    - name: Check container is running
      ansible.builtin.command: podman ps --filter name={{ container_name }} --format "{{ '{{' }}.Status{{ '}}' }}"
      register: container_status
      failed_when: "'Up' not in container_status.stdout"

    - name: Check health endpoint
      ansible.builtin.uri:
        url: "http://{{ app_ip }}:{{ backend_port }}/health"
        status_code: 200
      retries: 5
      delay: 3

    - name: Verify DNS resolution
      ansible.builtin.command: nslookup {{ hostname }}.{{ domain }} {{ pihole_ip }}
      register: dns_result
      failed_when: traefik_ip not in dns_result.stdout

    - name: Verify HTTPS access via Traefik
      ansible.builtin.uri:
        url: "https://{{ hostname }}.{{ domain }}"
        status_code: 200
        validate_certs: yes
      delegate_to: localhost
```

### 7.2 Infrastructure-Wide Validation Playbook

A dedicated `validate-all.yml` playbook that checks the entire infrastructure:

```yaml
# validate-all.yml — run anytime, especially after changes or reboots
#
# Checks:
#   ✓ All Proxmox nodes reachable
#   ✓ All VMs/CTs running
#   ✓ All containers healthy (podman ps on each VM)
#   ✓ All DNS records resolve correctly
#   ✓ All Traefik routes return 200
#   ✓ HTTPS certificates valid and not expiring within 30 days
#   ✓ PBS backup jobs exist and last backup < 48 hours
#   ✓ ZFS pool health on pve-1 and pve-2
#   ✓ Disk space > 20% free on all hosts
```

This is the "morning coffee" playbook — run it daily or after any change to confirm everything is healthy.

### 7.3 Idempotency Validation

The most important test for any Ansible role:

```bash
# Run once — expect changes
ansible-playbook deploy-app.yml -e "app=colossus-legal env=dev"
# Output: changed=N

# Run again immediately — expect zero changes
ansible-playbook deploy-app.yml -e "app=colossus-legal env=dev"
# Output: changed=0  ← THIS IS THE TEST
```

If the second run shows changes, the role is not idempotent and must be fixed.

### 7.4 Drift Detection

Weekly scheduled playbook in `--check --diff` mode:

```bash
ansible-playbook deploy-all.yml --check --diff
```

This reports what would change without touching anything. If it reports changes, something has drifted from the declared state — investigate before it becomes a problem.

---

## 8. Directory Structure

```
~/colossus-ansible/
├── ansible.cfg                    # Ansible configuration
├── inventory/
│   └── hosts.yml                  # All hosts, groups, variables
├── group_vars/
│   ├── all.yml                    # Global variables (domain, IPs)
│   ├── proxmox.yml                # Proxmox-specific vars
│   ├── coreos_vms.yml             # CoreOS connection settings
│   └── infrastructure.yml         # LXC container settings
├── host_vars/
│   ├── pve-1.yml                  # PROD node specifics
│   ├── pve-2.yml                  # DEV node specifics
│   └── pve-3.yml                  # Infra node specifics
├── secrets/
│   └── vault.yml                  # Ansible Vault encrypted secrets
├── apps/                          # Application definitions
│   ├── colossus-legal.yml
│   └── colossus-ai.yml
├── services/                      # Docker Compose service definitions
│   ├── opik.yml
│   └── helicone.yml
├── roles/
│   ├── proxmox-vm/
│   │   ├── tasks/main.yml
│   │   ├── templates/
│   │   └── defaults/main.yml
│   ├── proxmox-lxc/
│   ├── coreos-app/
│   ├── traefik-route/
│   │   ├── tasks/main.yml
│   │   └── templates/services.yml.j2
│   ├── pihole-dns/
│   ├── pbs-backup/
│   └── docker-compose-service/
├── playbooks/
│   ├── deploy-app.yml             # Deploy any application
│   ├── deploy-lxc-service.yml     # Deploy Docker Compose services
│   ├── validate-all.yml           # Infrastructure-wide health check
│   ├── backup-all.yml             # Trigger all backup jobs
│   └── update-containers.yml      # Pull latest images, restart
└── butane/                        # Butane source files (templates)
    ├── coreos-app.bu.j2           # Jinja2-templated Butane
    ├── coreos-db.bu.j2
    └── README.md
```

---

## 9. Future Tooling Roadmap

### 9.1 Near-Term (Phase 5B complete → Phase 5C)

| Tool | Purpose | When |
|------|---------|------|
| **Semaphore UI** | Web dashboard for Ansible playbook execution | After core playbooks are stable |
| **Forgejo** | Self-hosted Git for infrastructure code | When playbook library grows |

Semaphore UI deploys as 2 containers on pve-3 (CT-316). Gives you a web UI to trigger playbooks, view execution history, and schedule jobs (drift detection, backups). Think of it as the "control panel" for your automation.

### 9.2 Medium-Term (As complexity grows)

| Tool | Purpose | When |
|------|---------|------|
| **OpenTofu** | Declarative VM/CT provisioning with state tracking | When managing 15+ VMs/CTs |
| **Infisical** | Centralized secrets management with API access | When Ansible Vault becomes limiting |
| **Packer** | Automated CoreOS template builds | When managing multiple OS variants |

### 9.3 Long-Term (Full GitOps pipeline)

```
Developer pushes code
    → Forgejo Actions builds container image
        → Pushes to ghcr.io
            → Semaphore UI triggers deploy-app.yml
                → Ansible deploys to DEV
                    → Validation playbook runs
                        → On success: promote to PROD
```

This is the end-state vision. Every component (Forgejo, Semaphore, Ansible, Traefik, Pi-hole) already exists in the Colossus architecture or is planned. The pipeline emerges naturally as each piece is added.

### 9.4 Application Roadmap Summary

| Application | Type | Status | Deployment Method |
|-------------|------|--------|-------------------|
| Colossus-Legal | Rust/React web app | ✅ Running | Manual (to be codified) |
| Colossus-AI | Python/React LLM app | ⏳ On hold | Ansible playbook |
| Opik | LLM observability (Docker Compose) | 📋 Planned | Ansible + Docker Compose |
| Helicone | LLM gateway (Docker) | 📋 Evaluating | Ansible + Docker |
| Semaphore UI | Ansible orchestration (Docker) | 📋 Planned | Ansible + Docker |
| Forgejo | Git hosting (Docker) | 📋 Planned | Ansible + Docker |

---

## 10. Rust Learning Opportunity

Phase 5B has a Rust angle worth highlighting. The Colossus-AI backend will likely be Rust/Axum (matching Colossus-Legal), and the LLM integration introduces interesting Rust patterns:

- **Async HTTP clients** — calling Anthropic/OpenAI APIs from Axum handlers using `reqwest`
- **Streaming responses** — Server-Sent Events for real-time LLM output (Axum + `tokio::sync::mpsc`)
- **Middleware patterns** — intercepting LLM calls for Opik/Helicone tracing
- **Error handling** — graceful degradation when LLM providers are slow or down
- **Configuration management** — runtime config via environment variables (the CORS pattern from Colossus-Legal, extended)

We can explore these patterns as Colossus-AI development progresses.

---

## 11. Success Criteria

Phase 5B is complete when:

1. ✅ Ansible inventory covers all 9 VMs/CTs
2. ✅ `ansible all -m ping` succeeds for every host
3. ✅ Ansible Vault stores all secrets (Neo4j passwords, API tokens, Cloudflare token)
4. ✅ `deploy-app.yml` successfully deploys Colossus-Legal to DEV (idempotent)
5. ✅ `validate-all.yml` passes with zero failures
6. ✅ Colossus-AI deployed to DEV using only `deploy-app.yml`
7. ✅ Opik running on CT-314, accessible via `opik.cogmai.com`
8. ✅ Second run of every playbook shows `changed=0`

---

## 12. Risk Assessment

| Risk | Mitigation |
|------|-----------|
| CoreOS immutable filesystem limits Ansible modules | Use `ansible.builtin.command`/`raw` for CoreOS-specific tasks; Ansible connects via SSH which works fine |
| Pi-hole v6 API changes break dns role | Pi-hole v6 has a REST API at `/api`; fall back to editing config files via SSH |
| Traefik dynamic config format changes | Template the YAML; validate with `traefik healthcheck` after changes |
| ClickHouse (Opik) consumes too much RAM on LXC | Set memory limits in LXC config; tune ClickHouse `max_server_memory_usage_to_ram_ratio` |
| Ansible learning curve | Ansible YAML is readable by anyone with shell script experience; roles are just organized tasks |

---

## 13. Decision Log

| Decision | Rationale |
|----------|-----------|
| Ansible over Komodo | Podman/CoreOS support; agentless; covers full lifecycle |
| Ansible Vault over Infisical | Zero additional infrastructure for Phase 5B; upgrade path exists |
| Opik before Helicone | Higher value for Colossus-AI development (tracing, evaluation); Helicone adds gateway features later |
| LXC for Opik/Helicone, not CoreOS VM | Docker Compose tools don't fit Quadlet model; LXC on pve-3 follows infra services pattern |
| Shared App VMs initially | Lower overhead; Ansible makes dedicated VMs a variable change later |
| Semaphore UI deferred to 5C | Core playbooks must be stable before adding orchestration UI |

---

## 14. References

| Document | Purpose |
|----------|---------|
| `PHASE5_AUTOMATION_TOOLING_SESSION_TRANSITION.md` | Full tooling research (Ansible, OpenTofu, Semaphore, secrets) |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v3.md` | Current infrastructure state |
| `APPLICATION_DEPLOYMENT_REQUIREMENTS.md` | Colossus-Legal deployment requirements |
| [Opik GitHub](https://github.com/comet-ml/opik) | LLM observability platform |
| [Helicone GitHub](https://github.com/Helicone/helicone) | LLM gateway & observability |
| [Opik self-host guide](https://www.comet.com/docs/opik/self-host/local_deployment/) | Docker Compose deployment |
| [Helicone self-host guide](https://docs.helicone.ai/getting-started/self-host/docker) | Docker deployment |
