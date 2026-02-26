# Colossus — Authelia Authentication Gateway Design

**Version:** v1.0
**Date:** 2026-02-26
**Status:** Design — ready for execution
**Depends on:** Traefik (CT-313), Pi-hole (CT-311), colossus-legal backend

---

## 1. Purpose

Deploy Authelia as a centralized authentication gateway for all Colossus web services. Authelia integrates with Traefik's ForwardAuth middleware to intercept requests, authenticate users, and inject identity headers that downstream applications can trust.

**Goals:**
- Single sign-on across all `*.cogmai.com` services
- User identity passed to backends via trusted HTTP headers
- Group-based access control (admin, legal_editor, legal_viewer, ai_user)
- Optional 2FA (TOTP) for external access
- Minimal footprint (~30MB RAM, single binary)
- All persistent data externalized to ZFS (golden rule compliance)

**Non-goals:**
- LDAP/Active Directory integration (overkill for 5-10 users)
- OIDC/SAML provider (not needed without external IdP)
- Redis session store (SQLite sufficient for single-instance)

---

## 2. Architecture

### 2.1 Request Flow

```
Browser → Traefik (CT-313)
              │
              ├─ ForwardAuth middleware → Authelia (CT-316): "Authenticated?"
              │       │
              │       ├─ NO → 302 redirect to https://auth.cogmai.com
              │       │        → User logs in (username/password + optional TOTP)
              │       │        → Authelia sets session cookie (domain: cogmai.com)
              │       │        → 302 redirect back to original URL
              │       │
              │       └─ YES → 200 + headers:
              │                  Remote-User: roman
              │                  Remote-Email: roman@cogmai.com
              │                  Remote-Groups: admin,legal_editor
              │                  Remote-Name: Roman
              │
              └─ Traefik forwards request + auth headers → Backend (VM-120/220)
                        │
                        └─ Axum reads Remote-User/Remote-Groups headers
                           → Applies authorization logic per endpoint
```

### 2.2 Component Placement

```
pve-3 (Infrastructure)
├── CT-311  Pi-hole      → auth.cogmai.com → 10.10.100.55
├── CT-312  cloudflared  → Tunnel routes include auth.cogmai.com
├── CT-313  Traefik      → ForwardAuth middleware → CT-316:9091
├── CT-315  Semaphore
├── CT-316  Authelia      ← NEW (10.10.100.58)
├── VM-314  Monitoring
└── VM-900  PBS
```

### 2.3 Network Position

Authelia sits **behind Traefik**, not in front of it. Traefik handles TLS termination and routing. Authelia only sees internal HTTP traffic from Traefik on port 9091.

```
External: Browser → Cloudflare → CT-312 → CT-313 (Traefik :80) → CT-316 (Authelia :9091)
Internal: Browser → Pi-hole DNS → CT-313 (Traefik :443) → CT-316 (Authelia :9091)
```

---

## 3. Container Specification

| Property | Value |
|----------|-------|
| CTID | 316 |
| Hostname | authelia |
| Node | pve-3 |
| IP | 10.10.100.58/24 |
| Gateway | 10.10.100.1 |
| DNS | 10.10.100.53 |
| OS | Debian 12 (minimal) |
| Cores | 1 |
| Memory | 256MB |
| Swap | 256MB |
| Disk | 4GB rootfs (local-lvm) |
| Service port | 9091 (HTTP, internal only) |

### 3.1 External Storage (Golden Rule)

All persistent data lives on ZFS datasets, bind-mounted into the container:

| ZFS Dataset | Host Mountpoint | Container Mount | Contents |
|-------------|----------------|-----------------|----------|
| `pbs-zfs/services/authelia/data` | `/pbs-zfs/services/authelia/data` | `/mnt/data` | SQLite DB, notification state |
| `pbs-zfs/services/authelia/config` | `/pbs-zfs/services/authelia/config` | `/mnt/config` | configuration.yml, users_database.yml, secrets |

**Rationale:** Container is disposable. Destroy CT-316 and recreate — configuration and user sessions survive on ZFS. Same pattern as CT-315 (Semaphore).

### 3.2 LXC Bind Mounts

```
mp0: /pbs-zfs/services/authelia/data,mp=/mnt/data
mp1: /pbs-zfs/services/authelia/config,mp=/mnt/config
```

---

## 4. Authelia Configuration

### 4.1 Installation Method

