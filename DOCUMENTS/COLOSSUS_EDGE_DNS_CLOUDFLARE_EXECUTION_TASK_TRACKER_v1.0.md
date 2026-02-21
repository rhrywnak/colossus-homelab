# COLOSSUS — External Access + DNS Architecture — Execution & Task Tracker v1.0

**Use this as a living checklist.**  
- Add notes in the “Operator Notes” column as you execute.  
- When complete, mark ✅ and add completion date/time.

**Scope:** Domain + Cloudflare DNS + Cloudflare Tunnel + UDM VLAN DNS split + Pi-hole lab DNS + split-horizon records + validation + rollback plan.

---

## 0. Change Control + Safety Gates

| Gate | Requirement | Status | Operator Notes |
|---|---|---:|---|
| G0.1 | Confirm **no Proxmox node hostname changes** are planned (`pve-*.local` stays) | ⬜ | |
| G0.2 | Confirm you have console access to UDM + Proxmox nodes (out-of-band enough to recover DNS mistakes) | ⬜ | |
| G0.3 | Snapshot/backup edge VM (once created) before major changes | ⬜ | |
| G0.4 | Define “family VLAN must remain working” as top priority invariant | ⬜ | |

---

## 1. Domain Acquisition + DNS Planning

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 1.1 | Choose a public domain name | Pick something stable for years. Avoid `.local`. | ⬜ | |
| 1.2 | Register domain | Use registrar of choice. Enable registrar lock + 2FA. | ⬜ | |
| 1.3 | Create Cloudflare account + enable 2FA | Use strong auth. | ⬜ | |
| 1.4 | Add domain to Cloudflare | Follow Cloudflare add-site flow; note assigned nameservers. | ⬜ | |
| 1.5 | Update registrar nameservers to Cloudflare | Replace with Cloudflare-provided NS; wait for propagation. | ⬜ | |
| 1.6 | Create baseline DNS records (optional) | `A` record for `@` can be placeholder; tunnel will be CNAMEs later. | ⬜ | |

**Checkpoint:** Domain resolves via Cloudflare (verify in Cloudflare dashboard).

---

## 2. Decide DNS Split by VLAN on UDM (Household vs Lab)

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 2.1 | Inventory VLANs / Networks in UDM | Identify which network is family, lab/servers, IoT, guest. | ⬜ | |
| 2.2 | Set Family VLAN DNS to UDM/ISP/External | UDM Network → DHCP Name Server: Auto or custom (e.g., 1.1.1.1). Ensure **NOT Pi-hole**. | ⬜ | |
| 2.3 | Set Lab/Servers VLAN DNS to Pi-hole | UDM Network → DHCP Name Server: Manual → Pi-hole IP(s). | ⬜ | |
| 2.4 | (Optional) Set IoT VLAN DNS to Pi-hole | Recommended if you want IoT filtering/visibility. | ⬜ | |
| 2.5 | (Optional) Add firewall rules to “force DNS” on IoT | Block IoT → WAN UDP/TCP 53 except Pi-hole; allow IoT → Pi-hole 53. | ⬜ | |
| 2.6 | Validate DHCP changes | Renew DHCP on a test client in each VLAN and confirm DNS server used. | ⬜ | |

**Checkpoint:** Family devices still work even if Pi-hole is shut down.

---

## 3. Deploy Pi-hole on pve-3 (Infra/Services)

> You indicated pve-3 is the services node (PBS already running) and you want to host Pi-hole/metrics there.

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 3.1 | Choose Pi-hole runtime | VM vs LXC vs container. Prefer “boring + backed up”. | ⬜ | |
| 3.2 | Assign Pi-hole static IP | Place in servers/lab VLAN; reserve via DHCP or set static. Record IP. | ⬜ | |
| 3.3 | Install Pi-hole | Install + set admin password + upstream DNS (optionally Unbound later). | ⬜ | |
| 3.4 | Enable local DNS (records/overrides) | Confirm where you’ll manage internal records (Pi-hole UI). | ⬜ | |
| 3.5 | Validate Pi-hole from a lab client | `nslookup example.com <pihole-ip>` and confirm response. | ⬜ | |
| 3.6 | Document Pi-hole backup procedure | Export gravity/teleporter or back up volumes if containerized. | ⬜ | |

**Checkpoint:** Lab VLAN devices successfully use Pi-hole for DNS; family VLAN does not.

---

## 4. Deploy “Edge Services” VM on pve-3 (colossus-edge1)

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 4.1 | Create edge VM spec | Small: 1–2 vCPU, 1GB RAM, minimal disk, stable network. | ⬜ | |
| 4.2 | Choose OS | Recommended: Fedora CoreOS (aligns with your standard) fileciteturn0file0 | ⬜ | |
| 4.3 | Create VM via script | Use `qm` script approach (no click-ops). Document VMID, MAC, IP method. | ⬜ | |
| 4.4 | Apply Butane/Ignition | Provision cloudflared container via Quadlet (systemd-managed). | ⬜ | |
| 4.5 | Verify base VM health | SSH, systemd status, time sync, updates, etc. | ⬜ | |

**Checkpoint:** Edge VM is stable and “infra-only”.

---

