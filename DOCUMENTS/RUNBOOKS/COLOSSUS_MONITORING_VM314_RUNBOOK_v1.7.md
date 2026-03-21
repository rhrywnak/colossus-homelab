# COLOSSUS_MONITORING_VM314_RUNBOOK_v1.7

## Consolidated "Full Detail" Edition (v1.4 detail + v1.5/v1.6 expansions)

Project: Colossus Homelab\
Component: Monitoring Stack\
Deployment Model: Fedora CoreOS VM + Podman + Quadlet\
Primary Host: VM-314 (monitoring) --- 10.10.100.56\
Generated: 2026-02-15 15:10:39 UTC

------------------------------------------------------------------------

# 1. ADR --- Substrate Decision vs Original Design

## 1.1 Baseline design (unchanged architecture)

We keep the original monitoring **architecture**: - Central stack:
Prometheus + Loki + Grafana + PVE exporter (+ Alertmanager) - Fleet
agents: Grafana Alloy everywhere - UniFi syslog via UDP/514 (filtered) →
Loki - Traefik metrics scraped - Retention-based storage controls - PBS
backups and restore testing

## 1.2 Original substrate: Docker Compose inside LXC (CT-314)

**Pros** - Fastest time-to-first-dashboard (Compose) - Well-trodden
examples - Lightweight CT

**Cons / risks** - LXC nesting (`nesting=1`) + overlayfs/cgroups edge
cases - Debugging often becomes kernel/runtime-layer work - Weaker
isolation than VM for creds/tokens/logs - Introduces Docker runtime
while rest of lab standardizes on CoreOS + Podman - Operational drift
(networking/logging/update model differences)

## 1.3 Considered alternative: Docker Compose inside VM

**Pros**: removes LXC nesting issues, keeps Compose simplicity\
**Cons**: still introduces Docker divergence

## 1.4 Chosen substrate: CoreOS VM + Podman + systemd Quadlet

**Pros** - One container runtime across the lab (Podman) - VM isolation
boundary - No nested container-runtime hacks - systemd-managed lifecycle
(predictable) - Aligns with Colossus "repeatable CoreOS VM host"
doctrine

**Cons** - Up-front translation effort (Compose → Quadlet) - Need to
template/configure rather than paste Compose

Decision: For a foundational platform component (monitoring),
consistency and isolation beat short-term convenience.

------------------------------------------------------------------------

# 2. Target Architecture (VM-314)

VM-314 runs: - Grafana: TCP 3000 (via Traefik) - Prometheus: TCP 9090
(internal/admin only) - Loki: TCP 3100 (internal) - Alertmanager: TCP
9093 (internal) - PVE exporter: TCP 9221 (internal) - Alloy receiver:
UDP 514 (UniFi), HTTP 12346 (optional metrics/health)

Agents elsewhere: - Alloy agent metrics endpoint: TCP 12345 (example) -
Alloy sends logs to Loki `http://10.10.100.56:3100/loki/api/v1/push`

------------------------------------------------------------------------

# 3. Network / DNS / Firewall (execution detail)

## 3.1 DNS

-   `monitoring.cogmai.com` → 10.10.100.56
-   `grafana.cogmai.com` → Traefik entrypoint (preferred) or direct
    (less preferred)

## 3.2 Firewall policy (recommended)

Inbound to VM-314: - TCP 3000 from Traefik host(s) and/or LAN admin
subnet - TCP 3100 from Alloy agents subnets only - UDP 514 from UniFi
controller only - TCP 9090 optional, admin subnet only - TCP 9093
internal only - TCP 9221 internal only

Outbound from VM-314: - TCP 8006 to Proxmox nodes (PVE API) - DNS/NTP

------------------------------------------------------------------------

# 4. Storage layout + retention

Persistent paths (VM filesystem): - `/var/lib/monitoring/prometheus` -
`/var/lib/monitoring/loki` - `/var/lib/monitoring/grafana`

Configs: - `/etc/monitoring/...`

Start values: - Prometheus: 15s scrape, 30d retention, 10GB cap - Loki:
30d retention, filesystem backend

Disk recommendation: - 60GB+ (gives headroom for spikes, dashboards,
upgrades, mistakes)

------------------------------------------------------------------------

# 5. VM-314 Provisioning Checklist

## 5.1 Proxmox VM spec