Authelia provides an official APT repository for Debian. This is the preferred method (matches Colossus LXC pattern — native services, no Docker):

```bash
apt install ca-certificates curl gnupg
curl -fsSL https://www.authelia.com/keys/authelia-security.gpg \
  -o /usr/share/keyrings/authelia-security.gpg
echo "deb [signed-by=/usr/share/keyrings/authelia-security.gpg] \
  https://apt.authelia.com/stable/debian/debian/ debian main" \
  > /etc/apt/sources.list.d/authelia.list
apt update && apt install authelia
```

Current version: **4.39.0** (as of 2026-02-26)

### 4.2 Configuration File: `/mnt/config/configuration.yml`

```yaml
---
theme: dark
default_2fa_method: totp

server:
  address: 'tcp://0.0.0.0:9091/'

log:
  level: info
  file_path: /mnt/data/authelia.log

totp:
  issuer: cogmai.com
  period: 30
  skew: 1

authentication_backend:
  file:
    path: /mnt/config/users_database.yml
    password:
      algorithm: argon2id
      iterations: 3
      memory: 65536
      parallelism: 4
      key_length: 32
      salt_length: 16

session:
  cookies:
    - domain: 'cogmai.com'
      authelia_url: 'https://auth.cogmai.com'
      default_redirection_url: 'https://colossus-legal.cogmai.com'
      expiration: 12h
      inactivity: 1h
      remember_me: 1M

storage:
  local:
    path: /mnt/data/db.sqlite3

notifier:
  filesystem:
    filename: /mnt/data/notification.txt

access_control:
  default_policy: deny

  rules:
    # Authelia portal itself — must be bypass
    - domain: 'auth.cogmai.com'
      policy: bypass

    # Colossus-Legal health/status endpoints — no auth (for monitoring)
    - domain:
        - 'colossus-legal-api.cogmai.com'
        - 'colossus-legal-api-dev.cogmai.com'
      resources:
        - '^/health$'
        - '^/api/status$'
      policy: bypass

    # Admin-only services
    - domain:
        - 'semaphore.cogmai.com'
        - 'grafana.cogmai.com'
        - 'traefik.cogmai.com'
      subject:
        - 'group:admin'
      policy: one_factor

    # Colossus-Legal — all authenticated users
    - domain:
        - 'colossus-legal.cogmai.com'
        - 'colossus-legal-api.cogmai.com'
      subject:
        - 'group:admin'
        - 'group:legal_editor'
        - 'group:legal_viewer'
      policy: one_factor

    # DEV environment — admin only
    - domain:
        - 'colossus-legal-dev.cogmai.com'
        - 'colossus-legal-api-dev.cogmai.com'
      subject:
        - 'group:admin'
      policy: one_factor

    # Future: colossus-ai
    - domain:
        - 'colossus-ai.cogmai.com'
        - 'colossus-ai-api.cogmai.com'
      subject:
        - 'group:admin'
        - 'group:ai_user'
      policy: one_factor
```

**Key design decisions:**
- `default_policy: deny` — everything blocked unless explicitly allowed
- Health/status endpoints use `bypass` so Prometheus/Alloy monitoring continues working
- `filesystem` notifier for development (no email server needed); upgrade to SMTP later if desired
- Session cookie scoped to `cogmai.com` domain — SSO across all subdomains
- DEV environment restricted to admin only

### 4.3 Users Database: `/mnt/config/users_database.yml`

```yaml
---
users:
  roman:
    disabled: false
    displayname: "Roman"
    email: roman@cogmai.com
    groups:
      - admin
      - legal_editor
      - ai_user
    password: "$argon2id$..."   # Generated with: authelia crypto hash generate argon2
```

Passwords are hashed with Argon2id. Generate with:
```bash
authelia crypto hash generate argon2 --password 'YOUR_PASSWORD'
```

### 4.4 Secrets

Authelia requires several secrets for JWT, session encryption, and storage encryption. These should be generated as random strings and stored in files on the config mount:

```
/mnt/config/secrets/
├── jwt_secret                  # JWT signing key
├── session_secret              # Session cookie encryption
└── storage_encryption_key      # SQLite encryption key
```

Referenced in `configuration.yml` via environment variables:
```yaml
identity_validation:
  reset_password:
    jwt_secret: {{ secret "/mnt/config/secrets/jwt_secret" }}
```

