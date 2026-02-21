# Colossus — Pi-hole LXC Deployment Runbook v2

**Project:** Colossus Homelab  
**Target:** pve-3 (management/infrastructure node)  
**Version:** 2.0 — Updated after live deployment (2026-02-10)  
**Pi-hole Version:** v6.x (Debian 12 Bookworm LXC)

---

## Changes from v1

| Issue | v1 (broken) | v2 (fixed) |
|-------|-------------|------------|
| Pi-hole CLI | `pihole -a -p` (v5) | `pihole setpassword` (v6) |
| Config file | `setupVars.conf` only | `setupVars.conf` for install, `pihole.toml` post-install |
| Cross-VLAN DNS | Not addressed | "Permit all origins" set automatically |
| PATH | Not in PATH in LXC | `/usr/local/bin` added to PATH automatically |
| pve-2 IP | 10.10.100.4 (wrong) | 10.10.100.2 (correct) |
| Web server | `LIGHTTPD_ENABLED` (v5) | Removed — v6 uses embedded web server |
| Manual steps | Many | Three scripts, minimal interaction |

---

## Container Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| CTID | 311 | |
| Hostname | pihole | |
| IP | 10.10.100.53/24 | Port 53 = DNS (memorable) |
| Gateway | 10.10.100.1 | UDM |
| Proxmox node | pve-3 | Management/infrastructure |
| OS | Debian 12 (Bookworm) | Standard template |
| Resources | 1 core, 512MB RAM, 8GB disk | Minimal — DNS is lightweight |
| Storage | local-lvm | |
| Features | unprivileged=1, nesting=1, onboot=1 | |

---

## Deployment (3 steps)

### Prerequisites

Debian 12 template must be available on pve-3:

```bash
pveam update
pveam download local debian-12-standard_12.12-1_amd64.tar.zst
```

### Step 1: Create container (on pve-3)

```bash
bash 01-create-pihole-lxc.sh
```

Creates CT-311, starts it, and prints instructions for step 2.

### Step 2: Install Pi-hole (inside container)

```bash
# From pve-3 — push script into container and run it
pct push 311 02-install-pihole.sh /root/02-install-pihole.sh
pct exec 311 -- bash /root/02-install-pihole.sh
```

The script will prompt once for the admin password. Everything else is automatic:
- Installs prerequisites and Pi-hole (unattended)
- Fixes PATH for `/usr/local/bin`
- Sets DNS listening mode to "Permit all origins" (cross-VLAN)
- Adds local DNS records (pve-1/2/3, DB VMs, Pi-hole itself)
- Restarts DNS

### Step 3: Verify (from workstation or pve-3)

```bash
bash 03-verify-pihole.sh
```

Runs automated checks: ping, web admin, DNS resolution, ad blocking, performance.

---

## Cross-VLAN DNS Access

Pi-hole sits on 10.10.100.x. If your workstation is on a different VLAN (e.g., 10.10.0.x), DNS queries require:

**On Pi-hole (done automatically by install script):**
- Settings → DNS → Interface Settings → **Permit all origins**

**On UDM (manual, one-time):**
- Create firewall rule allowing UDP+TCP port 53 from workstation VLAN to 10.10.100.53
- Without this rule, `dig @10.10.100.53` times out from your workstation even though the web admin (port 80) works

**Why port 80 works but 53 doesn't:**  
UDM default inter-VLAN rules typically allow established TCP connections (web browsing) but block unsolicited UDP traffic. DNS uses UDP 53 by default, which gets dropped.

---

## Post-Deployment Configuration

### Add local DNS records

Edit `/etc/pihole/custom.list` (inside container):

```bash
pct exec 311 -- nano /etc/pihole/custom.list
```

Format: `IP  hostname` (one per line). After editing:

```bash
pct exec 311 -- pihole restartdns
```

### Add domain records (after domain registration)

Once your domain (e.g., roman.com) is registered, add split-horizon entries:

```
10.10.100.120  legal.roman.com
10.10.100.53   pihole.roman.com
10.10.100.3    pve-1.roman.com
10.10.100.2    pve-2.roman.com
10.10.100.5    pve-3.roman.com
```

These override the public Cloudflare DNS records for internal clients, keeping traffic on-LAN.

### Switch lab VLAN DNS (when ready)

In UDM: Settings → Networks → Lab/Servers VLAN → DHCP DNS → `10.10.100.53`

After this, all devices on the lab VLAN use Pi-hole automatically.

---

## Backup (PBS)

Add CT-311 to PBS backup schedule on pve-3:

```bash
# One-time manual backup
vzdump 311 --storage pbs-storage --compress zstd --mode snapshot
```

Or add to the existing backup schedule in Proxmox web UI:
Datacenter → Backup → Add/Edit job → Include CT 311.

Critical files to preserve (in case of rebuild):
- `/etc/pihole/custom.list` — local DNS records
- `/etc/pihole/pihole.toml` — Pi-hole v6 configuration

---

## Disaster Recovery

| Scenario | Recovery |
|----------|----------|
| Container stopped | `pct start 311` (onboot=1 handles reboots) |
| Config corruption | Restore from PBS |
| pve-3 failure | Rebuild from this runbook (~15 min) + restore custom.list |
| Bypass Pi-hole | Change lab VLAN DNS to 1.1.1.1 in UDM (instant) |

---

## Management Commands

All run from pve-3:

```bash
# Container lifecycle
pct start 311
pct stop 311
pct enter 311

# Pi-hole management (from pve-3, without entering container)
pct exec 311 -- pihole status
pct exec 311 -- pihole restartdns
pct exec 311 -- pihole -g                # Update gravity (blocklists)
pct exec 311 -- pihole setpassword       # Change admin password
pct exec 311 -- cat /etc/pihole/custom.list

# View logs
pct exec 311 -- pihole -t               # Tail DNS query log
```
