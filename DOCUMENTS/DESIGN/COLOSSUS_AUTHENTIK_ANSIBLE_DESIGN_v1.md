# Colossus — Authentik Ansible Integration Design v1

**Document Type:** Design Document  
**Phase:** Stage 5C-5D (Authentik Configuration + Traffic Switchover)  
**Author:** Colossus Infrastructure Team  
**Date:** 2026-02-27  
**Status:** DESIGN — Awaiting review  
**Depends on:** Stage 5A ✅ (VM-316 created), Stage 5B ✅ (containers running)  
**Related docs:**
- `COLOSSUS_AUTHENTIK_MIGRATION_DESIGN_v1.md` — Migration architecture
- `COLOSSUS_AUTH_EXECUTION_TASK_TRACKER_v2.md` — Stage tracker
- `COLOSSUS_ANSIBLE_RUNBOOK_v2.md` — Ansible patterns and role inventory

---

## 1. Purpose

This document defines every change required to the `colossus-ansible` repository to make the Authentik deployment fully reproducible via Ansible. It covers seven work items:

1. **Fix Butane config** — incorporate `overwrite: true` and `AUTHENTIK_HOST` fixes discovered during Stage 5A execution
2. **Provisioning recipe** — `vars/vm-316-authentik.yml` for disaster recovery
3. **Inventory update** — add VM-316 to `hosts.yml`
4. **New `authentik-config` role** — API-based role to configure Authentik (provider, application, groups, users, brand, outpost)
5. **Traefik role update** — extend `traefik-route` template with auth middleware support
6. **Pi-hole update** — add `auth.cogmai.com` DNS record (already exists from Authelia stage, verify only)
7. **New playbooks** — `configure-authentik.yml` and updated `manage-traefik.yml` variables

The design follows established patterns: API-based roles follow the `pihole-dns` pattern, template-based changes follow the `traefik-route` pattern, and provisioning recipes follow the `vars/` convention.

---

## 2. Current State Assessment

### 2.1 What Exists (Done in Stage 5A/5B)

| Item | State | Location |
|------|-------|----------|
| VM-316 on pve-3 | Running | CoreOS, 2 cores, 2048MB, IP 10.10.100.58 |
| ZFS datasets | Created | `pbs-zfs/services/authentik/{postgres,data}` |
| Containers | Running | postgresql, authentik-server, authentik-worker |
| Provisioning scripts | In repo | `~/Projects/colossus-homelab/authentik/` |
| Butane config | In repo | `~/Projects/colossus-homelab/authentik/authentik.bu` |

### 2.2 What Was Done Manually (Needs Automation)

| Item | How it was done | Problem |
|------|----------------|---------|
| Proxy provider (`colossus-forward-auth`) | Authentik admin UI | Lost on VM rebuild |
| Application (`Colossus Services`) | Authentik admin UI | Lost on VM rebuild |
| Embedded outpost → application binding | Authentik admin UI | Lost on VM rebuild |
| Brand domain (`auth.cogmai.com`) | Authentik admin UI | Lost on VM rebuild |
| Groups (admin, legal_editor, legal_viewer, ai_user) | Authentik admin UI | Lost on VM rebuild |
| User `roman` with group membership | Authentik admin UI | Lost on VM rebuild |
| `AUTHENTIK_HOST=http://localhost:9000` | Manual edit on VM | Butane out of sync |
| Traefik `services.yml` | Not yet applied | Template doesn't support auth middleware |

### 2.3 What's Missing from Ansible Repo

| Item | Type | Why it matters |
|------|------|---------------|
| `vars/vm-316-authentik.yml` | Provisioning recipe | No DR documentation |
| VM-316 in `inventory/hosts.yml` | Inventory entry | Ansible can't reach it |
| `roles/authentik-config/` | New role | No automated configuration |
| Auth middleware in `traefik-route` | Template gap | Can't protect routes |
| `host_vars/authentik.yml` | Host variables | No variable file for API calls |
| `playbooks/configure-authentik.yml` | New playbook | No orchestration |

---

## 3. Butane Config Fixes

Two issues were discovered during Stage 5A execution. These must be incorporated into the canonical `authentik.bu` in `colossus-homelab/authentik/`:

### 3.1 Hostname Overwrite

CoreOS ships with a default `/etc/hostname`. Ignition refuses to replace without explicit `overwrite: true`.

