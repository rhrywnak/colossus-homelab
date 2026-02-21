# Proxmox NIC Swap Runbook — Moving vmbr0 to a New Interface

**Version:** v1.0  
**Date:** 2026-02-13  
**Scope:** Any Proxmox node — swapping the physical NIC behind vmbr0  
**Requires:** Monitor + keyboard on the node (SSH won't work mid-swap)

---

## Prerequisites

- New NIC physically installed and cabled to the switch
- Monitor and keyboard attached to the Proxmox node
- Know the current bridge-ports interface name

---

## Procedure

### 1. Identify the new interface name

```bash
ip link show
```

Look for the new interface(s) — they'll be in state `DOWN` with no `master vmbr0`. Note the name (e.g., `enp15s0f0`).

### 2. Edit network config

```bash
nano /etc/network/interfaces
```

Find the `vmbr0` block:

```
auto vmbr0
iface vmbr0 inet static
    address 10.10.100.X/24
    gateway 10.10.100.1
    bridge-ports <old-interface>
    bridge-stp off
    bridge-fd 0
```

Change `bridge-ports` from the old interface to the new one:

```
    bridge-ports <new-interface>
```

### 3. Apply

```bash
ifreload -a
```

### 4. Verify

```bash
ping 10.10.100.1
```

If ping works, SSH is back. Confirm from your workstation:

```bash
ssh root@10.10.100.X
```

### 5. Verify VMs/CTs are healthy

```bash
qm list
pct list
pvesm status
```

---

## Rollback

If the new NIC doesn't work, edit `/etc/network/interfaces` back to the old interface name and run `ifreload -a` again. This is why you need the monitor + keyboard — if networking breaks, SSH is unavailable.

---

## pve-3 Reference (2026-02-13)

Swapped from failing onboard `nic0` to I350-T2 `enp15s0f0`.

| Interface | Card | Speed | Role |
|-----------|------|-------|------|
| enp15s0f0 | I350-T2 | 1GbE | Active — vmbr0 |
| enp15s0f1 | I350-T2 | 1GbE | Spare |
| enp13s0 | 10GbE | 10GbE | Future (needs SFP+ cable) |
| enp14s0 | 10GbE | 10GbE | Future (needs SFP+ cable) |
| nic0 | Onboard | 1GbE | Failing — do not use |
| nic1 | Onboard | 1GbE | Unknown condition |
