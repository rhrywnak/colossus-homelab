# COLOSSUS — Ansible Runbook Addendum: alloy-agent Role (Phase 6A-2)

**Date:** 2026-02-16
**Applies to:** `COLOSSUS_ANSIBLE_RUNBOOK_v2.md` — Section 9 (Role Reference)
**Purpose:** Documentation for the `alloy-agent` role added during Phase 6A-2

---

## Role: alloy-agent

### Overview

**What it manages:** Installation and configuration of Grafana Alloy agents on all managed hosts. Alloy is a unified observability agent that replaces both node_exporter (metrics) and Promtail (logs) in a single binary/container.

**What each agent does:**
1. Exposes host-level metrics (CPU, RAM, disk, network) on port 12345 for Prometheus to scrape
2. Ships journald logs to the central Loki instance on VM-314 (10.10.100.56:3100)

**How it works:** The role detects the host type from Ansible group membership and routes to the appropriate install path:
- Hosts in the `coreos_vms` group → Podman container via Quadlet unit
- All other hosts → APT package with systemd service

### File Structure

```
roles/alloy-agent/
├── defaults/main.yml           # Shared defaults (Loki URL, port 12345, image tag)
├── handlers/main.yml           # Restart handlers (systemd native vs podman quadlet)
├── tasks/
│   ├── main.yml                # Entry point — sets alloy_containerized, routes to install task
│   ├── install-apt.yml         # Debian/Proxmox: GPG key → repo → apt install → config → systemd
│   └── install-podman.yml      # CoreOS: config → Quadlet .container unit → image pull → systemd
└── templates/
    ├── config.alloy.j2         # Alloy River/HCL config — shared, with containerized conditionals
    └── alloy.container.j2      # Podman Quadlet unit — CoreOS only
```

### Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `alloy_loki_url` | `http://10.10.100.56:3100/loki/api/v1/push` | Central Loki push endpoint |
| `alloy_listen_port` | `12345` | HTTP port for Prometheus scraping and UI |
| `alloy_image` | `docker.io/grafana/alloy:v1.6.1` | Container image (CoreOS only) |
| `alloy_config_dir_apt` | `/etc/alloy` | Config location for APT installs |
| `alloy_config_dir_podman` | `/etc/alloy` | Config location for Podman installs |
| `alloy_journal_max_age` | `24h` | Max age of journal entries to ship on first start |
| `alloy_containerized` | Auto-detected | Set by `main.yml` from group membership — do not override |

### Playbook

```bash
# Deploy to all hosts (default)
ansible-playbook playbooks/deploy-alloy.yml

# Deploy to a specific wave (by group)
ansible-playbook playbooks/deploy-alloy.yml -l infrastructure
ansible-playbook playbooks/deploy-alloy.yml -l proxmox
ansible-playbook playbooks/deploy-alloy.yml -l coreos_vms

# Deploy to a single host (for testing)
ansible-playbook playbooks/deploy-alloy.yml -l pihole

# Dry run (note: APT install will fail in check mode if repo not yet added — this is expected)
ansible-playbook playbooks/deploy-alloy.yml --check --diff
```

**Playbook target:** `all:!truenas:!monitoring`
- Excludes TrueNAS (SSH disabled) and monitoring VM (runs its own Alloy via Butane/Ignition)

### APT Install Path (Debian/Proxmox/LXC/PBS)

Tasks in order:
1. Install `gpg` package (needed for key dearmoring)
2. Download Grafana GPG key from `https://apt.grafana.com/gpg.key`
3. Dearmor key to `/usr/share/keyrings/grafana.gpg`
4. Add Grafana APT repository (`deb [signed-by=...] https://apt.grafana.com stable main`)
5. Install `alloy` package
6. Template config to `/etc/alloy/config.alloy`
7. Write `/etc/default/alloy` with `--server.http.listen-addr=0.0.0.0:12345` (critical: default binds to 127.0.0.1)
8. Enable and start `alloy.service`
9. Wait for readiness check (`http://127.0.0.1:12345/-/ready`)