```yaml
# BEFORE (broken):
- path: /etc/hostname
  mode: 0644
  contents:
    inline: authentik

# AFTER (working):
- path: /etc/hostname
  mode: 0644
  overwrite: true
  contents:
    inline: authentik
```

### 3.2 AUTHENTIK_HOST Environment Variable

The embedded outpost needs to know how to reach the Authentik API. Without this, the outpost logs: `"Outpost has localhost/blank API Connection but no authentik_host is configured."`

Add to `/etc/authentik/env/authentik.env` in the Butane config:

```
AUTHENTIK_HOST=http://localhost:9000
```

This line must be added to the `authentik.env` inline content in `authentik.bu`.

---

## 4. Provisioning Recipe — `vars/vm-316-authentik.yml`

Follows the established pattern from `vars/vm-110-prod-db.yml`, `vars/ct-311-pihole.yml`, etc. This file serves as both Ansible input and disaster recovery documentation.

```yaml
---
# VM-316 Authentik — Provisioning Recipe
# Used with: ansible-playbook playbooks/create-vm.yml -e @vars/vm-316-authentik.yml
#
# This file documents every parameter needed to recreate VM-316 from scratch.
# The VM runs on CoreOS with Podman Quadlet containers for Authentik.

# ── VM Identity ─────────────────────────────────────────────
vm_id: 316
vm_name: authentik
vm_description: "Authentik identity provider (CoreOS + Podman Quadlet)"
proxmox_node: pve-3

# ── Hardware ────────────────────────────────────────────────
vm_cores: 2
vm_memory: 2048
vm_disk_size: 20G
vm_machine: q35
vm_cpu_type: host

# ── Network ─────────────────────────────────────────────────
vm_ip: 10.10.100.58
vm_cidr: 24
vm_gateway: 10.10.100.1
vm_bridge: vmbr0
vm_nameserver: 10.10.100.53

# ── Storage ─────────────────────────────────────────────────
vm_boot_storage: pbs-zfs
vm_ignition_storage: coreos-snippets
vm_ignition_file: authentik.ign

# ── ZFS Datasets ────────────────────────────────────────────
# Created by colossus-homelab/authentik/01-create-zfs-datasets.sh
zfs_datasets:
  - path: pbs-zfs/services/authentik/postgres
    recordsize: 8K
    description: "PostgreSQL database files"
  - path: pbs-zfs/services/authentik/data
    recordsize: 128K
    description: "Authentik media, templates, exports"

# ── Proxmox Directory Mappings (virtiofs) ───────────────────
directory_mappings:
  - name: authentik-postgres
    path: /pbs-zfs/services/authentik/postgres
  - name: authentik-data
    path: /pbs-zfs/services/authentik/data

# ── Container Images ────────────────────────────────────────
authentik_version: "2025.12"
postgres_version: "16-alpine"

# ── Service Ports ───────────────────────────────────────────
authentik_http_port: 9000
authentik_https_port: 9443
postgres_port: 5432
```

---

## 5. Inventory Update — `hosts.yml`

### 5.1 Add VM-316 to Inventory

Add under `coreos_vms` → new child group `auth_vms`:

```yaml
    coreos_vms:
      children:
        db_vms:
          hosts:
            # ... existing ...
        app_vms:
          hosts:
            # ... existing ...
        auth_vms:
          hosts:
            authentik:
              ansible_host: 10.10.100.58
              proxmox_node: pve-3
              vmid: 316
```

This inherits `ansible_user: core` and `ansible_python_interpreter: /usr/bin/python3` from the `coreos_vms` group vars.

### 5.2 Host Variables — `inventory/host_vars/authentik.yml`

