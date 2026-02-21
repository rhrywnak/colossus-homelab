# Colossus-Legal Containerization Guide

**Version:** 1.0  
**Date:** 2026-02-10  
**Purpose:** Build container images for DEV and PROD deployment

---

## Overview

This guide covers containerizing the Colossus-Legal application for deployment
to the Colossus homelab cluster. Both components produce lightweight, production-ready
container images using multi-stage builds.

| Component | Base Image | Final Size | Port |
|-----------|-----------|------------|------|
| Backend   | rust:1.84 → debian:bookworm-slim | ~100 MB | 3403 |
| Frontend  | node:20 → nginx:1.27 | ~50 MB | 5473 |

---

## File Placement

Copy these files into your `colossus-legal` repository:

```
colossus-legal/
├── backend/
│   ├── Dockerfile              ← NEW (from containerization/backend/)
│   ├── .dockerignore           ← NEW
│   ├── Cargo.toml
│   └── src/
├── frontend/
│   ├── Dockerfile              ← NEW (from containerization/frontend/)
│   ├── .dockerignore           ← NEW
│   ├── nginx.conf              ← NEW
│   ├── docker-entrypoint.sh    ← NEW
│   ├── package.json
│   └── src/
```

---

## Prerequisites

- **Podman** installed on your workstation (`sudo dnf install podman` or `sudo apt install podman`)
- **GitHub account** with a Personal Access Token (PAT) that has `write:packages` scope
- Neo4j running (DEV at 10.10.100.200:7687) for testing the backend container

---

## Step 1: One-Time React Code Change (Runtime Config)

The frontend currently reads the API URL at build time via `import.meta.env.VITE_API_URL`.
We need to change it to read from `window.__COLOSSUS_CONFIG__` at runtime so one image
works in every environment.

### 1a. Add config.js to index.html

Edit `frontend/index.html` and add this line in the `<head>`, BEFORE the Vite scripts:

```html
<script src="/config.js"></script>
```

### 1b. Create a config helper

Create `frontend/src/config.ts`:

```typescript
// Runtime configuration — injected by container entrypoint
// Falls back to VITE_API_URL for local development (npm run dev)

interface ColossusConfig {
  apiUrl: string;
}

declare global {
  interface Window {
    __COLOSSUS_CONFIG__?: ColossusConfig;
  }
}

export function getApiUrl(): string {
  // Container deployment: read from runtime config.js
  if (window.__COLOSSUS_CONFIG__?.apiUrl) {
    return window.__COLOSSUS_CONFIG__.apiUrl;
  }
  // Local development: fall back to Vite env var
  return import.meta.env.VITE_API_URL || "http://localhost:3403";
}
```

### 1c. Update service files

In each file under `frontend/src/services/`, replace hardcoded API URLs with:

```typescript
import { getApiUrl } from "../config";

const API_URL = getApiUrl();

// Then use API_URL in fetch calls:
const response = await fetch(`${API_URL}/claims`);
```

### 1d. Create a stub config.js for local dev

Create `frontend/public/config.js`:

```javascript
// Stub for local development (npm run dev)
// In production, the container entrypoint overwrites this file.
window.__COLOSSUS_CONFIG__ = {
  apiUrl: "http://localhost:3403"
};
```

### 1e. Test locally

```bash
cd frontend
npm run dev
# Verify the app still works at http://localhost:5473
```

---

## Step 2: Build Backend Image

```bash
cd ~/Projects/colossus-legal/backend

# Build the image (first build takes 5-10 min for dependency compilation)
podman build -t colossus-backend:v0.1.0 .

# Subsequent builds (source changes only) take ~1-2 min thanks to layer caching
```

### Test the backend image locally

```bash
# Run with your local Neo4j
podman run --rm -it \
  -e NEO4J_URI="bolt://10.10.100.200:7687" \
  -e NEO4J_USER="neo4j" \
  -e NEO4J_PASSWORD="your-password-here" \
  -e RUST_LOG="info" \
  -p 3403:3403 \
  colossus-backend:v0.1.0

# In another terminal, test the health endpoint
curl http://localhost:3403/health
# Expected: OK

curl http://localhost:3403/api/status
# Expected: {"app":"colossus-legal-backend","version":"0.1.0","status":"ok"}
```