Or via `AUTHELIA_*_FILE` environment variables in the systemd unit.

---

## 5. Traefik Integration

### 5.1 ForwardAuth Middleware

Add to CT-313 `/etc/traefik/dynamic/services.yml`:

```yaml
http:
  middlewares:
    authelia:
      forwardAuth:
        address: "http://10.10.100.58:9091/api/authz/forward-auth"
        trustForwardHeader: true
        authResponseHeaders:
          - "Remote-User"
          - "Remote-Groups"
          - "Remote-Email"
          - "Remote-Name"
```

### 5.2 Apply to Protected Routers

Add `authelia` middleware to existing routers in `services.yml`:

```yaml
  routers:
    colossus-legal-frontend:
      rule: "Host(`colossus-legal.cogmai.com`)"
      entryPoints: "https"
      middlewares:
        - authelia
      service: colossus-legal-frontend
      tls: {}

    colossus-legal-api:
      rule: "Host(`colossus-legal-api.cogmai.com`)"
      entryPoints: "https"
      middlewares:
        - authelia
      service: colossus-legal-api
      tls: {}
```

### 5.3 Authelia Portal Router

Add a new router for the authentication portal itself:

```yaml
    authelia-portal:
      rule: "Host(`auth.cogmai.com`)"
      entryPoints: "https"
      service: authelia-portal
      tls: {}

    # HTTP router for tunnel traffic (no redirect loop)
    authelia-portal-http:
      rule: "Host(`auth.cogmai.com`)"
      entryPoints: "http"
      service: authelia-portal
      priority: 10

  services:
    authelia-portal:
      loadBalancer:
        servers:
          - url: "http://10.10.100.58:9091"
```

### 5.4 Cloudflare Tunnel Update

Add `auth.cogmai.com` route to the Cloudflare Tunnel (CT-312) pointing to Traefik:
- `auth.cogmai.com` → `http://10.10.100.55:80`

### 5.5 Pi-hole DNS

Add DNS record:
- `auth.cogmai.com` → `10.10.100.55` (Traefik, same as all other services)

### 5.6 Tunnel Traffic Considerations

Cloudflare Tunnel sends HTTP to Traefik port 80. The ForwardAuth middleware must work over HTTP for tunnel traffic. Authelia's session cookie needs `Secure` flag handling:

- Internal (HTTPS via Traefik): Cookie is Secure, works normally
- External (HTTP via tunnel → Traefik): Cloudflare handles TLS at the edge, so the browser sees HTTPS and accepts Secure cookies

This matches the existing pattern — no special handling needed beyond what's already configured for Cloudflare Tunnel routes.

---

## 6. Application Integration Contract

This section defines the complete contract between Authelia (identity provider) and colossus-legal (application). It is sufficient for implementing the Rust backend and React frontend without further design input.

### 6.1 Header Contract

Traefik injects these headers on every request to a protected service. The backend **must not** trust these headers from any other source.

| Header | Type | Example | Present When |
|--------|------|---------|-------------|
| `Remote-User` | String | `roman` | Always (if authenticated) |
| `Remote-Email` | String | `roman@cogmai.com` | Always |
| `Remote-Groups` | Comma-separated | `admin,legal_editor` | Always (may be empty) |
| `Remote-Name` | String | `Roman` | Always |

**When headers are absent:** If `Remote-User` is missing, the request either bypassed Authelia (health endpoints) or something is misconfigured. The backend must handle both cases.

### 6.2 Authentication Modes

The backend must support three operating modes:

| Mode | When | `Remote-User` Present? | Behavior |
|------|------|----------------------|----------|
| **Authenticated** | Normal operation behind Authelia | Yes | Extract user, enforce permissions |
| **Bypass** | Health/status endpoints configured as bypass in Authelia | No | Allow request, no user context |
| **Development** | Local dev without Authelia running | No | Configurable: reject or use mock user |

**Development mode** is controlled by an environment variable:

```
AUTH_MODE=required       # Production: reject requests without Remote-User (default)
AUTH_MODE=optional       # Development: allow requests, use "anonymous" if no header
```

This avoids the need to run Authelia locally during development. The Ansible-managed environment files set `AUTH_MODE=required` in both DEV and PROD.

### 6.3 Groups and Permissions

#### 6.3.1 Group Definitions