```yaml
---
# Authentik (VM-316) — Configuration via REST API
#
# The authentik-config role uses these variables to configure
# Authentik via its /api/v3/ REST API. This is the single source
# of truth for all Authentik configuration.
#
# API authentication uses a token created during initial setup.
# The token is stored in Ansible Vault.

# ── API Connection ──────────────────────────────────────────
authentik_api_base: "http://10.10.100.58:9000/api/v3"
# authentik_api_token is in vault.yml

# ── Brand Configuration ─────────────────────────────────────
authentik_brand_domain: "auth.cogmai.com"

# ── Provider (Proxy — Forward Auth Domain Level) ────────────
authentik_provider:
  name: "colossus-forward-auth"
  authorization_flow_slug: "default-provider-authorization-implicit-consent"
  mode: "forward_domain"
  external_host: "https://auth.cogmai.com"
  cookie_domain: "cogmai.com"
  access_token_validity: "hours=24"

# ── Application ─────────────────────────────────────────────
authentik_application:
  name: "Colossus Services"
  slug: "colossus-services"

# ── Groups ──────────────────────────────────────────────────
# Declarative: groups not listed here will NOT be removed
# (to preserve authentik's built-in groups).
authentik_groups:
  - name: "admin"
  - name: "legal_editor"
  - name: "legal_viewer"
  - name: "ai_user"

# ── Users ───────────────────────────────────────────────────
# Passwords are in vault.yml. Users are created if they don't exist.
# Group membership is enforced on every run.
authentik_users:
  - username: "roman"
    name: "Roman"
    email: "roman@cogmai.com"
    groups:
      - "admin"
      - "legal_editor"
      - "ai_user"
```

### 5.3 Vault Additions

Add to `inventory/group_vars/vault.yml` (or `inventory/group_vars/all/vault.yml`):

```yaml
# ── Authentik ──────────────────────────────────────────────
vault_authentik_api_token: "<token-from-authentik-admin>"
vault_authentik_roman_password: "<initial-password>"
```

**How to obtain the API token:**
1. Log into Authentik admin UI as `akadmin`
2. Go to **Directory → Tokens and App passwords**
3. Click **Create**
4. Set **Identifier:** `ansible-automation`
5. Set **User:** `akadmin`
6. Set **Intent:** `API Token`
7. Click **Create**, then copy the token value
8. Store in vault

---

## 6. New Role — `authentik-config`

### 6.1 Architecture

This is an **API-based configuration role**, following the `pihole-dns` pattern:

- Runs against the `authentik` host via `delegate_to: localhost` (API calls from workstation)
- Uses `ansible.builtin.uri` module for all REST API calls
- Declarative for groups (creates missing ones)
- Idempotent: checks if resources exist before creating
- Supports `--check` mode with planned change reporting

### 6.2 Role Structure

```
roles/authentik-config/
├── defaults/main.yml         # Default variable values
├── tasks/
│   ├── main.yml              # Entry point — orchestrates all tasks
│   ├── brand.yml             # Configure brand domain
│   ├── provider.yml          # Create/update proxy provider
│   ├── application.yml       # Create/update application
│   ├── outpost.yml           # Bind application to embedded outpost
│   ├── groups.yml            # Create groups
│   └── users.yml             # Create users with group membership
└── README.md                 # Role documentation
```

### 6.3 API Endpoints Used

All endpoints are under `/api/v3/`. Authentication is via `Authorization: Bearer <token>` header.

| Task | Method | Endpoint | Notes |
|------|--------|----------|-------|
| List brands | GET | `/core/brands/` | Find default brand |
| Update brand | PATCH | `/core/brands/{id}/` | Set domain |
| List flows | GET | `/flows/instances/?designation=authorization&slug=...` | Get flow UUID for provider |
| Create proxy provider | POST | `/providers/proxy/` | Forward auth domain mode |
| List proxy providers | GET | `/providers/proxy/?search=...` | Check if exists |
| Create application | POST | `/core/applications/` | Links to provider |
| List applications | GET | `/core/applications/?search=...` | Check if exists |
| List outposts | GET | `/outposts/instances/` | Find embedded outpost |
| Update outpost | PATCH | `/outposts/instances/{id}/` | Add application to providers list |
| Create group | POST | `/core/groups/` | Simple name-only creation |
| List groups | GET | `/core/groups/?search=...` | Check if exists, get UUID |
| Create user | POST | `/core/users/` | With group UUIDs |
| List users | GET | `/core/users/?search=...` | Check if exists |
| Set password | POST | `/core/users/{id}/set_password/` | Set initial password |

### 6.4 Task Flow

