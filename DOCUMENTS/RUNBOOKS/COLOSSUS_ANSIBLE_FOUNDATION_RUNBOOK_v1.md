# Colossus Ansible Foundation Runbook — Phase 5B-1

**Document Type:** Operational Runbook  
**Phase:** 5B-1 — Ansible Foundation  
**Author:** Colossus Infrastructure Team  
**Date:** 2026-02-14  
**Status:** COMPLETE ✅  
**Depends on:** Phase 5A (Traefik) ✅, Phase 5A-TrueNAS ✅  

---

## 1. Purpose

This runbook documents every configuration change made during Phase 5B-1 to establish Ansible as the configuration management foundation for the Colossus homelab. It captures the exact commands, workarounds, troubleshooting steps, and lessons learned so the entire process can be reproduced or audited without repeating the trial-and-error that occurred during the initial implementation.

**Scope of changes:**

- SSH key authentication deployed to all 11 managed hosts
- SSH server installed and enabled on 3 LXC containers
- Python3 + libselinux-python3 layered onto 2 CoreOS VMs
- SSH connection multiplexing configured on workstation
- Ansible project structure created with inventory, vault, and validation playbook
- UniFi UDM SE IDS/IPS detection exclusions added for internal subnets
- Ansible configuration tuned (forks, vault auto-decrypt, output format)

---

## 2. Prerequisites

### 2.1 Control Node (proxima-centauri)

The Ansible control node is `proxima-centauri`, Roman's Linux workstation on the main network (10.10.0.0/24).

| Component | Version | Install Method |
|-----------|---------|----------------|
| Ansible | 2.16.3 | System package (pre-existing) |
| Python3 | 3.x | System (pre-existing) |
| proxmoxer | 2.2.0 | `pip3 install proxmoxer --break-system-packages` |
| community.general | Pre-installed | `ansible-galaxy collection install community.general` |

### 2.2 SSH Key

The workstation uses an Ed25519 SSH key:

```
~/.ssh/id_ed25519 (private)
~/.ssh/id_ed25519.pub (public)
SHA256:FEe4MlYzbkM5i8viYDAjzHfZT6kFGOfPqMaHqxrWav4
```

If regenerating on a new workstation:

```bash
ssh-keygen -t ed25519 -C "roman@proxima-centauri"
```

---

## 3. SSH Key Deployment — All Hosts

### 3.1 Proxmox Nodes (root@)

**Hosts:** pve-1 (10.10.100.3), pve-2 (10.10.100.2), pve-3 (10.10.100.5)

pve-1 already had key auth configured. For pve-2 and pve-3, the standard `ssh-copy-id` approach had issues (stale host keys from pve-3 NIC replacement, temp directory errors). The working procedure was:

```bash
# Clear stale host keys if needed (e.g., after NIC swap)
ssh-keygen -R 10.10.100.5
ssh-keygen -R 10.10.100.2

# If ssh-copy-id works:
ssh-copy-id root@10.10.100.2
ssh-copy-id root@10.10.100.5

# If ssh-copy-id fails (temp directory errors), push key manually:
cat ~/.ssh/id_ed25519.pub | ssh root@10.10.100.2 "cat >> /root/.ssh/authorized_keys"
ssh root@10.10.100.2 "chmod 600 /root/.ssh/authorized_keys"

# Verify key auth (should NOT prompt for password):
ssh -o ConnectTimeout=3 root@10.10.100.3 "hostname"  # pve-1
ssh -o ConnectTimeout=3 root@10.10.100.2 "hostname"  # pve-2
ssh -o ConnectTimeout=3 root@10.10.100.5 "hostname"  # pve-3
```

**Gotcha:** `ssh-copy-id` can report "All keys were skipped because they already exist" even when the `authorized_keys` file doesn't exist. This is a misleading error caused by temp directory creation failures. Always verify by actually testing key-based SSH.

### 3.2 PBS (root@10.10.100.242)

PBS had no `authorized_keys` file despite `ssh-copy-id` claiming success:

```bash
# Verify the file actually exists:
ssh root@10.10.100.242 "ls -la /root/.ssh/authorized_keys"

# If missing, create it manually:
cat ~/.ssh/id_ed25519.pub | ssh root@10.10.100.242 "cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"

# Verify:
ssh -o ConnectTimeout=3 root@10.10.100.242 "hostname"
```

### 3.3 CoreOS VMs (core@)

**Hosts:** VM-110 (10.10.100.110), VM-120 (10.10.100.120), VM-210 (10.10.100.200), VM-220 (10.10.100.220)

CoreOS VMs were provisioned with SSH keys via Butane/Ignition during initial creation, so key auth already worked for the `core` user:

```bash
ssh -o ConnectTimeout=3 core@10.10.100.110 "hostname"  # colossus-prod-db1
ssh -o ConnectTimeout=3 core@10.10.100.120 "hostname"  # colossus-prod-app1
ssh -o ConnectTimeout=3 core@10.10.100.200 "hostname"  # colossus-dev-db1
ssh -o ConnectTimeout=3 core@10.10.100.220 "hostname"  # colossus-dev-app1
```

**Gotcha:** VM-220 (colossus-dev-app1) initially showed intermittent SSH timeouts from the workstation. This resolved after fixing the UniFi IPS issue (Section 8). If a CoreOS VM is reachable from its Proxmox host but not from the workstation, suspect IPS/IDS first.

### 3.4 LXC Containers (root@) — Required SSH Setup

**Hosts:** CT-311 pihole (10.10.100.53), CT-312 cloudflared (10.10.100.54), CT-313 traefik (10.10.100.55)

LXC containers did **not** have SSH configured at creation time. Ansible requires direct SSH access (not `pct exec`), so SSH had to be installed and keys deployed via `pct exec` through pve-3.

#### Step 1: Create .ssh directories

```bash
ssh root@10.10.100.5 "pct exec 311 -- bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'"
ssh root@10.10.100.5 "pct exec 312 -- bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'"
ssh root@10.10.100.5 "pct exec 313 -- bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'"
```

#### Step 2: Deploy SSH public key

```bash
PUBKEY=$(cat ~/.ssh/id_ed25519.pub)

ssh root@10.10.100.5 "pct exec 311 -- bash -c 'echo \"$PUBKEY\" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'"
ssh root@10.10.100.5 "pct exec 312 -- bash -c 'echo \"$PUBKEY\" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'"
ssh root@10.10.100.5 "pct exec 313 -- bash -c 'echo \"$PUBKEY\" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'"
```

**Gotcha:** Piping `cat ~/.ssh/id_ed25519.pub` through multiple SSH hops can append stray characters (tilde `~`). Using a variable (`PUBKEY=...`) with `echo` is cleaner and avoids this.

#### Step 3: Install and enable SSH server

The LXC containers (Debian 12) had `openssh-server` already installed but the SSH service was not enabled/running.

```bash
ssh root@10.10.100.5 "pct exec 311 -- systemctl enable --now ssh"
ssh root@10.10.100.5 "pct exec 312 -- systemctl enable --now ssh"
ssh root@10.10.100.5 "pct exec 313 -- systemctl enable --now ssh"
```

**Gotcha — Debian vs RHEL service name:** Debian uses `ssh` (not `sshd`). Attempting `systemctl enable --now sshd` will fail with: `Refusing to operate on alias name or linked unit file: sshd.service`. The perl locale warnings during enable are cosmetic and can be ignored.

#### Step 4: Verify direct SSH access from workstation

```bash
ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new root@10.10.100.53 "hostname"  # pihole
ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new root@10.10.100.54 "hostname"  # cloudflared
ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new root@10.10.100.55 "hostname"  # traefik
```

Use `-o StrictHostKeyChecking=accept-new` on first connection to auto-accept the new host keys.

---

## 4. Python3 on CoreOS VMs (Ansible Requirement)

### 4.1 The Problem

Fedora CoreOS is intentionally minimal — no Python installed by default. Ansible requires Python on managed hosts for all modules except `raw`. The App VMs (VM-120, VM-220) already had Python3 from their Butane provisioning, but the DB VMs (VM-110, VM-210) did not.

### 4.2 Canonical Solution: rpm-ostree with --apply-live

The community-consensus approach for Fedora CoreOS + Ansible is to layer `python3` and `libselinux-python3` using `rpm-ostree`. The `--apply-live` flag applies the change immediately via an overlayfs on `/usr`, avoiding a reboot.

```bash
ssh core@10.10.100.110 "sudo rpm-ostree install python3 libselinux-python3 --apply-live"
ssh core@10.10.100.200 "sudo rpm-ostree install python3 libselinux-python3 --apply-live"
```

**Why both packages:**

- `python3` — Required for Ansible module execution
- `libselinux-python3` — Required for Ansible to manage files on SELinux-enforcing systems (all CoreOS VMs have SELinux enforcing)

### 4.3 How --apply-live Works

- Creates a new ostree deployment with the package layered on
- Mounts an overlayfs over `/usr` to make the packages available immediately
- The overlayfs is transient (rebuilt on reboot), but the package is persisted in the ostree deployment
- After next reboot, the package is available natively (no overlayfs needed)
- Survives CoreOS auto-updates — the package layer is maintained across version upgrades

### 4.4 Verification

```bash
ssh core@10.10.100.110 "python3 --version"
ssh core@10.10.100.200 "python3 --version"

# Verify via Ansible:
ansible db_vms -m ping
```

### 4.5 Future VMs — Bake into Butane/Ignition

For new CoreOS VMs, the best practice is to add a one-shot systemd unit to the Butane config that installs Python before SSH becomes available. This ensures Ansible can manage the VM from first boot:

```yaml
# Add to Butane file — runs once before sshd starts
systemd:
  units:
    - name: install-python-for-ansible.service
      enabled: true
      contents: |
        [Unit]
        Requires=network-online.target
        After=network-online.target
        Before=sshd.service
        [Service]
        Type=oneshot
        ExecCondition=/usr/bin/test ! -f /etc/python3-for-ansible.done
        ExecStart=/usr/bin/rpm-ostree install python3 libselinux-python3 --apply-live
        ExecStartPost=/usr/bin/touch /etc/python3-for-ansible.done
        [Install]
        WantedBy=multi-user.target
```

---

## 5. SSH Connection Multiplexing

### 5.1 The Problem

Ansible spawns multiple parallel SSH connections. Without connection multiplexing, each connection performs a full TCP + SSH handshake. Combined with IPS inspection (Section 8), this caused random SSH timeouts.

### 5.2 Configuration

Added to `~/.ssh/config` on proxima-centauri:

```
Host 10.10.100.*
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 120s
    ServerAliveInterval 15
    ServerAliveCountMax 3
```

**What this does:**

- `ControlMaster auto` — First connection to a host opens a persistent control socket; subsequent connections reuse it
- `ControlPath` — Socket file location (unique per user@host:port)
- `ControlPersist 120s` — Keep the master connection alive for 2 minutes after the last session disconnects
- `ServerAliveInterval 15` — Send keepalive every 15 seconds to detect dead connections
- `ServerAliveCountMax 3` — Close after 3 missed keepalives (45 seconds)

### 5.3 Pre-existing Entries

The config already had specific entries for 10.10.100.110 (VM-110) and 10.10.100.3 (pve-1) from earlier troubleshooting. The wildcard `10.10.100.*` entry covers all hosts. SSH matches the first applicable `Host` entry, so specific entries take precedence over the wildcard.

### 5.4 Managing Stale Sockets

If connections hang due to a stale multiplexing socket:

```bash
# List active sockets:
ls ~/.ssh/cm-*

# Kill a specific socket:
ssh -O exit -o ControlPath=~/.ssh/cm-%r@%h:%p root@10.10.100.5

# Nuclear option — kill all:
rm ~/.ssh/cm-*
```

---

## 6. Ansible Project Structure

### 6.1 Directory Layout

