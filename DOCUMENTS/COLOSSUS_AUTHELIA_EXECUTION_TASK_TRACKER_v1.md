# Colossus — Authelia Execution Task Tracker

**Version:** v1.0
**Date:** 2026-02-26
**Design Document:** `COLOSSUS_AUTHELIA_DESIGN_v1.md`
**Status:** Ready for execution

---

## Stage 1: LXC Container Creation

**Run on:** pve-3 (via workstation scripts)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 1.1 | Create ZFS datasets on pve-3 | `zfs list -r pbs-zfs/services/authelia` shows data + config | ⬜ |
| 1.2 | Set ZFS dataset ownership for unprivileged LXC | `ls -la` on host shows correct mapped UID | ⬜ |
| 1.3 | Create `scripts/authelia/config.sh` (shared variables) | File exists, matches CT-315 pattern | ⬜ |
| 1.4 | Create `scripts/authelia/00-destroy.sh` | Preserves ZFS data on destroy | ⬜ |
| 1.5 | Create `scripts/authelia/01-create.sh` | CT-316 running, bind mounts attached | ⬜ |
| 1.6 | Verify container networking | `ping 10.10.100.1` and `ping 10.10.100.53` from CT-316 | ⬜ |

**Exit gate:** CT-316 running with Debian 12 minimal, ZFS mounts at `/mnt/data` and `/mnt/config`.

---

## Stage 2: Authelia Installation & Configuration

**Run on:** CT-316 (via workstation script or manual)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 2.1 | Create `scripts/authelia/02-install.sh` | Authelia binary installed via APT | ⬜ |
| 2.2 | Add Authelia APT repository + GPG key | `apt list --installed authelia` shows version | ⬜ |
| 2.3 | Install Authelia package | `authelia --version` returns 4.39.x | ⬜ |
| 2.4 | Generate secrets (JWT, session, storage encryption) | 3 files in `/mnt/config/secrets/` | ⬜ |
| 2.5 | Create `configuration.yml` on config mount | `/mnt/config/configuration.yml` exists | ⬜ |
| 2.6 | Create `users_database.yml` with initial admin user | `/mnt/config/users_database.yml` exists | ⬜ |
| 2.7 | Hash password with `authelia crypto hash generate argon2` | Argon2id hash in users file | ⬜ |
| 2.8 | Create/update systemd unit for Authelia | `systemctl status authelia` shows active | ⬜ |
| 2.9 | Verify Authelia starts and listens on :9091 | `curl -s http://localhost:9091/api/health` returns OK | ⬜ |
| 2.10 | Verify SQLite DB created on data mount | `/mnt/data/db.sqlite3` exists | ⬜ |

**Exit gate:** Authelia running on CT-316:9091, healthy, using externalized config and data.

---

## Stage 3: DNS + Traefik Integration

**Run on:** CT-311 (Pi-hole), CT-313 (Traefik), CT-312 (cloudflared)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 3.1 | Add Pi-hole DNS record: `auth.cogmai.com` → 10.10.100.55 | `dig auth.cogmai.com @10.10.100.53` returns Traefik IP | ⬜ |
| 3.2 | Add Authelia portal router to Traefik `services.yml` | Router visible in Traefik dashboard | ⬜ |
| 3.3 | Add Authelia portal HTTP router (tunnel traffic) | Both HTTP and HTTPS routers present | ⬜ |
| 3.4 | Add ForwardAuth middleware definition to Traefik | Middleware visible in Traefik dashboard | ⬜ |
| 3.5 | Test Authelia portal accessible internally | `https://auth.cogmai.com` shows login page from LAN | ⬜ |
| 3.6 | Add Cloudflare Tunnel route for `auth.cogmai.com` | Route visible in Cloudflare dashboard | ⬜ |
| 3.7 | Test Authelia portal accessible externally | `https://auth.cogmai.com` shows login page from cellular | ⬜ |
| 3.8 | Test login with admin user | Successful login, redirect to default URL | ⬜ |

**Exit gate:** Authelia login portal reachable internally and externally, login works.

---

## Stage 4: Protect Colossus-Legal Routes