```
main.yml
  ├── Validate required variables
  ├── brand.yml
  │   ├── GET /core/brands/ → find default brand
  │   └── PATCH /core/brands/{id}/ → set domain to auth.cogmai.com
  ├── groups.yml
  │   ├── GET /core/groups/ → list existing
  │   └── POST /core/groups/ → create missing (loop)
  ├── provider.yml
  │   ├── GET /providers/proxy/?search=colossus-forward-auth → check exists
  │   ├── GET /flows/instances/?slug=default-provider-authorization-implicit-consent → get flow UUID
  │   └── POST /providers/proxy/ → create if missing
  ├── application.yml
  │   ├── GET /core/applications/?search=colossus-services → check exists
  │   └── POST /core/applications/ → create if missing, link to provider
  ├── outpost.yml
  │   ├── GET /outposts/instances/ → find embedded outpost
  │   └── PATCH /outposts/instances/{id}/ → ensure application is in providers list
  └── users.yml
      ├── GET /core/groups/ → resolve group names to UUIDs
      ├── GET /core/users/?search=roman → check exists
      ├── POST /core/users/ → create if missing, with group UUIDs
      └── POST /core/users/{id}/set_password/ → set initial password (only on create)
```

### 6.5 Idempotency Model

| Resource | Create | Update | Delete |
|----------|--------|--------|--------|
| Brand | N/A (always exists) | PATCH domain if different | N/A |
| Groups | Create if name doesn't exist | N/A | No (preserve built-in groups) |
| Provider | Create if name doesn't exist | Skip (manual changes respected) | No |
| Application | Create if slug doesn't exist | Skip | No |
| Outpost | N/A (embedded always exists) | PATCH providers list if app missing | No |
| Users | Create if username doesn't exist | Update group membership | No |

### 6.6 defaults/main.yml

```yaml
---
# authentik-config role defaults
# Override in inventory/host_vars/authentik.yml

# ── API Connection ──────────────────────────────────────────
authentik_api_base: "http://10.10.100.58:9000/api/v3"
authentik_api_token: "{{ vault_authentik_api_token }}"

# ── Common API headers ──────────────────────────────────────
authentik_api_headers:
  Authorization: "Bearer {{ authentik_api_token }}"
  Content-Type: "application/json"
  Accept: "application/json"

# ── Brand ───────────────────────────────────────────────────
authentik_brand_domain: "auth.cogmai.com"

# ── Provider ────────────────────────────────────────────────
authentik_provider:
  name: "colossus-forward-auth"
  authorization_flow_slug: "default-provider-authorization-implicit-consent"
  mode: "forward_domain"
  external_host: "https://auth.cogmai.com"
  cookie_domain: "cogmai.com"
  access_token_validity: "hours=24"

# ── Application ─────────────────────────────────────────────
authentik_application:
  name: "Colossus Services"
  slug: "colossus-services"

# ── Groups ──────────────────────────────────────────────────
authentik_groups: []

# ── Users ───────────────────────────────────────────────────
authentik_users: []
```

---

## 7. Traefik Role Update — Auth Middleware Support

### 7.1 Problem

The current `traefik-route` role template (`services.yml.j2`) only defines the `redirect-to-https` middleware. The live `services.yml` has an `authelia` middleware that was hand-added outside Ansible. The template and data model must be extended to support authentication middleware.

### 7.2 Data Model Changes — `host_vars/traefik.yml`

Add auth configuration and `protected` flag to routes:

```yaml
# ── Authentication Middleware ──────────────────────────────
# ForwardAuth middleware for Authentik. When enabled, protected
# routes require authentication before Traefik forwards to backend.
traefik_auth:
  enabled: true
  name: "authentik"
  address: "http://10.10.100.58:9000/outpost.goauthentik.io/auth/traefik"
  response_headers:
    - "X-authentik-username"
    - "X-authentik-groups"
    - "X-authentik-entitlements"
    - "X-authentik-email"
    - "X-authentik-name"
    - "X-authentik-uid"
    - "X-authentik-jwt"
    - "X-authentik-meta-jwks"
    - "X-authentik-meta-outpost"
    - "X-authentik-meta-provider"
    - "X-authentik-meta-app"
    - "X-authentik-meta-version"

# ── Authentik Portal Route ─────────────────────────────────
# The auth portal itself and the outpost callback path.
# These are special routes handled by the template separately.
traefik_auth_portal:
  host: "auth.{{ domain }}"
  backend_url: "http://10.10.100.58:9000"

traefik_routes:
  # ── Colossus-Legal PROD ──────────────────────────────────
  - name: colossus-legal-frontend
    host: "colossus-legal.{{ domain }}"
    backend_url: "http://10.10.100.120:5473"
    external: true
    protected: true

  - name: colossus-legal-api
    host: "colossus-legal-api.{{ domain }}"
    backend_url: "http://10.10.100.120:3403"
    external: true
    protected: false           # API uses its own auth (JWT)

  # ── Colossus-Legal DEV ───────────────────────────────────
  - name: colossus-legal-dev
    host: "colossus-legal-dev.{{ domain }}"
    backend_url: "http://10.10.100.220:5473"
    external: false
    protected: true

  - name: colossus-legal-api-dev
    host: "colossus-legal-api-dev.{{ domain }}"
    backend_url: "http://10.10.100.220:3403"
    external: false
    protected: false

  # ── Infrastructure ───────────────────────────────────────
  - name: traefik-dashboard
    host: "traefik.{{ domain }}"
    service: "api@internal"
    external: false
    protected: true

  - name: semaphore
    host: "semaphore.{{ domain }}"
    backend_url: "http://10.10.100.57:3000"
    external: false
    protected: true

  - name: grafana
    host: "grafana.{{ domain }}"
    backend_url: "http://10.10.100.56:3000"
    external: false
    protected: true
```