-   VMID: 314
-   Name: monitoring
-   Node: pve-3
-   CPU: 2--4 cores
-   RAM: 4--8GB
-   Disk: 60GB
-   Bridge: vmbr0
-   IP: 10.10.100.56 (static)

## 5.2 CoreOS bootstrap

Use your standard CoreOS provisioning approach. Validate:

``` bash
hostnamectl
ip a
podman --version
systemctl --version
```

------------------------------------------------------------------------

# 6. Filesystem preparation (VM-314)

``` bash
sudo mkdir -p /etc/monitoring/{prometheus,loki,grafana/provisioning,datasources,dashboards,pve-exporter,alertmanager,alloy}
sudo mkdir -p /var/lib/monitoring/{prometheus,loki,grafana}
sudo mkdir -p /etc/containers/systemd
sudo install -m 600 -o root -g root /dev/null /etc/monitoring/secrets.env
```

Create secrets:

``` bash
sudo bash -c 'cat > /etc/monitoring/secrets.env <<EOF
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=CHANGE_ME_LONG_RANDOM
GF_SERVER_ROOT_URL=https://grafana.cogmai.com
GF_SERVER_DOMAIN=grafana.cogmai.com
EOF'
```

------------------------------------------------------------------------

# 7. Config files (complete)

## 7.1 Prometheus: /etc/monitoring/prometheus/prometheus.yml

``` yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['127.0.0.1:9093']

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['127.0.0.1:9090']

  - job_name: 'proxmox'
    metrics_path: /pve
    params:
      module: [default]
    static_configs:
      - targets:
          - '10.10.100.3'   # pve-1
          - '10.10.100.2'   # pve-2
          - '10.10.100.5'   # pve-3
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 10.10.100.56:9221

  - job_name: 'alloy-agents'
    static_configs:
      - targets:
          - '10.10.100.3:12345'
          - '10.10.100.2:12345'
          - '10.10.100.5:12345'
          - '10.10.100.110:12345'
          - '10.10.100.200:12345'
          - '10.10.100.120:12345'
          - '10.10.100.220:12345'

  - job_name: 'traefik'
    static_configs:
      - targets: ['10.10.100.XX:8082']  # set real metrics endpoint
```

## 7.2 Loki: /etc/monitoring/loki/loki-config.yml

``` yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  boltdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/cache
    shared_store: filesystem

compactor:
  working_directory: /loki/compactor
  shared_store: filesystem

limits_config:
  retention_period: 720h
  ingestion_rate_mb: 16
  ingestion_burst_size_mb: 32
```

Create Loki dirs:

``` bash
sudo mkdir -p /var/lib/monitoring/loki/{chunks,index,cache,compactor,rules}
```

## 7.3 Alloy receiver (UniFi syslog): /etc/monitoring/alloy/config.alloy

``` hcl
logging { level = "info" }

loki.write "default" {
  endpoint { url = "http://127.0.0.1:3100/loki/api/v1/push" }
}

loki.source.syslog "unifi" {
  listen_address = "0.0.0.0:514"
  protocol = "udp"
  labels = { source = "unifi" }
  forward_to = [loki.process.unifi_filter.receiver]
}

loki.process "unifi_filter" {
  stage.drop { expression = ".*(DHCP|ntp|mdns|stp).*" }
  stage.labels { values = { pipeline = "unifi" } }
  forward_to = [loki.write.default.receiver]
}
```

## 7.4 PVE exporter: /etc/monitoring/pve-exporter/pve.yml

``` yaml
default:
  user: "prometheus@pve"
  token_name: "monitoring"
  token_value: "PASTE_TOKEN_VALUE_HERE"
  verify_ssl: false
```

## 7.5 Alertmanager: /etc/monitoring/alertmanager/alertmanager.yml

``` yaml
route:
  receiver: 'default'

receivers:
  - name: 'default'
    # Add email/webhook later; keep silent until rules are tuned.
```

------------------------------------------------------------------------

# 8. Quadlet unit files (complete)

Place in `/etc/containers/systemd/`

## 8.1 prometheus.container

``` ini
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Container]
Image=prom/prometheus:latest
ContainerName=prometheus
PublishPort=9090:9090
Volume=/etc/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
Volume=/etc/monitoring/prometheus/rules:/etc/prometheus/rules:ro
Volume=/var/lib/monitoring/prometheus:/prometheus:Z
Exec=--config.file=/etc/prometheus/prometheus.yml
Exec=--storage.tsdb.path=/prometheus
Exec=--storage.tsdb.retention.time=30d
Exec=--storage.tsdb.retention.size=10GB
Exec=--web.enable-lifecycle

[Install]
WantedBy=multi-user.target
```