**Run on:** CT-313 (Traefik config change)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 4.1 | Add `authelia` middleware to DEV frontend router | Access to `colossus-legal-dev.cogmai.com` redirects to login | ⬜ |
| 4.2 | Add `authelia` middleware to DEV API router | API calls without session return 401/302 | ⬜ |
| 4.3 | Verify DEV health/status endpoints bypass auth | `curl colossus-legal-api-dev.cogmai.com/health` returns OK without login | ⬜ |
| 4.4 | Verify DEV frontend works after login | Full UI accessible post-authentication | ⬜ |
| 4.5 | Verify Remote-User header reaches backend | Backend logs show username in requests | ⬜ |
| 4.6 | Add `authelia` middleware to PROD frontend router | Access to `colossus-legal.cogmai.com` redirects to login | ⬜ |
| 4.7 | Add `authelia` middleware to PROD API router | API calls without session return 401/302 | ⬜ |
| 4.8 | Verify PROD health/status endpoints bypass auth | Monitoring continues working | ⬜ |
| 4.9 | Verify PROD frontend works after login | Full UI accessible post-authentication | ⬜ |
| 4.10 | Test external access (cellular) through full chain | Cloudflare → Tunnel → Traefik → Authelia → App works | ⬜ |
| 4.11 | Create `emergency/traefik-no-auth.yml` bypass config | File in colossus-homelab repo, matches services.yml minus authelia middleware | ⬜ |
| 4.12 | Test emergency bypass: deploy no-auth config | Services accessible without auth after SCP | ⬜ |
| 4.13 | Test emergency restore: redeploy auth config | Services redirect to login after SCP | ⬜ |
| 4.14 | Create `emergency/README.md` with bypass procedure | Clear instructions for when/how to use | ⬜ |
| 4.15 | Commit emergency directory to colossus-homelab | `git push` complete | ⬜ |

**Exit gate:** Both DEV and PROD colossus-legal routes require Authelia authentication. Health endpoints bypass. External access works. Emergency bypass procedure tested and documented.

---

## Stage 5: Infrastructure Integration

**Run on:** Various hosts

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 5.1 | Deploy Alloy agent on CT-316 | `http://10.10.100.58:12345` returns Alloy status | ⬜ |
| 5.2 | Add Alloy scrape target to Prometheus (VM-314) | Target UP in Prometheus | ⬜ |
| 5.3 | Add Authelia metrics scrape target to Prometheus | `http://10.10.100.58:9091/metrics` scraped | ⬜ |
| 5.4 | Add Authelia health alert rule to Alertmanager | Alert fires if `/api/health` down > 1 minute | ⬜ |
| 5.5 | Deploy SSH key to CT-316 | `ssh root@10.10.100.58 hostname` succeeds | ⬜ |
| 5.6 | Add CT-316 to Ansible inventory | `ansible authelia -m ping` succeeds | ⬜ |
| 5.7 | Create PBS backup job for CT-316 | `backup-authelia` job in `/etc/pve/jobs.cfg` | ⬜ |
| 5.8 | Run initial PBS backup | Backup visible in PBS dashboard | ⬜ |
| 5.9 | Optionally protect Grafana/Semaphore with authelia middleware | Admin-only access via Authelia groups | ⬜ |

**Exit gate:** CT-316 monitored, backed up, managed by Ansible, SSH accessible.

---

## Stage 6: Rust Backend AuthUser Extractor

**Run on:** Workstation (colossus-legal codebase)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 6.1 | Create `src/auth.rs` with `AuthUser` struct | Compiles | ⬜ |
| 6.2 | Implement `FromRequestParts` for `AuthUser` | Extracts Remote-User, Remote-Email, Remote-Groups | ⬜ |
| 6.3 | Add helper methods: `is_admin()`, `can_edit()`, `can_use_ai()` | Unit tests pass | ⬜ |
| 6.4 | Add `GET /api/me` endpoint (returns current user info) | Returns JSON with username + groups | ⬜ |
| 6.5 | Add `AuthUser` extractor to write endpoints (POST/PUT) | Unauthorized without Remote-User header | ⬜ |
| 6.6 | Add `AuthUser` extractor to admin endpoints | Forbidden without admin group | ⬜ |
| 6.7 | Add optional `AuthUser` to read endpoints (for audit logging) | Logs username on reads | ⬜ |
| 6.8 | Test locally with mock headers | `curl -H "Remote-User: test"` works | ⬜ |
| 6.9 | Build and push new container image (v0.4.0) | Images on ghcr.io | ⬜ |
| 6.10 | Deploy to DEV via Semaphore | Backend reads auth headers correctly | ⬜ |
| 6.11 | Deploy to PROD via Semaphore | Production verified | ⬜ |

**Exit gate:** Backend enforces group-based authorization, user identity available in all handlers.

---

## Stage 7: Frontend Auth-Aware UI