```
~/colossus-ansible/
├── ansible.cfg                        # Ansible configuration
├── inventory/
│   ├── hosts.yml                      # All hosts, groups, variables
│   └── group_vars/
│       ├── all.yml                    # Global variables + default ansible_user
│       ├── coreos_vms.yml             # ansible_user: core, python interpreter
│       ├── infrastructure.yml         # ansible_user: root
│       ├── dev.yml                    # DEV environment overrides (pre-existing)
│       ├── prod.yml                   # PROD environment overrides (pre-existing)
│       └── vault.yml                  # Encrypted variables (pre-existing)
├── secrets/
│   └── vault.yml                      # Ansible Vault encrypted secrets
├── playbooks/
│   └── gather-facts.yml               # Validation playbook
├── apps/                              # Application variable files (future)
├── services/                          # Docker Compose service definitions (future)
├── roles/                             # Ansible roles (future — Phase 5B-2)
├── host_vars/                         # Per-host variable overrides (future)
└── butane/                            # Butane template files (future)
```

### 6.2 ansible.cfg

```ini
[defaults]
inventory = inventory/hosts.yml
private_key_file = ~/.ssh/id_ed25519
vault_password_file = ~/.vault_pass
host_key_checking = False
retry_files_enabled = False
stdout_callback = default
result_format = yaml
timeout = 30
forks = 10

[privilege_escalation]
become = False
```

**Key settings explained:**

- `vault_password_file` — Points to `~/.vault_pass` (outside project directory, never committed to Git)
- `host_key_checking = False` — Required for Ansible to connect without interactive confirmation
- `forks = 10` — Number of parallel host connections. Initially set to 3 during IPS troubleshooting, restored to 10 after IPS exclusions were added
- `stdout_callback = default` with `result_format = yaml` — Clean output format

### 6.3 inventory/hosts.yml

```yaml
all:
  children:
    proxmox:
      hosts:
        pve-1:
          ansible_host: 10.10.100.3
          ansible_user: root
          proxmox_role: prod
        pve-2:
          ansible_host: 10.10.100.2
          ansible_user: root
          proxmox_role: dev
        pve-3:
          ansible_host: 10.10.100.5
          ansible_user: root
          proxmox_role: infra

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

    backup:
      hosts:
        pbs:
          ansible_host: 10.10.100.242
          ansible_user: root

    storage:
      hosts:
        truenas:
          ansible_host: 10.10.0.38
          ansible_user: admin
```

**Note:** TrueNAS (10.10.0.38) has SSH disabled. It is listed in inventory for completeness but excluded from playbooks with `hosts: all:!truenas`. Enable SSH via TrueNAS web UI → System → Services when ready to manage via Ansible.

### 6.4 Group Variables

**inventory/group_vars/all.yml** (appended to pre-existing file):

```yaml
# ── Network & Infrastructure ─────────────────────────────────
domain: cogmai.com
traefik_ip: 10.10.100.55
pihole_ip: 10.10.100.53
truenas_ip: 10.10.0.38
pbs_ip: 10.10.100.242

# ── Default SSH user (overridden per group) ──────────────────
ansible_user: root
```

**inventory/group_vars/coreos_vms.yml:**

```yaml
---
ansible_user: core
ansible_python_interpreter: /usr/bin/python3
```

**inventory/group_vars/infrastructure.yml:**

```yaml
---
ansible_user: root
```

**Critical lesson:** Group variables MUST be in `inventory/group_vars/` (inside the inventory directory), not in a top-level `group_vars/` directory. The `ansible` CLI ad-hoc commands pick up group_vars from the current working directory, but `ansible-playbook` looks relative to the playbook file location. Placing them inside the inventory directory ensures they're always found regardless of where commands are run from.

### 6.5 Ansible Vault

Encrypted secrets are stored in `secrets/vault.yml`:

```bash
# Create (prompts for vault password and opens editor):
ansible-vault create secrets/vault.yml

# Contents (fill in real values):
# ---
# vault_neo4j_password: "YOUR_NEO4J_PASSWORD"
# vault_cloudflare_dns_api_token: "YOUR_CF_TOKEN"
# vault_cloudflare_tunnel_token: "YOUR_TUNNEL_TOKEN"
# vault_anthropic_api_key: ""  # Future

# Auto-decrypt via password file:
echo 'YOUR_VAULT_PASSWORD' > ~/.vault_pass
chmod 600 ~/.vault_pass
```

The `vault_password_file` setting in `ansible.cfg` points to `~/.vault_pass`, allowing all vault operations without interactive password entry.

**Verify:** `ansible-vault view secrets/vault.yml` should display contents without prompting.

### 6.6 Validation Playbook

**playbooks/gather-facts.yml:**

```yaml
---
- name: Gather facts from all Colossus hosts
  hosts: all:!truenas
  gather_facts: true
  tasks:
    - name: Display host summary
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }} | {{ ansible_distribution | default('N/A') }} {{ ansible_distribution_version | default('') }} | {{ ansible_default_ipv4.address | default(ansible_host) }}"
```

**Expected output (all 11 hosts):**

| Host | Distribution | Version |
|------|-------------|---------|
| pve-1 | Debian | 13.3 |
| pve-2 | Debian | 13.3 |
| pve-3 | Debian | 13.3 |
| colossus-prod-db1 | Fedora | 43 |
| colossus-dev-db1 | Fedora | 43 |
| colossus-prod-app1 | Fedora | 43 |
| colossus-dev-app1 | Fedora | 43 |
| pihole | Debian | 12.x |
| cloudflared | Debian | 12.x |
| traefik | Debian | 12.x |
| pbs | Proxmox BS | - |

---

## 7. Ansible Connectivity Verification

### 7.1 Ad-hoc Ping (Quick Test)

```bash
ansible all --limit '!truenas' -m ping
```

All 10 managed hosts should return `pong`.

### 7.2 Full Facts Playbook (Comprehensive Test)

```bash
# Serial (one host at a time — safest for troubleshooting):
ansible-playbook playbooks/gather-facts.yml --forks 1

# Parallel (full speed):
ansible-playbook playbooks/gather-facts.yml
```

### 7.3 Idempotency Check

Run the playbook twice. Second run should show `changed=0` for every host:

```bash
ansible-playbook playbooks/gather-facts.yml
# Expected: ok=2, changed=0 for all 11 hosts
```

---

## 8. UniFi UDM SE — IDS/IPS Detection Exclusions

### 8.1 The Problem

The UniFi UDM SE had Intrusion Prevention (IPS) enabled with "Notify and Block" mode. The IPS was treating legitimate cross-VLAN traffic between the homelab VLAN (10.10.100.0/24) and the main/NAS network (10.10.0.0/24) as intrusion attempts, intermittently dropping packets.

**Symptoms:**

- Random SSH timeouts when running `ansible-playbook` — different hosts failed each run
- Even `--forks 1` (serial) failed randomly
- `ping` and `nc -zv` to affected hosts always succeeded
- SSH would hang during key exchange or after authentication

### 8.2 Root Cause Evidence

**System Log → Security Detection** in the UniFi controller showed hundreds of blocks:

| Source | Destination | Meaning |
|--------|-------------|---------|
| 10.10.100.2 → 10.10.0.38 | pve-2 → TrueNAS | NFS/PBS backup sync |
| 10.10.100.3 → 10.10.0.38 | pve-1 → TrueNAS | NFS/PBS backup sync |
| 10.10.100.5 → 10.10.0.38 | pve-3 → TrueNAS | NFS/PBS backup sync |
| 10.10.0.99 → 10.10.100.53 | (unknown) → pihole | DNS queries |
| 10.10.0.99 → 10.10.100.120 | (unknown) → prod-app1 | Application traffic |

The IPS was blocking Proxmox ↔ TrueNAS backup traffic approximately every 15 minutes. This was causing silent backup disruptions that were not previously noticed, in addition to the Ansible SSH timeouts.