| Group | Purpose | Assigned To |
|-------|---------|-------------|
| `admin` | Full access to everything | Roman (primary operator) |
| `legal_editor` | Read + write on colossus-legal data | Case team members |
| `legal_viewer` | Read-only on colossus-legal data | Observers, reviewers |
| `ai_user` | Access to AI features (ask, search, embed) | Users with AI access |

Groups are additive. A user can belong to multiple groups. `admin` implicitly includes all permissions.

#### 6.3.2 Permission Helpers

| Method | Logic | Used For |
|--------|-------|----------|
| `is_admin()` | `groups.contains("admin")` | Admin-only endpoints |
| `can_read()` | `is_admin() OR in(legal_editor, legal_viewer)` | All GET endpoints |
| `can_edit()` | `is_admin() OR in(legal_editor)` | POST, PUT, DELETE endpoints |
| `can_use_ai()` | `is_admin() OR in(ai_user)` | AI-powered endpoints |

### 6.4 Endpoint Authorization Map

Complete mapping of every current colossus-legal endpoint to its required permission:

#### 6.4.1 No Auth Required (Authelia bypass)

These endpoints are configured as `bypass` in Authelia's access_control rules. No headers are injected. The backend must serve them without an `AuthUser`.

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health` | Health check (monitoring) |
| GET | `/api/status` | Status check (monitoring) |

#### 6.4.2 Read Endpoints — `can_read()`

Any authenticated user with `admin`, `legal_editor`, or `legal_viewer` group. `AuthUser` is present and logged for audit.

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/analysis` | Get case analysis |
| GET | `/case` | Get case overview |
| GET | `/case-summary` | Get case summary |
| GET | `/claims` | List all claims |
| GET | `/claims/:id` | Get single claim |
| GET | `/documents` | List all documents |
| GET | `/documents/:id` | Get single document metadata |
| GET | `/documents/:id/file` | Serve PDF file |
| GET | `/schema` | Get graph schema |
| GET | `/persons` | List persons |
| GET | `/persons/:id/detail` | Get person detail |
| GET | `/allegations` | List allegations |
| GET | `/allegations/:id/evidence-chain` | Get evidence chain |
| GET | `/evidence` | List evidence |
| GET | `/harms` | List harms |
| GET | `/motion-claims` | List motion claims |
| GET | `/contradictions` | List contradictions |
| GET | `/graph/legal-proof` | Get legal proof graph |
| GET | `/decomposition` | List decomposition |
| GET | `/allegations/:id/detail` | Get allegation detail |
| GET | `/rebuttals` | List rebuttals |
| GET | `/queries` | List saved queries |
| GET | `/queries/:id/run` | Execute saved query |

#### 6.4.3 Write Endpoints — `can_edit()`

Requires `admin` or `legal_editor` group. Returns 403 Forbidden for `legal_viewer`.

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/claims` | Create claim |
| PUT | `/claims/:id` | Update claim |
| POST | `/documents` | Create document |
| PUT | `/documents/:id` | Update document |
| POST | `/import/validate` | Validate import data |

#### 6.4.4 AI Endpoints — `can_use_ai()`

Requires `admin` or `ai_user` group. These invoke LLM calls or vector search operations.

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/search` | Semantic search (Qdrant) |
| POST | `/ask` | Ask the case (LLM-powered Q&A) |

#### 6.4.5 Admin Endpoints — `is_admin()`

Requires `admin` group only. These are expensive or destructive operations.

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/admin/embed-all` | Re-embed all documents (expensive) |

#### 6.4.6 User Info Endpoint — NEW

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/api/me` | Any authenticated user | Returns current user's identity and groups |

Response:
```json
{
  "username": "roman",
  "email": "roman@cogmai.com",
  "display_name": "Roman",
  "groups": ["admin", "legal_editor", "ai_user"],
  "permissions": {
    "can_read": true,
    "can_edit": true,
    "can_use_ai": true,
    "is_admin": true
  }
}
```

### 6.5 Error Responses

#### 6.5.1 HTTP Status Codes

| Scenario | Status | Body |
|----------|--------|------|
| No `Remote-User` header (AUTH_MODE=required) | 401 Unauthorized | `{"error": "authentication_required", "message": "No authenticated user"}` |
| User lacks required group | 403 Forbidden | `{"error": "insufficient_permissions", "message": "Requires legal_editor or admin group", "user": "jane", "groups": ["legal_viewer"]}` |
| Valid auth, normal response | 200/201/etc | Normal response body |