**Important:** The `/etc/default/alloy` environment file override is required because the APT package's systemd service defaults to listening on `127.0.0.1:12345`, which is unreachable from Prometheus on VM-314.

### Podman Quadlet Path (CoreOS VMs)

Tasks in order:
1. Create `/etc/alloy` config directory
2. Template config to `/etc/alloy/config.alloy`
3. Deploy Quadlet `.container` unit to `/etc/containers/systemd/alloy.container`
4. Pre-pull container image (avoids first-start timeout)
5. Reload systemd (detects Quadlet unit)
6. Enable and start `alloy.service`
7. Wait for readiness check

**Critical Quadlet settings for CoreOS:**

```ini
User=0                        # Run as root — required for journal access
SecurityLabelDisable=true     # Disable SELinux label confinement — required on CoreOS
```

**Bind mounts:**

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `/etc/alloy/config.alloy` | `/etc/alloy/config.alloy` | Alloy config (ro,Z) |
| `/var/log/journal` | `/var/log/journal` | Journal access for log shipping (ro) |
| `/proc` | `/host/proc` | Host process info for metrics (ro) |
| `/sys` | `/host/sys` | Host sysfs for metrics (ro) |
| `/` | `/host/root` | Host filesystem for disk metrics (ro,rslave) |

### Config Template Details

The `config.alloy.j2` template generates Alloy River/HCL configuration. Key sections:

**Metrics collection:**
- `prometheus.exporter.unix "host"` — built-in node_exporter equivalent
- On CoreOS (containerized): uses `/host/proc`, `/host/sys`, `/host/root` paths
- On Debian (native): uses default system paths

**Log shipping:**
- `loki.source.journal "journal"` — reads systemd journal
- `max_age = "24h"` — prevents backfill flood on first start
- Labels: `job="systemd-journal"`, `host="{{ inventory_hostname }}"`

**Log relabeling:**
- `loki.relabel "journal"` — promotes `__journal__systemd_unit` → `unit`, `__journal__priority_keyword` → `priority`, `__journal__transport` → `transport`

**Log destination:**
- `loki.write "default"` — pushes to central Loki at `{{ alloy_loki_url }}`

### Validation

The playbook includes two validation steps:
1. **Role-level:** `uri` module checks `http://127.0.0.1:12345/-/ready` (5 retries, 3s delay)
2. **Playbook-level:** `uri` module checks `http://{{ ansible_host }}:12345/metrics` from localhost (verifies external reachability)

### Known Issues

| Issue | Impact | Notes |
|-------|--------|-------|
| `--check` mode fails on first APT repo+install | APT repo not actually added in check mode | Expected — test live on single host instead |
| "Module invocation had junk after JSON data" warnings on CoreOS | Cosmetic only | Caused by Python version/locale on CoreOS |
| Proxmox enterprise repo must be disabled | `apt update` fails with 401 if enterprise repo enabled without subscription | Ensure `Enabled: no` in `pve-enterprise.sources` / `pbs-enterprise.sources` |
| daemon-reload can timeout on CoreOS | If previous alloy units were in failed state | `systemctl reset-failed alloy.service` before `daemon-reload` |

### Idempotency

The role is idempotent — running it multiple times on the same host will:
- Skip GPG key download if already present
- Skip package install if already installed
- Update config only if template content changed
- Restart service only if config or Quadlet unit changed (via handlers)

### Uninstall

Not automated. Manual removal:

**APT hosts:**
```bash
sudo systemctl stop alloy
sudo apt remove alloy
sudo rm /etc/apt/sources.list.d/grafana.list
sudo rm /usr/share/keyrings/grafana.gpg
```

**CoreOS hosts:**
```bash
sudo systemctl stop alloy
sudo rm /etc/containers/systemd/alloy.container
sudo rm -rf /etc/alloy
sudo systemctl daemon-reload
sudo podman rmi docker.io/grafana/alloy:v1.6.1
```
