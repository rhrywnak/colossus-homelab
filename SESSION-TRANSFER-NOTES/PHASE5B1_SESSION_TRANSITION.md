# Phase 5B-1 Session Transition — Ansible Foundation Complete

**Date:** 2026-02-14  
**Phase:** 5B-1 — Ansible Foundation  
**Status:** ✅ COMPLETE  
**Next Phase:** 5B-2 — Codify Existing Infrastructure as Ansible Roles  
**Previous Transition:** PHASE5B_TRUENAS_SESSION_TRANSITION.md  

---

## 1. What Was Accomplished

### Phase 5B-1: Ansible Foundation — All 7 Steps Complete

| Step | Task | Status |
|------|------|--------|
| 1 | Ansible installed on workstation (2.16.3) | ✅ Pre-existing |
| 2 | proxmoxer Python library installed (2.2.0) | ✅ |
| 3 | community.general collection installed | ✅ Pre-existing |
| 4 | Inventory created with all 11 hosts | ✅ |
| 5 | ansible.cfg configured | ✅ |
| 6 | Ansible Vault created with secrets | ✅ |
| 7 | Facts playbook validates all hosts | ✅ 11/11 |

### Additional Work Completed (Not in Original Plan)

| Task | Detail |
|------|--------|
| SSH keys deployed to pve-2, pve-3, PBS | Key auth was missing on 3 hosts |
| SSH server enabled on CT-311, CT-312, CT-313 | LXC containers had no SSH access |
| SSH keys deployed to all 3 LXC containers | Via `pct exec` through pve-3 |
| Python3 + libselinux-python3 on CoreOS DB VMs | `rpm-ostree install --apply-live` on VM-110, VM-210 |
| SSH multiplexing configured | `~/.ssh/config` for 10.10.100.* subnet |
| UniFi IPS detection exclusions added | 10.10.100.0/24 and 10.10.0.0/24 |
| Ansible forks tuned | Set to 10 (initially 3 during troubleshooting) |

---

## 2. Current State of Infrastructure

### 2.1 Ansible Control Node