#### 6.5.2 Error Response Structure

```rust
#[derive(Serialize)]
pub struct AuthError {
    pub error: String,          // Machine-readable: "authentication_required" or "insufficient_permissions"
    pub message: String,        // Human-readable explanation
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,   // Present on 403 (user is known but lacks permission)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub groups: Option<Vec<String>>,  // Present on 403
}
```

### 6.6 Audit Logging

Every authenticated request should be logged at INFO level with the username:

```
2026-02-26T15:30:00Z  INFO  roman GET /documents 200 (12ms)
2026-02-26T15:30:05Z  INFO  roman POST /documents 201 (45ms)
2026-02-26T15:30:10Z  INFO  jane GET /documents 200 (8ms)
2026-02-26T15:30:15Z  WARN  jane POST /documents 403 FORBIDDEN (requires legal_editor)
```

All 403 responses should be logged at WARN level with the user, endpoint, and required permission.

### 6.7 Frontend Integration

#### 6.7.1 Auth Context

On app load, the frontend calls `GET /api/me` to determine the current user and their permissions. This response drives all UI decisions.

```typescript
interface AuthUser {
  username: string;
  email: string;
  display_name: string;
  groups: string[];
  permissions: {
    can_read: boolean;
    can_edit: boolean;
    can_use_ai: boolean;
    is_admin: boolean;
  };
}
```

#### 6.7.2 UI Behavior by Permission

| UI Element | `can_read` | `can_edit` | `can_use_ai` | `is_admin` |
|-----------|-----------|-----------|-------------|-----------|
| View documents, claims, etc. | ✅ | ✅ | — | ✅ |
| "Create Document" button | Hidden | Visible | — | Visible |
| "Edit" buttons on detail pages | Hidden | Visible | — | Visible |
| "Ask the Case" feature | Hidden | Hidden | Visible | Visible |
| "Semantic Search" feature | Hidden | Hidden | Visible | Visible |
| "Re-embed All" admin button | Hidden | Hidden | Hidden | Visible |
| User display in header | Username shown | Username shown | Username shown | Username + "Admin" badge |

#### 6.7.3 Handling 403 Responses

If the frontend receives a 403, display a toast/notification: "You don't have permission to perform this action." Do NOT redirect to login — the user IS authenticated, they just lack the required group.

#### 6.7.4 Logout

Authelia provides a logout endpoint. The frontend logout button navigates to:

```
https://auth.cogmai.com/logout
```

This clears the Authelia session cookie and redirects to the login page.

### 6.8 Security Considerations

#### 6.8.1 Header Forgery Prevention

The `Remote-User`, `Remote-Groups`, etc. headers can only be set by Traefik's ForwardAuth middleware. Traefik strips any incoming `Remote-*` headers from the client before the ForwardAuth check. A malicious client cannot forge these headers.

However, if the backend is accessed directly (bypassing Traefik), there is no protection. This is acceptable because:
- Backend ports (3403) are not exposed externally
- Only Traefik routes to the backend
- LAN access to port 3403 directly is an accepted risk for a homelab

#### 6.8.2 Frontend Authorization is Cosmetic

The frontend hides UI elements based on permissions, but this is **cosmetic only**. The backend MUST enforce permissions independently. A determined user could call the API directly. The frontend just provides a clean UX.

#### 6.8.3 Development Mode Safety

`AUTH_MODE=optional` should NEVER be set in DEV or PROD environment files. It exists only for local development on the workstation. The Ansible vault-managed environment files always set `AUTH_MODE=required`.

### 6.9 Graceful Degradation

If Authelia is down, Traefik's ForwardAuth will fail closed — returning 502 Bad Gateway rather than allowing unauthenticated access. This is the correct default for security.

To restore access during an Authelia outage, use the emergency bypass procedure documented in Section 12.4.6.

---

## 7. Storage Layout

### 7.1 ZFS Datasets

```bash
# On pve-3
zfs create pbs-zfs/services/authelia
zfs create pbs-zfs/services/authelia/data       # SQLite DB, logs, notifications
zfs create pbs-zfs/services/authelia/config      # configuration.yml, users, secrets
```

### 7.2 Ownership

Unprivileged LXC container — UID mapping applies:

| Inside CT | Host UID | Purpose |
|-----------|----------|---------|
| authelia (UID TBD) | 100000 + UID | Authelia process owner |

