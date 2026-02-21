# Colossus — Pi-hole LXC Deployment Runbook

**Version:** v1.0
**Date:** 2026-02-09
**Scope:** Deploy Pi-hole as an LXC container on pve-3
**Target audience:** Roman (operator)

---

## 0. Summary

| Parameter | Value |
|-----------|-------|
| CTID | 311 |
| Hostname | `pihole` |
| Node | pve-3 |
| OS | Debian 12 (Bookworm) |
| IP | `10.10.100.53/24` |
| Gateway | `10.10.100.1` |
| DNS (container) | `1.1.1.1` (bootstrap — Pi-hole replaces this) |
| Resources | 1 core, 512MB RAM, 8GB disk |
| Storage | `local-lvm` |
| Bridge | `vmbr0` |
| Upstream DNS | Cloudflare: `1.1.1.1`, `1.0.0.1` |

---

## 1. Prerequisites

### 1.1 Container Template

You need a Debian 12 container template on pve-3. Check what's available:

```bash
pveam list local
```

If no Debian 12 template exists, download one:

```bash
pveam update
pveam download local debian-12-standard_12.7-1_amd64.tar.zst
```

> **Note:** The exact filename may differ. Run `pveam available | grep debian-12`
> to see current options.

### 1.2 Verify pve-3 Has Capacity

```bash
# Check storage
pvesm status
# Check memory
free -h
```

Pi-hole needs ~200MB RAM and <1GB disk in practice. The 512MB/8GB allocation
is generous.

---

## 2. Create the LXC Container

Run on **pve-3**:

```bash
#!/bin/bash
# 01-create-pihole-lxc.sh — Create Pi-hole LXC container on pve-3
set -euo pipefail

CTID=311
HOSTNAME=pihole
STORAGE=local-lvm
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
# ^^^ Adjust filename to match what pveam downloaded

MEMORY=512
CORES=1
DISK_SIZE=8
IP="10.10.100.53/24"
GATEWAY="10.10.100.1"
BRIDGE="vmbr0"

echo "=== Creating Pi-hole LXC container (CTID ${CTID}) ==="

# Pre-flight
if pct status $CTID &>/dev/null; then
    echo "ERROR: CTID ${CTID} already exists"
    exit 1
fi

# Create container
pct create $CTID $TEMPLATE \
    --hostname $HOSTNAME \
    --storage $STORAGE \
    --rootfs ${STORAGE}:${DISK_SIZE} \
    --cores $CORES \
    --memory $MEMORY \
    --swap 256 \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}" \
    --nameserver "1.1.1.1" \
    --searchdomain "local" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0

echo ""
echo "Container created. Verifying..."
pct config $CTID
echo ""
echo "=== Done. Start with: pct start ${CTID} ==="
```

### Key flags explained:

- `--unprivileged 1`: Security best practice — container runs without root privileges on the host
- `--features nesting=1`: Required for Pi-hole's internal process management
- `--onboot 1`: Auto-start on pve-3 boot (DNS should survive host reboots)
- `--start 0`: Don't start yet — we configure first

---

## 3. Start and Access the Container

```bash
# Start the container
pct start 311

# Enter the container
pct enter 311
```

Once inside, verify networking:

```bash
# Check IP
ip addr show eth0

# Test DNS (should work via 1.1.1.1 we set as nameserver)
ping -c 3 google.com

# Test apt
apt update
```

If `apt update` fails with DNS errors, check that `--nameserver 1.1.1.1` was
applied correctly:

```bash
cat /etc/resolv.conf
# Should show: nameserver 1.1.1.1
```

---

## 4. Install Pi-hole

### 4.1 Install Prerequisites

Inside the container:

```bash
apt update && apt upgrade -y
apt install -y curl
```

### 4.2 Run Pi-hole Installer (Automated)

Pi-hole supports an unattended install via a setup variables file. This avoids
the interactive installer and makes the process repeatable.

**Create the setup variables file:**

```bash
mkdir -p /etc/pihole

cat > /etc/pihole/setupVars.conf << 'EOF'
PIHOLE_INTERFACE=eth0
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=1.0.0.1
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=false
DNS_BOGUS_PRIV=true
DNSSEC=false
REV_SERVER=false
BLOCKING_ENABLED=true
WEBPASSWORD=
EOF
```

> **Note:** `WEBPASSWORD=` is intentionally blank — we'll set it after install.
> `DNS_BOGUS_PRIV=true` prevents forwarding reverse lookups for private IPs
> (10.x, 192.168.x, etc.) to upstream DNS — good security practice.

**Run the installer:**

```bash
curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
```

This takes 1-3 minutes. It will:
- Install lighttpd (web server for the admin UI)
- Install PHP
- Configure dnsmasq (the actual DNS engine)
- Set up log rotation
- Create the `pihole` user

### 4.3 Set Admin Password

```bash
pihole -a -p
```

This prompts for a password interactively. Pick something you'll remember —
this is for the Pi-hole web admin UI.

### 4.4 Verify Installation

```bash
# Check Pi-hole status
pihole status

# Check listening ports
ss -tlnp | grep -E '(53|80)'
```

Expected output should show:
- Port 53 (TCP + UDP) — DNS
- Port 80 (TCP) — Web admin interface

---

## 5. Verify from Outside the Container

Exit the container (`exit` or Ctrl-D) and test from **pve-3**:

```bash
# DNS query test
dig @10.10.100.53 google.com

# Short form
dig @10.10.100.53 google.com +short

# Web admin
curl -s -o /dev/null -w "%{http_code}" http://10.10.100.53/admin/
# Should return 200 or 301
```

Test from your **workstation**:

```bash
# DNS resolution
dig @10.10.100.53 google.com +short

# Or with nslookup
nslookup google.com 10.10.100.53

# Web UI — open in browser
# http://10.10.100.53/admin/
```

---

## 6. Add Internal DNS Records (Local DNS)

This is where split-horizon DNS will live. For now, add records for your
existing infrastructure. You can do this via the **web UI** (Local DNS →
DNS Records) or via the command line.

### 6.1 Via Command Line (Repeatable)

Inside the container (or via `pct exec 311 -- bash -c "..."`):

```bash
cat >> /etc/pihole/custom.list << 'EOF'
# Colossus Infrastructure
10.10.100.3   pve-1.lab
10.10.100.4   pve-2.lab
10.10.100.5   pve-3.lab
10.10.100.110 colossus-prod-db1.lab
10.10.100.200 colossus-dev-db1.lab
10.10.100.50  colossus-db1-dev.lab
10.10.100.53  pihole.lab
EOF
```

Then restart DNS:

```bash
pihole restartdns
```

> **Note:** These use `.lab` as a suffix for now. Once you pick your domain,
> you'll add split-horizon records like `grafana.yourdomain.com → 10.10.100.x`.
> The `.lab` records are for internal convenience and can coexist with the
> public domain records.

### 6.2 Verify Internal Records

From your workstation:

```bash
dig @10.10.100.53 pve-1.lab +short
# Should return: 10.10.100.3

dig @10.10.100.53 colossus-prod-db1.lab +short
# Should return: 10.10.100.110
```

> **Important:** Adjust the IPs above if your Proxmox nodes use different
> addresses. I'm using the pattern from your project docs — verify against
> your actual `/etc/hosts` on a Proxmox node.

---

## 7. PBS Backup Configuration

The LXC container should be backed up to PBS like your other VMs.

On **pve-3** (or via Proxmox UI):

### 7.1 Verify PBS is Configured as Storage

```bash
pvesm status | grep pbs
```

If PBS storage is not visible on pve-3, you need to add it (this may already
be done from Phase 1).

### 7.2 Create Backup Job

In the Proxmox UI:
1. Datacenter → Backup → Add
2. Storage: Select your PBS storage
3. Node: pve-3
4. Selection mode: Include selected VMs
5. VMs: Check 311 (pihole)
6. Schedule: Daily (suggested: 02:00)
7. Retention: daily 14, weekly 8, monthly 12 (match existing policy)

Or via CLI:

```bash
# Manual backup test
vzdump 311 --storage <your-pbs-storage-id> --mode snapshot --compress zstd
```

---

## 8. Post-Install Hardening

### 8.1 Update Pi-hole Gravity (Block Lists)

Pi-hole ships with a default set of blocklists. Update gravity to get the
latest:

```bash
pct exec 311 -- pihole -g
```

### 8.2 Enable Auto-Updates (Optional)

Inside the container:

```bash
apt install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades
```

This handles Debian security updates. Pi-hole itself is updated separately:

```bash
pihole -up   # Manual Pi-hole update
```

---

## 9. Verification Checklist

Run these from your **workstation**:

```bash
#!/bin/bash
# verify-pihole.sh — Validate Pi-hole deployment
set -e

PIHOLE_IP="10.10.100.53"

echo "=== Pi-hole Verification ==="

# DNS resolution (external domain)
echo -n "External DNS resolution... "
RESULT=$(dig @${PIHOLE_IP} google.com +short | head -1)
if [ -n "$RESULT" ]; then
    echo "✓ (${RESULT})"
else
    echo "✗ FAILED"
    exit 1
fi

# DNS resolution (internal record)
echo -n "Internal DNS resolution... "
RESULT=$(dig @${PIHOLE_IP} pihole.lab +short)
if [ "$RESULT" = "${PIHOLE_IP}" ]; then
    echo "✓ (${RESULT})"
else
    echo "✗ FAILED (got: ${RESULT})"
    exit 1
fi

# Web admin accessible
echo -n "Web admin UI... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://${PIHOLE_IP}/admin/)
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ]; then
    echo "✓ (HTTP ${HTTP_CODE})"
else
    echo "✗ FAILED (HTTP ${HTTP_CODE})"
    exit 1
fi

# Ad blocking working
echo -n "Ad blocking active... "
BLOCKED=$(dig @${PIHOLE_IP} ads.google.com +short)
if echo "$BLOCKED" | grep -qE "^0\.0\.0\.0$|^$"; then
    echo "✓ (blocked)"
else
    echo "⚠ not blocking (${BLOCKED}) — may be normal with default lists"
fi

echo ""
echo "=== Pi-hole is operational ==="
echo "Web admin: http://${PIHOLE_IP}/admin/"
```

---

## 10. Next Steps After Pi-hole is Running

### 10.1 UDM DNS Switch (Section 2 from Task Tracker)

Once Pi-hole is verified:
1. In UDM UI → Networks → Lab/Servers VLAN → DHCP → DNS Server: `10.10.100.53`
2. Renew DHCP on a test client to verify
3. **Do NOT change Family VLAN DNS** — leave it on UDM/ISP/1.1.1.1

### 10.2 Split-Horizon Records (After Domain Registration)

Once you have your domain:

```bash
# Example — add inside Pi-hole container
cat >> /etc/pihole/custom.list << 'EOF'
# Split-horizon: internal IPs for public domain names
10.10.100.220 legal.yourdomain.com
10.10.100.200 grafana.yourdomain.com
EOF

pihole restartdns
```

### 10.3 Stability Test

After UDM DNS switch:
1. **Shut down Pi-hole container** (`pct stop 311`)
2. Verify family internet still works (it should — different DNS)
3. Verify lab DNS fails (expected — Pi-hole is the DNS server)
4. **Start Pi-hole** (`pct start 311`)
5. Verify lab DNS recovers

This confirms the isolation model works.

---

## 11. Disaster Recovery

| Scenario | Recovery |
|----------|----------|
| Pi-hole container crash | `pct start 311` — auto-start on boot handles most cases |
| Pi-hole config corruption | Restore from PBS backup |
| pve-3 failure | Rebuild container from this runbook (15 min) + restore gravity/custom.list from backup |
| Need to bypass Pi-hole | Change lab VLAN DNS back to 1.1.1.1 in UDM (instant) |

### Backup Artifacts to Preserve

| File | Purpose |
|------|---------|
| `/etc/pihole/setupVars.conf` | Installation configuration |
| `/etc/pihole/custom.list` | Local DNS records (split-horizon) |
| `/etc/pihole/custom.cname` | Local CNAME records |
| `/etc/pihole/pihole-FTL.conf` | FTL engine configuration |
| Pi-hole Teleporter export | Full config backup (Settings → Teleporter in web UI) |

---

## 12. Known Considerations

1. **Port 53 conflict:** If pve-3 itself runs `systemd-resolved` listening
   on port 53, it may conflict. LXC containers get their own network namespace
   so this is usually not an issue, but if DNS fails check with
   `ss -tlnp | grep :53` on pve-3 host.

2. **Unprivileged container limitations:** Pi-hole in an unprivileged LXC
   cannot modify host networking. This is fine — it only needs to listen on
   its own IP. If you see permission errors during install, the `nesting=1`
   feature should resolve most of them.

3. **DHCP:** Pi-hole can serve as a DHCP server, but **do NOT enable this**.
   Your UDM handles DHCP. Pi-hole is DNS-only in this design.

4. **Container DNS bootstrap:** The container's own `/etc/resolv.conf` initially
   points to 1.1.1.1 (set during creation). After Pi-hole install, the container
   resolves through itself. If Pi-hole's DNS engine dies, the container can't
   resolve external names either. This is acceptable — if Pi-hole is broken,
   you fix it via `pct enter 311` which doesn't need DNS.

---

*End of Pi-hole LXC Deployment Runbook v1.0*
