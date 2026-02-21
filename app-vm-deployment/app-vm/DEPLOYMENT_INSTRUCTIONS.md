# Phase 4A — Application VM Deployment Instructions

## Overview

Deploy Colossus-Legal to a CoreOS VM on pve-2 (DEV environment).

| Component | Detail |
|-----------|--------|
| VM | 220 — colossus-dev-app1 |
| Node | pve-2 |
| IP | 10.10.100.220 |
| Backend | ghcr.io/rhrywnak/colossus-backend:v0.1.0 → port 3403 |
| Frontend | ghcr.io/rhrywnak/colossus-frontend:v0.1.0 → port 5473 |
| DB target | 10.10.100.200 (DEV Neo4j on VM-210) |

---

## Step 0: CORS Fix (on workstation, before building images)

The backend currently hardcodes CORS origins. We need it to read from an
environment variable so the containerized frontend can reach it.

**Edit** `backend/src/main.rs` — replace this block:

```rust
    // CORS (dev-friendly; you can tighten this later)
    let cors = CorsLayer::new()
        .allow_origin([
            HeaderValue::from_static("http://localhost:5473"),
            HeaderValue::from_static("http://localhost:3403"),
            HeaderValue::from_static("http://10.10.0.99:5473"),
        ])
```

**With** this:

```rust
    // CORS — configurable via CORS_ALLOWED_ORIGINS env var (comma-separated)
    // Falls back to localhost defaults for local development.
    //
    // RUST NOTE — from_static vs from_str:
    // from_static() requires a &'static str (compile-time literal).
    // from_str() accepts a &str (runtime string from env var).
    // We use from_str() here because the origins come from configuration.
    let cors_origins: Vec<HeaderValue> = std::env::var("CORS_ALLOWED_ORIGINS")
        .unwrap_or_else(|_| {
            "http://localhost:5473,http://localhost:3403,http://10.10.0.99:5473".to_string()
        })
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .map(|s| {
            HeaderValue::from_str(&s)
                .unwrap_or_else(|_| panic!("Invalid CORS origin: {}", s))
        })
        .collect();

    let cors = CorsLayer::new()
        .allow_origin(cors_origins)
```

The rest of the CORS block (`.allow_methods`, `.allow_headers`) stays the same.

**Test locally:**

```bash
cd ~/Projects/colossus-legal/backend
cargo run
# Should work exactly as before (falls back to localhost origins)
```

**Rebuild and push the backend image:**

```bash
cd ~/Projects/colossus-legal/backend
podman build -t colossus-backend:v0.1.0 .
podman tag colossus-backend:v0.1.0 ghcr.io/rhrywnak/colossus-backend:v0.1.0
podman push ghcr.io/rhrywnak/colossus-backend:v0.1.0
# Also update latest
podman tag colossus-backend:v0.1.0 ghcr.io/rhrywnak/colossus-backend:latest
podman push ghcr.io/rhrywnak/colossus-backend:latest
```

**Commit:**

```bash
git add backend/src/main.rs
git commit -m "feat: make CORS origins configurable via CORS_ALLOWED_ORIGINS env var"
```

---

## Step 1: Prepare Ignition on workstation

**Edit the Butane file** (`colossus-dev-app1.bu`):

1. Replace the SSH key placeholder with your actual public key
2. Replace `NEO4J_PASSWORD=CHANGEME_USE_ANSIBLE_VAULT` with your DEV Neo4j password

**Transpile to Ignition:**

```bash
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < colossus-dev-app1.bu > colossus-dev-app1.ign
```

If you get errors, fix them — `--strict` rejects anything that would produce a broken config.

---

## Step 2: Deploy Ignition to pve-2

```bash
# Ensure the snippets directory exists
ssh root@pve-2 'mkdir -p /var/coreos/snippets'

# Copy the Ignition file
scp colossus-dev-app1.ign root@pve-2:/var/coreos/snippets/
```

---

## Step 3: Create and start the VM

```bash
# Copy the creation script to pve-2
scp create-vm-220.sh root@pve-2:/root/

# Run it
ssh root@pve-2 'bash /root/create-vm-220.sh'
```

---

## Step 4: Wait for first boot

The VM will:
1. Boot CoreOS, apply Ignition config (~30 seconds)
2. Install Python via rpm-ostree (~1-2 minutes)
3. **Reboot automatically** (Python install requires reboot)
4. Pull container images from ghcr.io (~1-2 minutes)
5. Start both containers

**Total wait: ~3-5 minutes**

Watch progress:

```bash
# Serial console (if SSH isn't up yet)
ssh root@pve-2 'qm terminal 220'
# Ctrl+O to exit serial console

# Or wait for SSH
ssh core@10.10.100.220
```

---

## Step 5: Verify

```bash
bash verify-app-vm.sh
```

Or manually:

```bash
# Containers running?
ssh core@10.10.100.220 'sudo podman ps'

# Backend healthy?
curl http://10.10.100.220:3403/health
curl http://10.10.100.220:3403/api/status

# Frontend serving?
curl -s -o /dev/null -w "%{http_code}" http://10.10.100.220:5473/

# Open in browser
open http://10.10.100.220:5473
```

---

## Troubleshooting

**Containers not starting:**
```bash
ssh core@10.10.100.220 'sudo systemctl status colossus-backend'
ssh core@10.10.100.220 'sudo podman logs colossus-backend'
```

**Image pull failed:**
```bash
ssh core@10.10.100.220 'sudo podman pull ghcr.io/rhrywnak/colossus-backend:v0.1.0'
```
If images are private, you need auth.json — uncomment that section in the Butane file.

**Backend can't reach Neo4j:**
```bash
# From inside the VM
ssh core@10.10.100.220 'curl -sf http://10.10.100.200:7474 || echo "Neo4j unreachable"'
```

**CORS errors in browser console:**
```bash
ssh core@10.10.100.220 'sudo podman logs colossus-backend' | grep -i cors
```
Check that CORS_ALLOWED_ORIGINS in backend.env includes the frontend URL.

---

## After DEV is verified

We'll create VM-120 (PROD) on pve-1 using the same pattern with PROD-specific:
- IP: 10.10.100.120
- DB target: 10.10.100.110 (PROD Neo4j)
- RUST_LOG: warn (instead of debug)
- Separate Neo4j password