### 7.3 Template Changes — `services.yml.j2`

The template needs three additions:

1. **Authentik ForwardAuth middleware** — conditional on `traefik_auth.enabled`
2. **Authentik portal routes** — HTTP + HTTPS routers for `auth.cogmai.com`
3. **Outpost callback routes** — `PathPrefix(/outpost.goauthentik.io/)` at priority 15
4. **Protected flag on routes** — add middleware reference when `route.protected` is true

Key template sections (pseudocode):

```jinja2
  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true
{% if traefik_auth is defined and traefik_auth.enabled | default(false) %}

    {{ traefik_auth.name }}:
      forwardAuth:
        address: "{{ traefik_auth.address }}"
        trustForwardHeader: true
        authResponseHeaders:
{% for header in traefik_auth.response_headers %}
          - "{{ header }}"
{% endfor %}
{% endif %}

  routers:
{% if traefik_auth_portal is defined %}
    # --- Authentik outpost callback (priority 15) ---
    authentik-outpost-http:
      rule: "PathPrefix(`/outpost.goauthentik.io/`)"
      entryPoints:
        - http
      service: authentik-portal
      priority: 15

    authentik-outpost:
      rule: "PathPrefix(`/outpost.goauthentik.io/`)"
      entryPoints:
        - https
      service: authentik-portal
      priority: 15
      tls: ...

    # --- Authentik portal ---
    authentik-portal-http:
      rule: "Host(`{{ traefik_auth_portal.host }}`)"
      entryPoints:
        - http
      service: authentik-portal
      priority: 10

    authentik-portal:
      rule: "Host(`{{ traefik_auth_portal.host }}`)"
      entryPoints:
        - https
      service: authentik-portal
      tls: ...
{% endif %}

    # --- Application routes ---
{% for route in traefik_routes %}
    {{ route.name }}:
      rule: "Host(`{{ route.host }}`)"
      entryPoints:
        - https
{% if route.protected | default(false) and traefik_auth.enabled | default(false) %}
      middlewares:
        - {{ traefik_auth.name }}
{% endif %}
      service: {{ route.service | default(route.name) }}
      tls: ...
{% endfor %}
```

### 7.4 defaults/main.yml Update

Add to `roles/traefik-route/defaults/main.yml`:

```yaml
# ── Authentication middleware (optional) ────────────────────
# When defined and enabled, routes with protected: true will
# require authentication via ForwardAuth before Traefik forwards
# to the backend. Set traefik_auth.enabled: false to bypass
# auth globally (emergency override).
traefik_auth: {}
traefik_auth_portal: {}
```

---

## 8. Pi-hole DNS Verification

The task tracker shows `auth.cogmai.com → 10.10.100.55` was created during Authelia Stage 3. However, checking `host_vars/pihole.yml`, this record is **NOT present** in the Ansible-managed list. It was likely added manually via Pi-hole UI.

**Required addition** to `inventory/host_vars/pihole.yml`:

```yaml
  # ── Authentication ────────────────────────────────────────
  - "10.10.100.55 auth.cogmai.com"
```

Note: This points to Traefik (10.10.100.55), not directly to Authentik (10.10.100.58). Traefik handles TLS termination and forwards to Authentik.

---

## 9. Playbooks

### 9.1 New — `playbooks/configure-authentik.yml`