Set ownership from pve-3 host after dataset creation, same pattern as CT-315.

---

## 8. Infrastructure Integration

### 8.1 Monitoring

- Alloy agent deployed on CT-316 (same pattern as all LXCs)
- Authelia exposes metrics at `http://localhost:9091/metrics` (Prometheus format)
- Add scrape target to Prometheus config on VM-314

### 8.2 PBS Backup

- Add `backup-authelia` job: VMID 316, daily, pbs-1, zstd, snapshot mode

### 8.3 Ansible

- Create `roles/authelia/` in colossus-ansible
- Manage configuration.yml, users_database.yml, secrets via Ansible Vault
- Semaphore template for Authelia deployment/updates

---

## 9. Key Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Authelia over Authentik | Single binary, ~30MB RAM vs multi-container ~2GB. Right-sized for 5-10 users |
| 2 | APT install, not Docker | Matches Colossus LXC pattern (CT-311/312/313/315 all use native services) |
| 3 | SQLite, not PostgreSQL | No external dependency, single-file DB on ZFS, survives rebuild |
| 4 | File-based user backend | YAML file for 5-10 users, no LDAP overhead, managed via Ansible Vault |
| 5 | Filesystem notifier | No SMTP server needed for 2FA registration; upgrade later if desired |
| 6 | Session cookie on cogmai.com | SSO across all subdomains — one login for legal, ai, grafana, etc. |
| 7 | Default deny policy | Explicit allowlists per service; new services are blocked until configured |
| 8 | Health endpoints bypass auth | Prometheus, Alloy, and uptime checks must work without authentication |
| 9 | Externalize all data to ZFS | Golden rule: container is disposable, data survives rebuild |
| 10 | CT-316 on pve-3 | All infrastructure services live on pve-3; consistent with CT-311–315 |

---

## 10. Interaction with Existing Cloudflare Access

You currently have a "Allow Roman" Cloudflare Access policy on `*.cogmai.com`. With Authelia in place:

**Option A: Keep both (defense in depth)**
- Cloudflare Access protects external access (email OTP at the edge)
- Authelia protects both internal and external access (username/password + TOTP)
- Two authentication layers for external users; one for LAN users

**Option B: Remove Cloudflare Access, rely on Authelia**
- Simpler user experience (one login, not two)
- Authelia alone handles both LAN and external authentication
- Cloudflare Tunnel still provides the transport layer

**Recommendation:** Start with Option A during deployment/testing. Once Authelia is proven stable, evaluate switching to Option B for cleaner UX.

---

## 11. Security Considerations

- Authelia listens on HTTP (:9091) — only accessible from Traefik on the internal network
- Session cookies are `Secure`, `HttpOnly`, `SameSite=Lax`
- Brute-force protection: Authelia locks accounts after configurable failed attempts
- Secrets stored as files on ZFS mount, not in configuration.yml
- User passwords hashed with Argon2id (memory-hard, GPU-resistant)
- `trustForwardHeader: true` is safe because Traefik is the only entity that can reach Authelia:9091

---

## 12. Resilience & Recovery

### 12.1 Dependency Chain

Authentication requires all five links in this chain to be healthy:

```
Browser → Pi-hole (CT-311) → Traefik (CT-313) → Authelia (CT-316) → App (VM-120/220)
                                                       ↑
                                              NEW single point of failure
```

For external access, Cloudflare Tunnel (CT-312) is also in the chain between browser and Traefik.

### 12.2 Failure Mode Analysis

| Component | Failure Symptom | User Sees | LAN Impact | External Impact | Auth-Specific? |
|-----------|----------------|-----------|------------|-----------------|----------------|
| Pi-hole (CT-311) | DNS resolution fails | ERR_NAME_NOT_RESOLVED | All services down | No impact (Cloudflare DNS) | No |
| Cloudflare Tunnel (CT-312) | Tunnel disconnects | Cloudflare 502 error | No impact | External access down | No |
| Traefik (CT-313) | Port 80/443 refuses | Connection refused | All services down | All services down | No |
| **Authelia (CT-316)** | **ForwardAuth returns 502** | **Traefik 502 Bad Gateway** | **All protected services down** | **All protected services down** | **YES** |
| Authelia config corrupt | Authelia won't start | Same as above | Same as above | Same as above | YES |
| Authelia SQLite locked | Sessions fail | Login loops / 500 errors | Auth broken | Auth broken | YES |
| App backend (VM-120/220) | App errors after auth | Application errors | App down, auth works | App down, auth works | No |