**Run on:** Workstation (colossus-legal frontend codebase)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 7.1 | Add auth context/hook that calls `GET /api/me` | User info available in React context | ⬜ |
| 7.2 | Show username in header/nav bar | "Logged in as roman" visible | ⬜ |
| 7.3 | Add logout button (clears Authelia session) | Redirects to Authelia logout | ⬜ |
| 7.4 | Conditionally show/hide edit buttons based on groups | Viewers see no edit buttons | ⬜ |
| 7.5 | Conditionally show/hide admin functions | Non-admins can't see embed-all | ⬜ |
| 7.6 | Build and push new frontend image | Images on ghcr.io | ⬜ |
| 7.7 | Deploy to DEV and PROD | UI reflects user permissions | ⬜ |

**Exit gate:** Frontend shows user identity, hides unauthorized actions, logout works.

---

## Stage 8: Testing & Validation

**Run on:** Workstation + mobile

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 8.1 | Create test user with `legal_viewer` group | User in users_database.yml | ⬜ |
| 8.2 | Test viewer: can read documents | List/detail pages work | ⬜ |
| 8.3 | Test viewer: cannot create/edit documents | POST/PUT returns 403 | ⬜ |
| 8.4 | Test viewer: cannot access admin endpoints | embed-all returns 403 | ⬜ |
| 8.5 | Test admin: full access to everything | All endpoints work | ⬜ |
| 8.6 | Test external access with Cloudflare + Authelia | Full chain works from cellular | ⬜ |
| 8.7 | Test session persistence (navigate between pages) | No re-authentication required | ⬜ |
| 8.8 | Test session expiry | After inactivity timeout, re-login required | ⬜ |
| 8.9 | Test Authelia restart — sessions survive | Restart CT-316, existing sessions still valid | ⬜ |
| 8.10 | Test CT-316 destroy + recreate | Sessions lost but config/users survive on ZFS | ⬜ |
| 8.11 | Verify monitoring unaffected (health bypass) | Prometheus targets still UP | ⬜ |
| 8.12 | Walk through diagnostic runbook end-to-end | All 7 diagnostic steps documented and tested | ⬜ |
| 8.13 | Verify Alertmanager fires on Authelia down | Stop Authelia, confirm alert triggers | ⬜ |

**Exit gate:** All user roles enforce correctly, external access works, infrastructure monitoring unaffected.

---

## Stage 9: Ansible Role + Semaphore

**Run on:** Workstation (colossus-ansible codebase)

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 9.1 | Create `roles/authelia/` with tasks, defaults, templates | Role exists in repo | ⬜ |
| 9.2 | Template configuration.yml with Ansible variables | Vault-encrypted secrets | ⬜ |
| 9.3 | Template users_database.yml (passwords from vault) | Users managed via Ansible | ⬜ |
| 9.4 | Create Authelia deploy playbook | `ansible-playbook playbooks/deploy-authelia.yml` succeeds | ⬜ |
| 9.5 | Add Semaphore template for Authelia deploy | Template in Semaphore UI | ⬜ |
| 9.6 | Test idempotent deployment | Second run shows changed=0 | ⬜ |
| 9.7 | Commit and push all changes | Clean git status | ⬜ |

**Exit gate:** Authelia fully managed by Ansible, deployable via Semaphore one-click.

---

## Stage 10: Documentation

**Run on:** Workstation

| # | Task | Validation | Status |
|---|------|-----------|--------|
| 10.1 | Update Master Context to v9 | New section for Authelia, CT-316 in inventory | ⬜ |
| 10.2 | Update Service Endpoints document | auth.cogmai.com, CT-316 IP, port 9091 | ⬜ |
| 10.3 | Create session transition document | Captures all decisions, issues, resolutions | ⬜ |
| 10.4 | Upload documents to Claude Project knowledge | Project knowledge current | ⬜ |
| 10.5 | Commit all documentation to colossus-homelab repo | Clean git status | ⬜ |

**Exit gate:** All documentation current, project knowledge updated.

---

## Summary

| Stage | Scope | Dependencies |
|-------|-------|-------------|
| 1 | LXC container (CT-316) | pve-3, ZFS |
| 2 | Authelia install + config | Stage 1 |
| 3 | DNS + Traefik + Cloudflare | Stage 2, CT-311, CT-313, CT-312 |
| 4 | Protect colossus-legal routes | Stage 3 |
| 5 | Monitoring, backup, Ansible | Stage 2 |
| 6 | Rust AuthUser extractor | Stage 4 (needs working auth to test) |
| 7 | Frontend auth-aware UI | Stage 6 |
| 8 | End-to-end testing | Stages 6 + 7 |
| 9 | Ansible role + Semaphore | Stage 8 (after validation) |
| 10 | Documentation | Stage 9 |

Stages 1–5 are infrastructure. Stages 6–7 are application code. Stages 8–10 are validation and cleanup. Stages 1–5 can likely be completed in one session. Stages 6–7 in a second session. Stages 8–10 to close out.