### 8.3 IPS Configuration (Before Fix)

- **Location:** UniFi Controller → CyberSecure → Protection
- **Intrusion Prevention:** ON
- **Detection Mode:** Notify and Block
- **Selected Networks:** Default
- **Active Detections:** "Attacks and Reconnaissance" (3 of 7 enabled), "Hacking and Exploits" (3 of 5 enabled)

### 8.4 The Fix — Detection Exclusions

**Location:** UniFi Controller → CyberSecure → Protection → Detection Exclusions → Create New

Added two exclusions:

1. **10.10.100.0/24** — Homelab VLAN (all Proxmox nodes, VMs, CTs)
2. **10.10.0.0/24** — Main/NAS network (TrueNAS, workstation)

These tell the IPS to not inspect traffic originating from or destined to these subnets. IPS continues to protect against external (internet-facing) threats.

### 8.5 Verification

After adding exclusions, the Ansible playbook immediately succeeded for all 11 hosts:

```bash
# Serial — 11/11 success:
ansible-playbook playbooks/gather-facts.yml --forks 1

# Parallel (forks=10) — 11/11 success, changed=0 (idempotent):
ansible-playbook playbooks/gather-facts.yml
```

### 8.6 Impact Beyond Ansible

The IPS exclusions also fixed:

- **PBS sync job stability** — Proxmox → TrueNAS NFS traffic was being intermittently blocked every 15 minutes
- **Cross-VLAN service reliability** — Any traffic between the homelab VLAN and main network is no longer subject to false-positive IPS blocks
- **DNS resolution** — Traffic to pihole (10.10.100.53) from the main network was occasionally blocked

### 8.7 General Guidance: Homelab IPS

IPS is designed to protect against external threats. Internal homelab traffic between your own subnets should be excluded from IPS inspection for two reasons:

1. **False positives** — Automated tools (Ansible, cron jobs, backup sync) generate traffic patterns that look like scans/attacks to signature-based IPS
2. **Performance** — Inspecting every internal packet adds latency and CPU overhead with no security benefit

Keep IPS enabled for internet-facing traffic. Exclude all internal management and service subnets.

---

## 9. Complete Host Connectivity Reference

### 9.1 All Managed Hosts

| Host | Inventory Name | IP | SSH User | Group | Notes |
|------|---------------|-----|----------|-------|-------|
| pve-1 | pve-1 | 10.10.100.3 | root | proxmox | PROD node |
| pve-2 | pve-2 | 10.10.100.2 | root | proxmox | DEV node |
| pve-3 | pve-3 | 10.10.100.5 | root | proxmox | Infra node |
| VM-110 | colossus-prod-db1 | 10.10.100.110 | core | coreos_vms.db_vms | PROD databases |
| VM-210 | colossus-dev-db1 | 10.10.100.200 | core | coreos_vms.db_vms | DEV databases |
| VM-120 | colossus-prod-app1 | 10.10.100.120 | core | coreos_vms.app_vms | PROD applications |
| VM-220 | colossus-dev-app1 | 10.10.100.220 | core | coreos_vms.app_vms | DEV applications |
| CT-311 | pihole | 10.10.100.53 | root | infrastructure | DNS |
| CT-312 | cloudflared | 10.10.100.54 | root | infrastructure | Cloudflare Tunnel |
| CT-313 | traefik | 10.10.100.55 | root | infrastructure | Reverse proxy |
| VM-900 | pbs | 10.10.100.242 | root | backup | Proxmox Backup Server |

### 9.2 Unmanaged Hosts

| Host | IP | Reason |
|------|-----|--------|
| TrueNAS | 10.10.0.38 | SSH disabled; manage via web UI or API |

---

## 10. Troubleshooting Reference

### 10.1 SSH Timeouts to Random Hosts

**Check first:** UniFi IDS/IPS — System Log → Security Detection for blocks involving homelab IPs.

**Then check:**

