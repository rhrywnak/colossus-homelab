# Colossus — Authentication Execution Task Tracker v2

**Version:** v2.0
**Date:** 2026-02-26
**Design Document:** `COLOSSUS_AUTHENTIK_MIGRATION_DESIGN_v1.md`
**Supersedes:** `COLOSSUS_AUTHELIA_EXECUTION_TASK_TRACKER_v1.md`
**Status:** In progress — Stages 1–4 complete (Authelia), migration to Authentik required

---

## Completed Stages (Authelia — Carry-Over Infrastructure)

These stages were executed during the Authelia deployment. The infrastructure they created carries forward into the Authentik migration — DNS records, Cloudflare tunnel routes, Traefik ForwardAuth pattern, and `forwardedHeaders` fix are all reusable.

| Stage | Description | Status |
|-------|-------------|--------|
| 1 | LXC Container Creation (CT-316) | ✅ Complete |
| 2 | Authelia Installation & Configuration | ✅ Complete |
| 3 | DNS + Traefik + Cloudflare Integration | ✅ Complete |
| 4 | Protect Colossus-Legal Routes | ✅ Complete (API routes have temp auth_bypass) |

**Key infrastructure that carries over unchanged:**
- Pi-hole DNS: `auth.cogmai.com → 10.10.100.55` ✅
- Cloudflare Tunnel: `auth.cogmai.com → http://10.10.100.55:80` ✅
- Traefik `forwardedHeaders.trustedIPs` fix ✅
- Traefik `services.yml.j2` template with conditional auth middleware ✅
- `traefik_authelia.enabled` emergency bypass variable ✅

---

## Stage 5A: Authentik VM Creation

**Run on:** pve-3 (via workstation scripts)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 5A.1 | Create ZFS datasets on pve-3 (`pbs-zfs/services/authentik/postgres`, `media`, `templates`) | `zfs list -r pbs-zfs/services/authentik` shows 3 datasets | ⬜ |
| 5A.2 | Create Proxmox directory resource mappings for virtiofs | Mappings visible in Proxmox UI | ⬜ |
| 5A.3 | Create Butane config for VM-316 (2 cores, 2048MB, Quadlet units) | `authentik.bu` compiles to `authentik.ign` | ⬜ |
| 5A.4 | Create `scripts/authentik/config.sh` (shared variables) | File exists, matches established pattern | ⬜ |
| 5A.5 | Create `scripts/authentik/00-destroy.sh` | Preserves ZFS data on destroy | ⬜ |
| 5A.6 | Create `scripts/authentik/01-create-vm.sh` | VM-316 created with q35, virtiofs, Ignition | ⬜ |
| 5A.7 | Boot VM-316, verify CoreOS starts | SSH to `core@10.10.100.58` succeeds | ⬜ |
| 5A.8 | Verify virtiofs mounts inside VM | `/mnt/data/postgres`, `/mnt/data/media`, `/mnt/data/templates` mounted | ⬜ |

**Exit gate:** VM-316 running CoreOS, ZFS mounts available, SSH accessible.

---

## Stage 5B: Authentik Container Deployment

**Run on:** VM-316 (via Butane/Ignition or manual Quadlet setup)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 5B.1 | Create PostgreSQL Quadlet unit (`authentik-postgresql.container`) | `sudo systemctl status authentik-postgresql` active | ⬜ |
| 5B.2 | Verify PostgreSQL data on virtiofs mount | Files in `/mnt/data/postgres/` | ⬜ |
| 5B.3 | Create shared env file with `AUTHENTIK_SECRET_KEY`, PostgreSQL credentials | `/etc/colossus/env/authentik.env` exists, mode 0600 | ⬜ |
| 5B.4 | Create authentik-server Quadlet unit (`authentik-server.container`) | `sudo systemctl status authentik-server` active | ⬜ |
| 5B.5 | Create authentik-worker Quadlet unit (`authentik-worker.container`) | `sudo systemctl status authentik-worker` active | ⬜ |
| 5B.6 | Verify Authentik health endpoint | `curl http://localhost:9000/-/health/live/` returns 200 | ⬜ |
| 5B.7 | Verify all 3 containers running | `sudo podman ps` shows postgresql, server, worker | ⬜ |
| 5B.8 | Run initial setup wizard | Navigate to `http://10.10.100.58:9000/if/flow/initial-setup/` from LAN, create akadmin | ⬜ |

**Exit gate:** Authentik running on VM-316:9000, admin account created, all containers healthy.

---

## Stage 5C: Authentik Application Configuration

**Run on:** Authentik admin UI (`http://10.10.100.58:9000`)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 5C.1 | Create Proxy Provider (`colossus-forward-auth`, domain-level, cookie domain `cogmai.com`) | Provider visible in admin UI | ⬜ |
| 5C.2 | Create Application (`Colossus Services`, linked to proxy provider) | Application visible in admin UI | ⬜ |
| 5C.3 | Enable application on Embedded Outpost | Outpost shows `Colossus Services` | ⬜ |
| 5C.4 | Create group: `admin` | Group visible in admin UI | ⬜ |
| 5C.5 | Create group: `legal_editor` | Group visible in admin UI | ⬜ |
| 5C.6 | Create group: `legal_viewer` | Group visible in admin UI | ⬜ |
| 5C.7 | Create group: `ai_user` | Group visible in admin UI | ⬜ |
| 5C.8 | Create user: `roman` (admin + legal_editor + ai_user groups) | User visible, temp password set | ⬜ |
| 5C.9 | Test direct login at `http://10.10.100.58:9000` | Login succeeds, forced password change works | ⬜ |
| 5C.10 | Disable Authentik analytics/update checks | Settings applied | ⬜ |

**Exit gate:** Authentik configured with proxy provider, groups, and admin user. Direct login works.

---

## Stage 5D: Traffic Switchover (Authelia → Authentik)

**Run on:** CT-313 (Traefik), pve-3

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 5D.1 | Stop Authelia on CT-316 | `ssh root@10.10.100.58 systemctl stop authelia` (note: CT still exists) | ⬜ |
| 5D.2 | Stop CT-316 (Authelia LXC) | `pct stop 316` on pve-3 | ⬜ |
| 5D.3 | Update `inventory/host_vars/traefik.yml`: change middleware to Authentik | ForwardAuth address → `http://10.10.100.58:9000/outpost.goauthentik.io/auth/traefik`, updated `authResponseHeaders` | ⬜ |
| 5D.4 | Update `services.yml.j2` template: Authentik headers + outpost path router | Template renders correctly with `--check --diff` | ⬜ |
| 5D.5 | Deploy Traefik config | `ansible-playbook playbooks/manage-traefik.yml` | ⬜ |
| 5D.6 | Test internal access: `https://auth.cogmai.com` shows Authentik login | Login page renders | ⬜ |
| 5D.7 | Test login: authenticate as `roman` | Redirect back to protected app works | ⬜ |
| 5D.8 | Test protected route: `https://colossus-legal.cogmai.com` | Redirects to Authentik login, then back to app | ⬜ |
| 5D.9 | Test external access: `https://auth.cogmai.com` from cellular | Cloudflare → Tunnel → Traefik → Authentik works | ⬜ |
| 5D.10 | Verify ForwardAuth headers reach backend | Check Traefik access logs for `X-authentik-username` | ⬜ |

**Exit gate:** All traffic routed through Authentik. Login, redirect, and header injection working.

---

## Stage 5E: Cleanup & Infrastructure Integration

**Run on:** pve-3, various hosts

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 5E.1 | Destroy CT-316 (Authelia LXC) | `pct destroy 316` on pve-3 | ⬜ |
| 5E.2 | Destroy Authelia ZFS datasets | `zfs destroy -r pbs-zfs/services/authelia` | ⬜ |
| 5E.3 | Remove Authelia from Ansible inventory | `authelia` host removed from `hosts.yml` | ⬜ |
| 5E.4 | Add VM-316 (Authentik) to Ansible inventory | `ansible authentik -m ping` succeeds | ⬜ |
| 5E.5 | Deploy SSH key to VM-316 | `ssh core@10.10.100.58 hostname` succeeds | ⬜ |
| 5E.6 | Deploy Alloy agent to VM-316 | `http://10.10.100.58:12345` returns Alloy status | ⬜ |
| 5E.7 | Add Alloy + Authentik metrics scrape targets to Prometheus | Targets UP in Prometheus | ⬜ |
| 5E.8 | Create PBS backup job for VM-316 | `backup-authentik` job in `/etc/pve/jobs.cfg` | ⬜ |
| 5E.9 | Run initial PBS backup | Backup visible in PBS dashboard | ⬜ |
| 5E.10 | Remove Authelia provisioning scripts from colossus-ansible | `scripts/authelia/` directory removed | ⬜ |
| 5E.11 | Commit all changes to git | Clean status across repos | ⬜ |

**Exit gate:** Authelia fully removed. VM-316 monitored, backed up, managed by Ansible.

---

## Stage 6: Rust Backend AuthUser Extractor

**Run on:** Workstation (colossus-legal codebase)
**Reference:** `COLOSSUS_LEGAL_AUTHELIA_INTEGRATION_GUIDE_v1.md` (header names updated for Authentik)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 6.1 | Create `src/auth.rs` with `AuthUser` struct | Compiles | ⬜ |
| 6.2 | Implement `FromRequestParts` for `AuthUser` | Extracts `X-authentik-username`, `X-authentik-email`, `X-authentik-groups` | ⬜ |
| 6.3 | Add helper methods: `is_admin()`, `can_edit()`, `can_use_ai()` | Unit tests pass | ⬜ |
| 6.4 | Add `GET /api/me` endpoint (returns current user info) | Returns JSON with username + groups | ⬜ |
| 6.5 | Add `AuthUser` extractor to write endpoints (POST/PUT) | Unauthorized without `X-authentik-username` header | ⬜ |
| 6.6 | Add `AuthUser` extractor to admin endpoints | Forbidden without admin group | ⬜ |
| 6.7 | Add optional `AuthUser` to read endpoints (for audit logging) | Logs username on reads | ⬜ |
| 6.8 | Update CORS: add `.allow_credentials(true)`, explicit `.allow_headers(...)` | Credentialed cross-origin requests work | ⬜ |
| 6.9 | Add `AUTH_MODE` to `AppConfig` | `AUTH_MODE=optional` for local dev, `required` for deployed | ⬜ |
| 6.10 | Test locally with mock headers | `curl -H "X-authentik-username: test"` works | ⬜ |
| 6.11 | Build and push new container image (v0.4.0) | Images on ghcr.io | ⬜ |
| 6.12 | Deploy to DEV via Semaphore | Backend reads auth headers correctly | ⬜ |
| 6.13 | Deploy to PROD via Semaphore | Production verified | ⬜ |

**Exit gate:** Backend enforces group-based authorization, user identity available in all handlers.

---

## Stage 7: Frontend Auth-Aware UI

**Run on:** Workstation (colossus-legal frontend codebase)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 7.1 | Add `authFetch()` wrapper with `credentials: 'include'` to `api.ts` | All fetch calls send cookies | ⬜ |
| 7.2 | Create `services/auth.ts` with `getCurrentUser()` and `logout()` | Types defined, logout URL points to Authentik | ⬜ |
| 7.3 | Replace `fetch()` with `authFetch()` in all service files | All service files updated | ⬜ |
| 7.4 | Create `AuthContext` provider calling `GET /api/me` | User info available in React context | ⬜ |
| 7.5 | Wrap App with `<AuthProvider>` | Context available throughout app | ⬜ |
| 7.6 | Show username + logout button in header/nav | "Logged in as roman" visible | ⬜ |
| 7.7 | Conditionally show/hide edit buttons based on groups | Viewers see no edit buttons | ⬜ |
| 7.8 | Conditionally show/hide admin functions | Non-admins can't see embed-all | ⬜ |
| 7.9 | Handle 403 responses (toast, not redirect) | Permission denied shows notification | ⬜ |
| 7.10 | Build and push new frontend image (v0.4.0) | Images on ghcr.io | ⬜ |
| 7.11 | Deploy to DEV and PROD | UI reflects user permissions | ⬜ |

**Exit gate:** Frontend shows user identity, hides unauthorized actions, logout works.

---

## Stage 8: Remove Auth Bypass & End-to-End Testing