- **Host:** proxima-centauri (Roman's workstation)
- **Project directory:** `~/colossus-ansible/`
- **Ansible version:** 2.16.3
- **Vault password:** `~/.vault_pass` (auto-decrypt enabled)

### 2.2 Managed Hosts — All 10 Responding

```
ansible all --limit '!truenas' -m ping  →  10/10 SUCCESS
ansible-playbook playbooks/gather-facts.yml  →  11/11 ok, changed=0
```

| Host | IP | User | OS | Group |
|------|----|------|-----|-------|
| pve-1 | 10.10.100.3 | root | Debian 13.3 | proxmox |
| pve-2 | 10.10.100.2 | root | Debian 13.3 | proxmox |
| pve-3 | 10.10.100.5 | root | Debian 13.3 | proxmox |
| colossus-prod-db1 | 10.10.100.110 | core | Fedora 43 | coreos_vms.db_vms |
| colossus-dev-db1 | 10.10.100.200 | core | Fedora 43 | coreos_vms.db_vms |
| colossus-prod-app1 | 10.10.100.120 | core | Fedora 43 | coreos_vms.app_vms |
| colossus-dev-app1 | 10.10.100.220 | core | Fedora 43 | coreos_vms.app_vms |
| pihole | 10.10.100.53 | root | Debian 12 | infrastructure |
| cloudflared | 10.10.100.54 | root | Debian 12 | infrastructure |
| traefik | 10.10.100.55 | root | Debian 12 | infrastructure |
| pbs | 10.10.100.242 | root | Proxmox BS | backup |

**Unmanaged:** TrueNAS (10.10.0.38) — SSH disabled, in inventory but excluded from playbooks.

### 2.3 Network Changes

- **SSH multiplexing:** `~/.ssh/config` has `Host 10.10.100.*` block with ControlMaster/ControlPersist
- **UniFi IPS:** Detection exclusions for 10.10.100.0/24 and 10.10.0.0/24 added to CyberSecure → Protection

### 2.4 CoreOS VM Changes

- **VM-110, VM-210:** `python3` and `libselinux-python3` layered via `rpm-ostree --apply-live`
- **VM-120, VM-220:** Already had Python3 from original Butane provisioning

### 2.5 LXC Container Changes

- **CT-311, CT-312, CT-313:** SSH server (`ssh.service`) enabled and running; root authorized_keys deployed

---

## 3. Files Created/Modified

### New Files

| File | Location | Purpose |
|------|----------|---------|
| `ansible.cfg` | `~/colossus-ansible/` | Ansible configuration |
| `inventory/hosts.yml` | `~/colossus-ansible/` | Host inventory (11 hosts) |
| `inventory/group_vars/coreos_vms.yml` | `~/colossus-ansible/` | CoreOS connection settings |
| `inventory/group_vars/infrastructure.yml` | `~/colossus-ansible/` | LXC connection settings |
| `secrets/vault.yml` | `~/colossus-ansible/` | Encrypted credentials |
| `playbooks/gather-facts.yml` | `~/colossus-ansible/` | Validation playbook |
| `~/.vault_pass` | Home directory | Vault auto-decrypt |
| `COLOSSUS_ANSIBLE_FOUNDATION_RUNBOOK_v1.md` | Project docs | This phase's runbook |

### Modified Files

| File | Change |
|------|--------|
| `~/.ssh/config` | Added `Host 10.10.100.*` multiplexing block |
| `inventory/group_vars/all.yml` | Appended network vars + `ansible_user: root` default |
| CT-311/312/313 `/root/.ssh/authorized_keys` | Added workstation SSH public key |
| CT-311/312/313 `ssh.service` | Enabled and started |
| VM-110/210 ostree deployment | `python3` + `libselinux-python3` layered |

### UniFi Controller Changes

| Setting | Change |
|---------|--------|
| CyberSecure → Protection → Detection Exclusions | Added 10.10.100.0/24 |
| CyberSecure → Protection → Detection Exclusions | Added 10.10.0.0/24 |

---

## 4. Known Issues

| Issue | Status | Detail |
|-------|--------|--------|
| TrueNAS SSH disabled | Deferred | Listed in inventory as unmanaged; manage via web UI |
| 10.10.0.99 hitting pihole and prod-app1 | Uninvestigated | Appeared in IPS logs; identify this device |
| community.general version warning | Cosmetic | `Collection community.general does not support Ansible version 2.16.3` — works fine |

---

## 5. Next Phase: 5B-2 — Codify Existing Infrastructure

### 5.1 Goal

Convert existing manual processes into Ansible roles. Don't deploy anything new — just make the current state reproducible.

### 5.2 Roles to Create

| Role | Codifies | Priority |
|------|----------|----------|
| `traefik-route` | Adding routers/services to Traefik dynamic config | High — most frequently needed |
| `pihole-dns` | Adding DNS records to Pi-hole | High — needed for every new app |
| `coreos-app` | Deploying Quadlet containers + env files to CoreOS | High — core deployment |
| `pbs-backup` | Creating PBS backup jobs | Medium |
| `proxmox-vm` | Creating CoreOS VMs via qm | Medium |
| `proxmox-lxc` | Creating LXC containers | Medium |

### 5.3 Approach

Start with `traefik-route` and `pihole-dns` since they affect running services and can be validated immediately against live state. These are the roles needed most frequently when deploying new applications.

### 5.4 Success Criteria for 5B-2

1. All 6 roles created with tasks, defaults, and templates
2. Running each role against current infrastructure produces `changed=0` (current state matches)
3. Each role is idempotent (run twice → no changes)
4. Each role supports `--check --diff` (dry-run capability)

---

## 6. Documents to Update

| Document | Update Needed |
|----------|--------------|
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v5.md` | Add Phase 5B-1 completion, Ansible section, IPS exclusions |
| `COLOSSUS_COREOS_VM_CREATION_RUNBOOK_v1.md` | Add Python3 installation step for Ansible compatibility |
| `COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md` | Mark Phase 5B-1 steps as ✅ COMPLETE |

---

## 7. Key Learnings for Future Sessions

1. **Always check UniFi IPS** when diagnosing intermittent network issues between VLANs
2. **group_vars go inside `inventory/`** — not at the project root
3. **CoreOS Python:** `rpm-ostree install python3 libselinux-python3 --apply-live` is the canonical approach
4. **LXC containers need SSH explicitly set up** — it's not enabled by default
5. **SSH multiplexing** is essential for Ansible managing 10+ hosts through a consumer router
6. **Debian uses `ssh` not `sshd`** as the service name