```bash
# Is the host reachable at all?
ping -c 2 <host_ip>

# Is SSH port open?
nc -zv -w3 <host_ip> 22

# Verbose SSH (look for where it stalls):
ssh -v -o ConnectTimeout=5 <user>@<host_ip> "hostname"

# Kill stale multiplexing socket:
rm ~/.ssh/cm-<user>@<host_ip>:22
```

### 10.2 CoreOS VM — "No Python" Error

```
colossus-prod-db1 | FAILED! => {"module_stderr": "/bin/sh: python3: command not found"
```

**Fix:**

```bash
ssh core@<host_ip> "sudo rpm-ostree install python3 libselinux-python3 --apply-live"
```

### 10.3 LXC Container — SSH Connection Refused

```
pihole | UNREACHABLE! => {"msg": "Connection refused"}
```

**Fix (from pve-3):**

```bash
ssh root@10.10.100.5 "pct exec <ctid> -- systemctl enable --now ssh"
```

### 10.4 Ansible Playbook Uses Wrong User

```
UNREACHABLE! => Permission denied (publickey,password)
```

**Check:** Are group_vars in `inventory/group_vars/`, not top-level `group_vars/`? Verify with:

```bash
ansible-inventory --host <hostname> | grep ansible_user
```

### 10.5 Vault Decryption Fails

```
ERROR! vault_password_file ... already exists
```

**Fix:** Ensure `vault_password_file` is under the `[defaults]` section in `ansible.cfg`, not under `[privilege_escalation]`.

---

## 11. Phase 5B-1 Success Criteria — Final Status

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Ansible inventory covers all 9 VMs/CTs + PBS | ✅ 11 hosts (10 managed + TrueNAS listed) |
| 2 | `ansible all -m ping` succeeds for every managed host | ✅ 10/10 |
| 3 | Ansible Vault stores all secrets | ✅ Neo4j, Cloudflare tokens |
| 4 | Facts playbook runs successfully against all hosts | ✅ 11/11 (serial + parallel) |
| 5 | Idempotent execution (changed=0 on second run) | ✅ Confirmed |

---

## 12. Key Lessons Learned

1. **CoreOS + Ansible:** The canonical approach is `rpm-ostree install python3 libselinux-python3 --apply-live`. No reboot required. Survives auto-updates.

2. **UniFi IPS + Homelab:** Internal subnets MUST be excluded from IDS/IPS detection. The IPS sees automated tools (Ansible, cron backups, DNS queries) as attacks and silently drops packets. This can cause intermittent, hard-to-diagnose failures.

3. **SSH multiplexing:** Essential for Ansible stability when managing many hosts. Configure at the subnet level (`Host 10.10.100.*`) with `ControlPersist` for session reuse.

4. **group_vars location:** Must be inside `inventory/group_vars/` for playbooks to find them reliably. Top-level `group_vars/` works for ad-hoc commands but not for playbooks in subdirectories.

5. **Debian SSH service name:** `ssh`, not `sshd`. The `sshd.service` unit exists but is an alias — `systemctl enable` refuses to operate on aliases.

6. **ssh-copy-id reliability:** Don't trust "keys already exist" messages. Always verify with an actual key-based SSH connection. Manual key deployment via `echo` + `cat` is more reliable through multi-hop scenarios.

7. **LXC containers need SSH:** Ansible requires direct SSH access. `pct exec` delegation through Proxmox hosts is not sufficient. Install openssh-server and deploy keys on all LXCs that Ansible will manage.

---

## 13. References

| Document | Purpose |
|----------|---------|
| `COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md` | Full Ansible design and implementation plan |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v5.md` | Current infrastructure state |
| `PHASE5B1_SESSION_TRANSITION.md` | Session transition record |
| `COLOSSUS_COREOS_VM_CREATION_RUNBOOK_v1.md` | CoreOS VM provisioning (Butane/Ignition) |
| [rpm-ostree apply-live docs](https://coreos.github.io/rpm-ostree/apply-live/) | Official apply-live architecture |
| [UniFi IDS/IPS](https://help.ui.com/hc/en-us/articles/360006893234) | UniFi Threat Management configuration |