**Run on:** Workstation, CT-313 (Traefik), mobile

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 8.1 | Remove `auth_bypass: true` from API routes in `host_vars/traefik.yml` | API routes protected by Authentik | ⬜ |
| 8.2 | Deploy Traefik config | `ansible-playbook playbooks/manage-traefik.yml` | ⬜ |
| 8.3 | Test DEV: frontend loads after Authentik login | Full UI accessible post-authentication | ⬜ |
| 8.4 | Test DEV: API calls include session cookie | Network tab shows `credentials: include` | ⬜ |
| 8.5 | Test PROD: full chain from cellular | Cloudflare → Authentik → App works | ⬜ |
| 8.6 | Create test user with `legal_viewer` group via Authentik admin UI | User visible in admin UI | ⬜ |
| 8.7 | Test viewer: can read documents | List/detail pages work | ⬜ |
| 8.8 | Test viewer: cannot create/edit (403) | POST/PUT returns 403, toast in UI | ⬜ |
| 8.9 | Test admin: full access to everything | All endpoints work | ⬜ |
| 8.10 | Test session persistence (navigate between pages) | No re-authentication required | ⬜ |
| 8.11 | Test session expiry | After timeout, re-login required | ⬜ |
| 8.12 | Test Authentik restart — sessions survive | `sudo systemctl restart authentik-server`, sessions valid | ⬜ |
| 8.13 | Verify monitoring unaffected (health bypass) | Prometheus targets still UP | ⬜ |
| 8.14 | Test emergency bypass (disable auth in Traefik) | Services accessible without auth | ⬜ |
| 8.15 | Test password change: user changes own password via Authentik UI | New password works on next login | ⬜ |

**Exit gate:** All user roles enforce correctly. Full auth chain verified. Self-service password change works.

---

## Stage 9: Ansible Automation

**Run on:** Workstation (colossus-ansible codebase)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 9.1 | Create Authentik provisioning scripts (`scripts/authentik/`) | Scripts for ZFS, VM creation | ⬜ |
| 9.2 | Create Butane template for VM-316 | Ignition config produces working VM | ⬜ |
| 9.3 | Add `AUTH_MODE=required` to backend env file templates | Both DEV and PROD env files updated | ⬜ |
| 9.4 | Add Semaphore template for colossus-legal v0.4.0 deployment | Template in Semaphore UI | ⬜ |
| 9.5 | Commit and push all changes | Clean git status across repos | ⬜ |

**Exit gate:** Full automation for Authentik VM and colossus-legal auth deployment.

---

## Stage 10: Documentation

**Run on:** Workstation

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 10.1 | Update Master Context to v9 | Authentik replaces Authelia, VM-316 in inventory | ⬜ |
| 10.2 | Update Service Endpoints document | auth.cogmai.com, VM-316 IP, port 9000 | ⬜ |
| 10.3 | Archive Authelia design docs (move to DOCUMENTS/archive/) | Files moved, not deleted | ⬜ |
| 10.4 | Create session transition document | Captures migration decisions, issues, resolutions | ⬜ |
| 10.5 | Upload documents to Claude Project knowledge | Project knowledge current | ⬜ |
| 10.6 | Commit all documentation | Clean git status | ⬜ |

**Exit gate:** All documentation current. Authelia docs archived. Project knowledge updated.

---

## Summary

| Stage | Scope | Dependencies |
|-------|-------|-------------|
| ~~1–4~~ | ~~Authelia infrastructure~~ | ✅ Complete (carry-over) |
| 5A | Authentik VM creation | pve-3, ZFS, CoreOS template |
| 5B | Authentik container deployment | Stage 5A |
| 5C | Authentik application config (admin UI) | Stage 5B |
| 5D | Traffic switchover (Authelia → Authentik) | Stage 5C, CT-313 |
| 5E | Cleanup + infrastructure integration | Stage 5D |
| 6 | Rust AuthUser extractor | Stage 5D (needs working auth) |
| 7 | Frontend auth-aware UI | Stage 6 |
| 8 | Remove bypass + end-to-end testing | Stages 6 + 7 |
| 9 | Ansible automation | Stage 8 |
| 10 | Documentation | Stage 9 |

**Estimated effort:**
- Stages 5A–5E: One session (~4–5 hours)
- Stages 6–7: One session (~3–4 hours, application code)
- Stages 8–10: One session (~2–3 hours, testing and docs)