**Key risk:** Authelia is the only new single point of failure introduced by this design. All other components in the chain are existing dependencies that would already cause outages if they failed.

### 12.3 Diagnostic Runbook

When users report "I can't access colossus-legal", walk the chain from bottom to top:

```bash
# Step 1: Is the app itself healthy? (bypasses auth entirely)
ssh core@10.10.100.120 "curl -s http://localhost:3403/health"
# Expected: OK

# Step 2: Is Authelia healthy?
ssh root@10.10.100.58 "curl -s http://localhost:9091/api/health"
# Expected: {"status":"OK"}

# Step 3: Can Traefik reach Authelia? (from Traefik's perspective)
ssh root@10.10.100.55 "curl -s http://10.10.100.58:9091/api/health"
# Expected: {"status":"OK"}

# Step 4: Is Traefik itself healthy?
curl -s http://10.10.100.55:8080/api/overview
# Expected: JSON with routers/services/middlewares counts

# Step 5: Is DNS resolving?
dig auth.cogmai.com @10.10.100.53
dig colossus-legal.cogmai.com @10.10.100.53
# Expected: Both return 10.10.100.55

# Step 6: Check Authelia logs for errors
ssh root@10.10.100.58 "tail -50 /mnt/data/authelia.log"

# Step 7: Check Authelia systemd status
ssh root@10.10.100.58 "systemctl status authelia"
```

### 12.4 Recovery Procedures

#### 13.4.1 Authelia Process Crashed

**Symptom:** `systemctl status authelia` shows failed/inactive.
**Impact:** All protected services return 502.
**Recovery time:** ~10 seconds.

```bash
ssh root@10.10.100.58 "systemctl restart authelia"
ssh root@10.10.100.58 "curl -s http://localhost:9091/api/health"
```

**User impact:** Active sessions preserved in SQLite — users do NOT need to re-login.

#### 13.4.2 Authelia Container Down (CT-316 stopped/crashed)

**Symptom:** `pct status 316` shows stopped.
**Impact:** All protected services return 502.
**Recovery time:** ~30 seconds.

```bash
ssh root@10.10.100.5 "pct start 316"
# Wait 10s for boot
ssh root@10.10.100.58 "curl -s http://localhost:9091/api/health"
```

**User impact:** Active sessions preserved — users do NOT need to re-login.

#### 13.4.3 Authelia Configuration Corrupt

**Symptom:** Authelia won't start, logs show YAML parse errors.
**Impact:** All protected services return 502.
**Recovery time:** ~5 minutes.

```bash
# Option A: Fix config manually
ssh root@10.10.100.58 "cat /mnt/data/authelia.log | tail -20"
# Fix the issue in /mnt/config/configuration.yml
ssh root@10.10.100.58 "systemctl restart authelia"

# Option B: Redeploy config via Ansible
cd ~/Projects/colossus-ansible
ansible-playbook playbooks/deploy-authelia.yml --vault-password-file ~/.vault_pass
```

#### 13.4.4 Authelia SQLite Corrupt

**Symptom:** Login loops, 500 errors, SQLite errors in logs.
**Impact:** Auth broken, no logins possible.
**Recovery time:** ~2 minutes (sessions lost).

```bash
ssh root@10.10.100.58 "systemctl stop authelia"
ssh root@10.10.100.58 "mv /mnt/data/db.sqlite3 /mnt/data/db.sqlite3.corrupt"
ssh root@10.10.100.58 "systemctl start authelia"
# Authelia recreates empty SQLite on startup
```

**User impact:** All sessions lost — every user must re-login. No user/config data lost (users are in YAML file, not SQLite). TOTP registrations stored in SQLite will need to be re-enrolled.

#### 13.4.5 CT-316 Destroyed / Unrecoverable

**Symptom:** Container gone or rootfs corrupted.
**Impact:** All protected services return 502.
**Recovery time:** ~5 minutes (ZFS data intact) or ~15 minutes (PBS restore).

**If ZFS datasets intact:**
```bash
# Data survived — just rebuild container
cd ~/Projects/colossus-ansible
bash scripts/authelia/01-create.sh
bash scripts/authelia/02-install.sh
# Config + users + sessions all on ZFS — service resumes
```