---

## Step 3: Build Frontend Image

```bash
cd ~/Projects/colossus-legal/frontend

# Build the image
podman build -t colossus-frontend:v0.1.0 .
```

### Test the frontend image locally

```bash
# Run with API pointing to your local backend
podman run --rm -it \
  -e COLOSSUS_API_URL="http://localhost:3403" \
  -p 5473:5473 \
  colossus-frontend:v0.1.0

# Open http://localhost:5473 in your browser
```

---

## Step 4: Push to GitHub Container Registry

### One-time setup: Authenticate Podman with ghcr.io

```bash
# Create a PAT at https://github.com/settings/tokens
# Scope needed: write:packages

echo "YOUR_GITHUB_PAT" | podman login ghcr.io -u rhrywnak --password-stdin
```

### Tag and push

```bash
# Tag with your GitHub username
podman tag colossus-backend:v0.1.0 ghcr.io/rhrywnak/colossus-backend:v0.1.0
podman tag colossus-frontend:v0.1.0 ghcr.io/rhrywnak/colossus-frontend:v0.1.0

# Push
podman push ghcr.io/rhrywnak/colossus-backend:v0.1.0
podman push ghcr.io/rhrywnak/colossus-frontend:v0.1.0
```

### Also tag as "latest" for convenience

```bash
podman tag colossus-backend:v0.1.0 ghcr.io/rhrywnak/colossus-backend:latest
podman tag colossus-frontend:v0.1.0 ghcr.io/rhrywnak/colossus-frontend:latest
podman push ghcr.io/rhrywnak/colossus-backend:latest
podman push ghcr.io/rhrywnak/colossus-frontend:latest
```

---

## Step 5: Verify Images on ghcr.io

Visit: `https://github.com/rhrywnak?tab=packages`

You should see both packages listed. By default they're private. To make them
pullable from your CoreOS VMs, either:

- Make them public (simplest for a homelab), OR
- Configure Podman on the VMs with a ghcr.io login token (Ansible will handle this)

---

## Rust Learning: What Makes This Different

### Why multi-stage builds matter for Rust

With Python or Node, the "build" and "run" environments are the same — you need the
interpreter in both. With Rust, compilation produces a **native binary** that runs
directly on the OS. The compiler is only needed during build, so we throw it away.

This is one of Rust's deployment advantages: your production container is just
Linux + your binary. No runtime, no garbage collector, no dependency hell.

### The dependency caching trick

The Dockerfile copies `Cargo.toml` and `Cargo.lock` first, builds a dummy project
to compile all dependencies, then copies the real source. This exploits Docker's
layer caching — if your dependencies haven't changed, Docker skips recompiling
them entirely. Since Rust dependency compilation is the slow part (5-10 min),
this turns rebuilds from 10 minutes to 1-2 minutes.

### Why we use debian-slim instead of Alpine

Alpine Linux uses musl libc instead of glibc. While Rust can target musl for
fully static binaries, the `neo4rs` crate (Neo4j driver) depends on OpenSSL
which has known issues with musl. Debian-slim with glibc is the pragmatic choice
that avoids hours of debugging linker issues for ~30 MB more image size.

---

## Troubleshooting

**Build fails at cargo build:**  
Run `cargo build --release` locally in `backend/` first to catch any compilation
errors before trying the Docker build.

**Backend can't connect to Neo4j:**  
If running locally, use `--network host` instead of `-p 3403:3403` so the container
can reach Neo4j on the host network.

**Frontend shows blank page:**  
Check the browser console. If you see fetch errors to `__RUNTIME_CONFIG__`, the
config.js isn't being generated — verify `docker-entrypoint.sh` is executable
and `COLOSSUS_API_URL` is set.

**Push to ghcr.io fails with 403:**  
Your PAT needs the `write:packages` scope. Regenerate at github.com/settings/tokens.

---

## Next Steps

After images are built and pushed:
1. Create DEV and PROD app VMs (Ansible or manual via Butane/Ignition)
2. Deploy via Ansible: `ansible-playbook playbooks/deploy-app.yml -e version=v0.1.0 -l dev`
3. Validate: health checks, frontend loads, data flows from Neo4j
