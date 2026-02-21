# Colossus Phase 4 — Execution Checklist

**Status:** ⬜ PENDING  
**Design Reference:** `COLOSSUS_PHASE4_DESIGN_v1.md`  
**Date Created:** 2026-02-09

---

## Phase 4A — Application Deployment

### 4A.0 Prerequisites (Application Code — Must Complete First)

- [ ] Implement `GET /health` endpoint in backend (returns 200/503)
- [ ] Make CORS origins configurable via `CORS_ORIGINS` environment variable
- [ ] Create `Dockerfile.backend` (multi-stage: rust builder + debian-slim)
- [ ] Create `Dockerfile.frontend` (multi-stage: node builder + nginx)
- [ ] Create `nginx.conf` (SPA routing, port 5473, cache headers)
- [ ] Test `podman build` for both images on workstation
- [ ] Test `podman run` for both containers on workstation (local end-to-end)
- [ ] Build and verify first release images

### 4A.1 DEV Host Preparation (pve-2)

- [ ] Create ZFS dataset `dev-zfs/legal-docs`
- [ ] Create Proxmox directory mapping `dev-legal-docs`
- [ ] Copy legal document PDFs to `/dev-zfs/legal-docs/`
- [ ] Verify file count (16 PDFs)

### 4A.2 DEV App VM Creation (VM-220)

- [ ] Author Butane config (`colossus-dev-app1.bu`)
  - [ ] Static IP 10.10.100.220
  - [ ] virtiofs mount for legal-docs with SELinux context
  - [ ] Quadlet: colossus-backend.container
  - [ ] Quadlet: colossus-frontend.container
  - [ ] Environment file (backend.env — DEV values)
  - [ ] nginx.conf for frontend
  - [ ] SSH authorized key
- [ ] Transpile Butane → Ignition (`--strict`)
- [ ] Copy Ignition to pve-2 snippets directory
- [ ] Create VM-220 via `qm` script (q35, 2 cores, 4GB, 20G disk)
- [ ] Attach virtiofs (dirid=dev-legal-docs)
- [ ] Start VM
- [ ] Verify: SSH, virtiofs mount with container_file_t, hostname

### 4A.3 DEV Image Deployment

- [ ] Transfer backend image tar to VM-220
- [ ] Transfer frontend (DEV) image tar to VM-220
- [ ] Load both images (`podman load`)
- [ ] Restart container services
- [ ] Verify: both containers running (`podman ps`)

### 4A.4 DEV Validation