## 5. Configure Cloudflare Tunnel (cloudflared)

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 5.1 | Create Tunnel in Cloudflare | Name: `colossus-homelab` (or similar). | ⬜ | |
| 5.2 | Generate tunnel credentials | Download/record `credentials.json`. Store securely (offline copy). | ⬜ | |
| 5.3 | Create `config.yml` for cloudflared | Define ingress hostnames → internal services. Include a final 404 rule. | ⬜ | |
| 5.4 | Install credentials + config on edge VM | Place under `/etc/cloudflared/` (or your chosen path). | ⬜ | |
| 5.5 | Start cloudflared service | Ensure systemd starts it at boot and it shows “healthy/connected”. | ⬜ | |
| 5.6 | Create public DNS entries for apps | In Cloudflare DNS: `CNAME` host → tunnel. | ⬜ | |

**Checkpoint:** From a phone on cellular, `https://<app>.<domain>` reaches Cloudflare (may still be blocked by Access until configured).

---

## 6. Configure Cloudflare Access Policies (Security)

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 6.1 | Enable Zero Trust / Access | In Cloudflare dashboard. | ⬜ | |
| 6.2 | Define identity provider | Email OTP, Google, etc. | ⬜ | |
| 6.3 | Create app policies per hostname | Require auth; allow only your user(s). | ⬜ | |
| 6.4 | Add service tokens for machine access (optional) | For API endpoints, prefer tokens. | ⬜ | |
| 6.5 | Validate that sensitive apps are protected | Try incognito access; ensure it prompts/denies correctly. | ⬜ | |

**Checkpoint:** No app is anonymously accessible unless explicitly intended.

---

## 7. Implement Split-Horizon DNS (Internal Overrides)

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 7.1 | Decide override location | Pi-hole (recommended for lab) and/or UDM (few household names). | ⬜ | |
| 7.2 | Add internal DNS records for key apps | Example: `grafana.<domain>` → internal IP:port (DNS is IP only; port handled by browser). | ⬜ | |
| 7.3 | Validate internal resolution in lab VLAN | `nslookup grafana.<domain> <pihole-ip>` → internal IP. | ⬜ | |
| 7.4 | Validate external resolution from WAN | Cellular test: should resolve via Cloudflare to tunnel. | ⬜ | |
| 7.5 | Validate “inside uses inside” (no hairpin) | From LAN browser, open `https://grafana.<domain>` and confirm it hits internal path (if TLS differs, decide policy). | ⬜ | |

**Note on TLS inside:**  
If you override DNS to internal IP but still use `https://grafana.<domain>`, you’ll want local TLS handling. Two common approaches:
- Keep internal clients using `http://grafana.<domain>` (simple).
- Add an internal reverse proxy with local TLS (more work, cleaner UX).

Choose one and document it here.

---

## 8. Validation Plan (Functional + Safety)

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 8.1 | Family VLAN stability test | Shut down Pi-hole; confirm family internet still works. | ⬜ | |
| 8.2 | Lab VLAN DNS test | Confirm lab VLAN fails DNS when Pi-hole is down (expected), then recovers. | ⬜ | |
| 8.3 | External access test (cellular) | Confirm each published hostname works and is Access-protected. | ⬜ | |
| 8.4 | Internal access test (LAN) | Confirm internal name resolution works as intended. | ⬜ | |
| 8.5 | Reboot resilience | Reboot edge VM; confirm tunnel auto-restores. | ⬜ | |
| 8.6 | Logging/visibility | Verify Cloudflare logs and Pi-hole logs are usable. | ⬜ | |

---

## 9. Rollback Plan (Must Be Clear)

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 9.1 | Disable tunnel routing | Stop cloudflared service; confirm external access stops. | ⬜ | |
| 9.2 | Remove/disable Cloudflare DNS records | Remove app hostnames if needed. | ⬜ | |
| 9.3 | Remove internal DNS overrides | Remove Pi-hole local records/overrides. | ⬜ | |
| 9.4 | Restore prior DHCP DNS settings | Revert UDM per-VLAN DNS to previous state if needed. | ⬜ | |
| 9.5 | Confirm Proxmox cluster unaffected | Validate cluster membership/quorum unchanged. | ⬜ | |

---

## 10. Documentation Closeout

| ID | Task | Details / Steps | Done | Operator Notes |
|---|---|---|---:|---|
| 10.1 | Record final architecture decisions | Domain, VLAN DNS split, edge VM placement, policies. | ⬜ | |
| 10.2 | Store configs in repo | cloudflared config (not secrets), runbooks, screenshots references. | ⬜ | |
| 10.3 | Store secrets safely | Tunnel credentials + recovery codes offline. | ⬜ | |
| 10.4 | Update master context doc | Add “Edge Services” and DNS/Tunnel design summary. | ⬜ | |

---

## Appendix A — Minimal cloudflared config template (fill in)

```yaml
# /etc/cloudflared/config.yml
tunnel: colossus-homelab
credentials-file: /etc/cloudflared/<tunnel-id>.json

ingress:
  - hostname: grafana.<your-domain>
    service: http://10.10.100.20:3000
  - hostname: neo4j.<your-domain>
    service: http://10.10.100.20:7474
  - service: http_status:404
```

## Appendix B — Operator Notes Log (optional)

- [ ] Notes entry 1:
- [ ] Notes entry 2:
