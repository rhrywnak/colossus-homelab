# Colossus Homelab Proxmox Cluster & Storage Architecture
**Version:** v1.1  
**Date:** 2026-02-02  

---

## 11. CoreOS as the Standard Service VM Host

### Was CoreOS the correct choice?
Yes. For your goals—immutability, reproducibility, container-first workflows, and long-lived stability—**Fedora CoreOS is the right choice**.

You are intentionally optimizing for:
- predictable VM behavior
- declarative configuration
- minimal configuration drift
- container-native workloads

Those map directly to CoreOS’s strengths.

Trade-offs you are consciously accepting:
- less interactive “SSH tweaking”
- stronger discipline around externalized data
- systemd-based container management instead of ad-hoc shells

Given your background and architecture, this is a **professional-grade decision**, not a hobbyist one.

---

## 12. CoreOS Golden Template Strategy

### Single golden image
You maintain **one CoreOS VM template** and clone it for:
- dev DB VMs
- prod DB VMs
- app service VMs

Role differences are expressed via:
- attached storage
- Ignition config
- systemd unit definitions

---

## 13. Creating the CoreOS Template (Proxmox)

### Initial creation (one-time)

```bash
qm create 9000   --name coreos-template   --memory 8192   --cores 4   --net0 virtio,bridge=vmbr0   --bios ovmf   --machine q35   --scsi0 local-lvm:32   --scsihw virtio-scsi-single   --boot order=scsi0
```

Install Fedora CoreOS from ISO.

### Convert to template

```bash
qm template 9000
```

---

## 14. CoreOS Container Model

Containers are **systemd-managed Podman services**, not ad-hoc shells.

### Standard layout inside the VM

```
/mnt/data/
  postgres/data
  neo4j/data
  neo4j/logs
  qdrant/storage

/etc/containers/env/
  postgres.env
  neo4j.env
  qdrant.env
```

---

## 15. CoreOS Container Unit Templates

### Postgres

```ini
[Unit]
Description=Postgres
After=network-online.target

[Service]
EnvironmentFile=/etc/containers/env/postgres.env
ExecStart=/usr/bin/podman run \
  --rm \
  --name postgres \
  -p 5432:5432 \
  -v /mnt/data/postgres/data:/var/lib/postgresql/data \
  postgres:16
Restart=always

[Install]
WantedBy=multi-user.target
```

### Neo4j

```ini
[Unit]
Description=Neo4j
After=network-online.target

[Service]
EnvironmentFile=/etc/containers/env/neo4j.env
ExecStart=/usr/bin/podman run \
  --rm \
  --name neo4j \
  -p 7474:7474 -p 7687:7687 \
  -v /mnt/data/neo4j/data:/data \
  -v /mnt/data/neo4j/logs:/logs \
  neo4j:5
Restart=always

[Install]
WantedBy=multi-user.target
```

---

## 16. Reproducible VM Creation Flow

1) Clone template:
```bash
qm clone 9000 210 --name dev-db-coreos
```

2) Attach persistent storage (virtiofs preferred):
```bash
qm set 210 --virtiofs0 /dev-zfs/db-neo4j,mountpoint=/mnt/data/neo4j
```

3) Apply Ignition
4) Boot VM
5) Containers auto-start

---

## 17. Backup Implications

- PBS backs up VM disk + attached datasets
- Container images are disposable
- Data lives in Proxmox-managed storage
- Restore = restore VM + data → services restart

---

## 18. Status

You now have:
- a consistent CoreOS VM model
- deterministic container startup
- externalized persistent data
- clean backup semantics

Next document:
**v1.2 – VM 200 Externalization Runbook (step-by-step)**