```yaml
---
# configure-authentik.yml — Configure Authentik via REST API
#
# Creates/updates all Authentik resources: brand, provider, application,
# outpost binding, groups, and users. Declarative and idempotent.
#
# Prerequisites:
#   - VM-316 running with Authentik containers healthy
#   - akadmin initial setup completed
#   - API token created and stored in vault
#
# Usage:
#   ansible-playbook playbooks/configure-authentik.yml --check   # dry-run
#   ansible-playbook playbooks/configure-authentik.yml            # execute

- name: "Configure Authentik identity provider"
  hosts: authentik
  gather_facts: false
  connection: local
  roles:
    - authentik-config
```

Note: `connection: local` because all API calls are HTTP from the workstation to VM-316. No SSH into the CoreOS VM needed.

### 9.2 Execution Order

After a fresh VM-316 rebuild, the complete sequence is:

```bash
# 1. Provisioning (colossus-homelab scripts on pve-3)
cd ~/Projects/colossus-homelab/authentik/
bash ./01-create-zfs-datasets.sh
bash ./02-create-directory-mappings.sh
bash ./03-create-vm.sh

# 2. Wait for boot (~3-4 min), then verify
ssh core@10.10.100.58 "sudo podman ps"

# 3. Complete initial setup wizard in browser
#    http://10.10.100.58:9000/if/flow/initial-setup/
#    Create akadmin account, create API token, store in vault

# 4. Configure Authentik via Ansible
cd ~/Projects/colossus-ansible/
ansible-playbook playbooks/configure-authentik.yml

# 5. Update DNS (if not already present)
ansible-playbook playbooks/manage-pihole.yml

# 6. Update Traefik routes (switches traffic to Authentik)
ansible-playbook playbooks/manage-traefik.yml
```

Step 3 (initial setup wizard + API token creation) is the **only manual step**. Everything else is automated.

---

## 10. Implementation Checklist

Execute in this order:

| # | Task | Files affected | Type |
|---|------|---------------|------|
| 1 | Fix Butane config | `colossus-homelab/authentik/authentik.bu` | Fix |
| 2 | Create provisioning recipe | `colossus-ansible/vars/vm-316-authentik.yml` | New file |
| 3 | Add VM-316 to inventory | `colossus-ansible/inventory/hosts.yml` | Edit |
| 4 | Create host_vars for authentik | `colossus-ansible/inventory/host_vars/authentik.yml` | New file |
| 5 | Add secrets to vault | `colossus-ansible/inventory/group_vars/*/vault.yml` | Edit |
| 6 | Create `authentik-config` role | `colossus-ansible/roles/authentik-config/` | New role (7 files) |
| 7 | Update `traefik-route` template | `colossus-ansible/roles/traefik-route/templates/services.yml.j2` | Edit |
| 8 | Update `traefik-route` defaults | `colossus-ansible/roles/traefik-route/defaults/main.yml` | Edit |
| 9 | Update traefik host_vars | `colossus-ansible/inventory/host_vars/traefik.yml` | Edit |
| 10 | Update pihole host_vars | `colossus-ansible/inventory/host_vars/pihole.yml` | Edit |
| 11 | Create configure-authentik playbook | `colossus-ansible/playbooks/configure-authentik.yml` | New file |
| 12 | Test: `configure-authentik.yml --check` | — | Validation |
| 13 | Test: `manage-pihole.yml --check --diff` | — | Validation |
| 14 | Test: `manage-traefik.yml --check --diff` | — | Validation |
| 15 | Execute all three playbooks | — | Execution |
| 16 | End-to-end test: access `https://colossus-legal.cogmai.com` | — | Validation |

---

## 11. Rollback Procedure

If Authentik fails after traffic switchover:

1. **Disable auth globally:** Edit `host_vars/traefik.yml`, set `traefik_auth.enabled: false`
2. **Re-run Traefik playbook:** `ansible-playbook playbooks/manage-traefik.yml`
3. Services are now accessible without authentication (emergency state)
4. Debug Authentik, then re-enable

This is the same emergency bypass pattern used with Authelia (`traefik_authelia.enabled`).

---

## 12. Future Considerations

- **Backup strategy:** VM-316 PostgreSQL data on ZFS — add to PBS backup jobs via `pbs-backup` role
- **Monitoring:** Add Grafana Alloy agent to VM-316 for container metrics/logs
- **Password rotation:** Initial passwords set by Ansible are temporary; users change on first login via Authentik's default flow
- **Additional applications:** As colossus-ai and colossus-observe come online, add them as separate applications with per-app access policies (advantage of Authentik over Authelia)