- [ ] `GET /health` returns 200
- [ ] `GET /case` returns JSON with `awad-v-cfs`
- [ ] `GET /schema` returns node counts
- [ ] Frontend serves at :5473 (HTML contains "Colossus")
- [ ] Browser test: frontend loads, navigation works
- [ ] Browser test: documents page shows 16 documents
- [ ] Browser test: at least one PDF opens
- [ ] Browser test: analysis page shows 18 allegations
- [ ] Reboot VM-220 — containers come back automatically (images won't — see note)

**Note:** After reboot, Quadlet will try to start containers with `localhost/colossus-backend:latest`. If the image was loaded with `podman load`, it persists across reboots in local storage. Verify this during the reboot test.

### 4A.5 PROD Host Preparation (pve-1)

- [ ] Create ZFS dataset `prod-zfs/legal-docs`
- [ ] Create Proxmox directory mapping `prod-legal-docs`
- [ ] Copy legal document PDFs to `/prod-zfs/legal-docs/`
- [ ] Verify file count (16 PDFs)

### 4A.6 PROD App VM Creation (VM-120)

- [ ] Author Butane config (`colossus-prod-app1.bu`)
  - [ ] Static IP 10.10.100.120
  - [ ] virtiofs mount for legal-docs with SELinux context
  - [ ] Quadlet: colossus-backend.container
  - [ ] Quadlet: colossus-frontend.container
  - [ ] Environment file (backend.env — PROD values)
  - [ ] nginx.conf for frontend
  - [ ] SSH authorized key
- [ ] Transpile Butane → Ignition (`--strict`)
- [ ] Copy Ignition to pve-1 snippets directory
- [ ] Create VM-120 via `qm` script (q35, 2 cores, 4GB, 20G disk)
- [ ] Attach virtiofs (dirid=prod-legal-docs)
- [ ] Start VM
- [ ] Verify: SSH, virtiofs mount with container_file_t, hostname

### 4A.7 PROD Image Deployment

- [ ] Transfer backend image tar to VM-120
- [ ] Transfer frontend (PROD) image tar to VM-120
- [ ] Load both images
- [ ] Restart container services
- [ ] Verify: both containers running

### 4A.8 PROD Validation

- [ ] `GET /health` returns 200
- [ ] `GET /case` returns JSON with `awad-v-cfs`
- [ ] Frontend serves at :5473
- [ ] Full browser validation (same as DEV checklist)
- [ ] Reboot VM-120 — containers survive
- [ ] DEV vs PROD comparison (both serve same data)

### 4A.9 Backup & Closeout

- [ ] PBS backup of VM-120 (first PROD app backup)
- [ ] Schedule daily PBS backup for VM-120
- [ ] Add VM-120 and VM-220 to SSH multiplexing config if needed
- [ ] Update Master Context: VM inventory, network, artifacts

---

## Phase 4B — Edge Services & DNS

### 4B.0 Prerequisites

- [ ] Choose public domain name
- [ ] Register domain with registrar (enable lock + 2FA)
- [ ] Create Cloudflare account (enable 2FA)
- [ ] Inventory UDM VLANs and current DNS settings
- [ ] Confirm console/out-of-band access to UDM + Proxmox nodes

### 4B.1 Cloudflare Domain Setup

- [ ] Add domain to Cloudflare
- [ ] Note assigned Cloudflare nameservers
- [ ] Update registrar nameservers to Cloudflare
- [ ] Wait for propagation
- [ ] Verify domain resolves via Cloudflare dashboard

### 4B.2 Pi-hole Deployment (pve-3)

- [ ] Download Debian 12 LXC template
- [ ] Create LXC container (CTID 311, 1 vCPU, 512MB, 4GB disk)
- [ ] Configure static IP 10.10.100.53
- [ ] Install Pi-hole
- [ ] Set admin password
- [ ] Configure upstream DNS (1.1.1.1, 8.8.8.8)
- [ ] Validate: `nslookup example.com 10.10.100.53` works
- [ ] Add Pi-hole to PBS backup schedule

### 4B.3 UDM VLAN DNS Configuration

- [ ] Set family VLAN DNS to UDM default / 1.1.1.1 (NOT Pi-hole)
- [ ] Set lab/servers VLAN DNS to Pi-hole (10.10.100.53)
- [ ] (Optional) Set IoT VLAN DNS to Pi-hole
- [ ] Renew DHCP on test client per VLAN — verify DNS server
- [ ] **Safety test:** Shut down Pi-hole — confirm family internet works

### 4B.4 Edge VM Deployment (VM-310)

- [ ] Author Butane config (`colossus-edge1.bu`)
  - [ ] Static IP 10.10.100.30
  - [ ] Quadlet: cloudflared.container
  - [ ] Tunnel credentials and config
  - [ ] SSH authorized key
- [ ] Transpile Butane → Ignition
- [ ] Create VM-310 via `qm` script (q35, 2 cores, 2GB, 10G disk)
- [ ] Start VM
- [ ] Verify SSH + base health

### 4B.5 Cloudflare Tunnel Configuration

- [ ] Create tunnel in Cloudflare dashboard (`colossus-homelab`)
- [ ] Download tunnel credentials JSON
- [ ] Store credentials securely (offline copy)
- [ ] Create `config.yml` with ingress rules
- [ ] Deploy credentials + config to edge VM
- [ ] Start cloudflared service
- [ ] Verify tunnel connected in Cloudflare dashboard
- [ ] Create DNS CNAME records for each hostname → tunnel

### 4B.6 Cloudflare Access Policies

- [ ] Enable Zero Trust / Access in Cloudflare
- [ ] Configure identity provider (email OTP or Google SSO)
- [ ] Create access policy for `legal.<domain>`
- [ ] Create access policy for `neo4j.<domain>`
- [ ] Verify: incognito browser → prompt for auth (not direct access)

### 4B.7 Split-Horizon DNS

- [ ] Add Pi-hole local DNS records:
  - [ ] `legal.<domain>` → 10.10.100.120
  - [ ] `neo4j.<domain>` → 10.10.100.110
- [ ] Verify internal: `nslookup legal.<domain> 10.10.100.53` → internal IP
- [ ] Verify external: cellular test → Cloudflare tunnel
- [ ] Verify no hairpin: LAN browser → `legal.<domain>` hits internal directly

### 4B.8 Full Validation

- [ ] Family VLAN: internet works with Pi-hole down
- [ ] Lab VLAN: DNS resolves via Pi-hole
- [ ] External: `https://legal.<domain>` works from cellular, requires auth
- [ ] Internal: `http://legal.<domain>` works from LAN, goes direct
- [ ] Reboot edge VM: tunnel auto-restores
- [ ] Cloudflare logs visible
- [ ] Pi-hole query logs visible

### 4B.9 Backup & Closeout

- [ ] PBS backup of VM-310 (edge VM)
- [ ] PBS backup of CT-311 (Pi-hole LXC)
- [ ] Document rollback procedure (disable tunnel, remove DNS)
- [ ] Store tunnel credentials offline
- [ ] Update Master Context: VM inventory, network, DNS architecture

---

## Phase 4 Completion Gate

- [ ] Colossus-Legal accessible internally (PROD)
- [ ] Colossus-Legal accessible externally (Cloudflare Tunnel + Access)
- [ ] Split-horizon DNS working (same URL, inside and outside)
- [ ] Family network unaffected
- [ ] All new VMs/LXCs backed up to PBS
- [ ] Master Context updated
- [ ] Phase 4 Completion Report authored
- [ ] Phase 4 locked

---

## Notes

- SSH multiplexing (`~/.ssh/config`) should be extended to cover new VMs
  if pve-1's igc NIC continues to cause issues
- App VM images persist in local podman storage across reboots, but
  if the VM is rebuilt from Ignition, images must be reloaded
- Legal documents rarely change — no automated sync needed