**If ZFS datasets lost:**
```bash
# Restore from PBS
# 1. Restore CT-316 from PBS backup
# 2. Start container
ssh root@10.10.100.5 "pct restore 316 <backup-path> --storage local-lvm"
ssh root@10.10.100.5 "pct start 316"
```

#### 13.4.6 Extended Outage — Emergency Auth Bypass

**Symptom:** Authelia cannot be recovered quickly and users need access NOW.
**Impact:** Temporarily removes authentication from all services.
**Recovery time:** ~30 seconds to bypass, then fix Authelia at leisure.

**This is the "break glass" procedure.** Use only when Authelia recovery will take significant time and service access is urgent.

```bash
# Pre-built bypass config removes authelia middleware from all routers
# Keep this file ready on workstation at:
#   ~/Projects/colossus-homelab/emergency/traefik-no-auth.yml

# Deploy bypass
scp ~/Projects/colossus-homelab/emergency/traefik-no-auth.yml \
  root@10.10.100.55:/etc/traefik/dynamic/services.yml

# Traefik hot-reloads dynamic config automatically — no restart needed
# Verify services are accessible without auth
curl -s https://colossus-legal.cogmai.com/ | head -5
```

**CRITICAL:** This removes ALL authentication. Services are fully open. Acceptable for short periods on a private homelab network. For external access, Cloudflare Access policies (if retained) still provide a layer of protection.

**Restore auth after Authelia is fixed:**
```bash
# Restore original Traefik config with authelia middleware
scp ~/Projects/colossus-homelab/traefik/services.yml \
  root@10.10.100.55:/etc/traefik/dynamic/services.yml

# Verify auth is back
curl -sv https://colossus-legal.cogmai.com/ 2>&1 | grep "302\|auth.cogmai.com"
# Should show 302 redirect to auth.cogmai.com
```

### 12.5 Emergency Bypass File

Pre-build and store this file in the colossus-homelab repo. It is an exact copy of the production `services.yml` with all `authelia` middleware references removed:

```
colossus-homelab/
└── emergency/
    ├── traefik-no-auth.yml    # services.yml without authelia middleware
    └── README.md              # Instructions for when to use and how to restore
```

This file must be updated whenever Traefik routing changes. Add a reminder to the Traefik update checklist.

### 12.6 Monitoring & Alerting

| Check | Method | Alert Condition |
|-------|--------|----------------|
| Authelia process health | Prometheus scrape `http://10.10.100.58:9091/metrics` | Target down > 1 minute |
| Authelia HTTP health | Alloy probe or blackbox exporter | `/api/health` returns non-200 |
| CT-316 container status | Proxmox API via PVE exporter | Container stopped |
| ForwardAuth latency | Traefik metrics (middleware duration) | p99 > 500ms |

### 12.7 Resilience Recommendations

| # | Recommendation | Priority | Status |
|---|---------------|----------|--------|
| 1 | Pre-build emergency bypass file and store in git | High | Stage 4 task |
| 2 | Add Authelia health to Prometheus alerting | High | Stage 5 task |
| 3 | Keep Cloudflare Access as defense-in-depth layer | Medium | Already in place |
| 4 | Test emergency bypass procedure quarterly | Low | Operational |
| 5 | Document TOTP re-enrollment procedure | Low | After 2FA enabled |

### 12.8 Decision: Cloudflare Access Retention

Given this failure analysis, the recommendation changes from "evaluate removing Cloudflare Access" to **keep Cloudflare Access permanently**:

- Authelia protects both LAN and external access with user identity + groups
- Cloudflare Access provides an independent external-only gate (email OTP)
- If Authelia fails AND emergency bypass is activated, Cloudflare Access still prevents anonymous external access
- Two independent auth layers is defense in depth, not redundancy

The minor UX cost (two logins for external access) is worth the safety margin.

---

## 13. References

- [Authelia + Traefik Setup Guide](https://www.authelia.com/blog/authelia--traefik-setup-guide/)
- [Authelia Traefik Integration](https://www.authelia.com/integration/proxies/traefik/)
- [Authelia Bare-Metal Deployment](https://www.authelia.com/integration/deployment/bare-metal/)
- [Authelia APT Repository](https://apt.authelia.com)
- [Authelia Access Control](https://www.authelia.com/configuration/security/access-control/)