## 8.2 loki.container

``` ini
[Unit]
Description=Loki
Wants=network-online.target
After=network-online.target

[Container]
Image=grafana/loki:latest
ContainerName=loki
PublishPort=3100:3100
Volume=/etc/monitoring/loki/loki-config.yml:/etc/loki/config.yml:ro
Volume=/var/lib/monitoring/loki:/loki:Z
Exec=-config.file=/etc/loki/config.yml

[Install]
WantedBy=multi-user.target
```

## 8.3 grafana.container

``` ini
[Unit]
Description=Grafana
Wants=network-online.target
After=network-online.target

[Container]
Image=grafana/grafana:latest
ContainerName=grafana
PublishPort=3000:3000
Volume=/var/lib/monitoring/grafana:/var/lib/grafana:Z
Volume=/etc/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
EnvironmentFile=/etc/monitoring/secrets.env
Environment=GF_AUTH_ANONYMOUS_ENABLED=false
Environment=GF_USERS_ALLOW_SIGN_UP=false
Environment=GF_SECURITY_DISABLE_GRAVATAR=true
Environment=GF_SECURITY_COOKIE_SECURE=true

[Install]
WantedBy=multi-user.target
```

## 8.4 pve-exporter.container

``` ini
[Unit]
Description=Prometheus PVE Exporter
Wants=network-online.target
After=network-online.target

[Container]
Image=prompve/prometheus-pve-exporter:latest
ContainerName=pve-exporter
PublishPort=9221:9221
Volume=/etc/monitoring/pve-exporter/pve.yml:/etc/prometheus/pve.yml:ro

[Install]
WantedBy=multi-user.target
```

## 8.5 alertmanager.container

``` ini
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Container]
Image=prom/alertmanager:latest
ContainerName=alertmanager
PublishPort=9093:9093
Volume=/etc/monitoring/alertmanager:/etc/alertmanager:ro
Exec=--config.file=/etc/alertmanager/alertmanager.yml

[Install]
WantedBy=multi-user.target
```

## 8.6 alloy.container

``` ini
[Unit]
Description=Grafana Alloy (Syslog Receiver)
Wants=network-online.target
After=network-online.target

[Container]
Image=grafana/alloy:latest
ContainerName=alloy
PublishPort=514:514/udp
PublishPort=12346:12346
Volume=/etc/monitoring/alloy/config.alloy:/etc/alloy/config.alloy:ro
Exec=run --server.http.listen-addr=0.0.0.0:12346 --config.file=/etc/alloy/config.alloy

[Install]
WantedBy=multi-user.target
```

------------------------------------------------------------------------

# 9. Grafana provisioning (materialized files)

## 9.1 Datasource provisioning: /etc/monitoring/grafana/provisioning/datasources/datasources.yml

``` yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://127.0.0.1:3100
```

## 9.2 Dashboard provisioning: /etc/monitoring/grafana/provisioning/dashboards/dashboards.yml

``` yaml
apiVersion: 1
providers:
  - name: 'colossus'
    orgId: 1
    folder: 'Colossus'
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /etc/grafana/provisioning/dashboards
```

Day-1 dashboards to import (then export to JSON and store here): - Node
Exporter Full (1860) - Proxmox VE (10347) - Loki logs overview (13639) -
Traefik v2 (17346)

------------------------------------------------------------------------

# 10. Bring-up and validation

``` bash
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus.service loki.service grafana.service pve-exporter.service alertmanager.service alloy.service
podman ps
curl -fsS http://127.0.0.1:9090/-/healthy && echo OK
curl -fsS http://127.0.0.1:3100/ready && echo OK
```

Validate: - Prometheus targets: `http://10.10.100.56:9090/targets` -
Grafana: `http://10.10.100.56:3000` (or via Traefik) - Loki query in
Grafana Explore: `{source="unifi"}`

------------------------------------------------------------------------

# 11. Ansible pack (materialized skeleton)

inventory/hosts.ini, playbooks, and role skeletons are included in §12.
Use these as the starting point for your repo.

------------------------------------------------------------------------

# 12. Task-tracker worksheet, rollback matrix, capacity + DR

See §§13--16 in this document. Use them as execution artifacts.

------------------------------------------------------------------------

END OF DOCUMENT
