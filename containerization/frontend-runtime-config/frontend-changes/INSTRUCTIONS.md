# Containerization — Step-by-Step Instructions

## Part 1: Frontend Code Changes (3 files)

These changes let ONE container image work in every environment (DEV, PROD).

### 1. Replace `frontend/src/services/api.ts`

Copy `src/services/api.ts` from this package over your existing file.

What changed: `API_BASE_URL` now checks `window.__COLOSSUS_CONFIG__` first
(set by container entrypoint), then falls back to `VITE_API_URL` (local dev).

No other service files need to change — they all import `API_BASE_URL` from api.ts.

### 2. Replace `frontend/index.html`

Copy `index.html` from this package over your existing file.

What changed: Added `<script src="/config.js"></script>` in the `<head>`.

### 3. Create `frontend/public/config.js`

Copy `public/config.js` into your `frontend/public/` directory.

This is the local dev stub. In containers, docker-entrypoint.sh overwrites it.

### Test locally

```bash
cd ~/Projects/colossus-legal/frontend
npm run dev
# App should work exactly as before at http://localhost:5473
```

---

## Part 2: Add Container Files (from earlier colossus-containerization.zip)

Copy these files from the containerization zip into your repo:

```bash
# From the earlier colossus-containerization.zip:
cp containerization/backend/Dockerfile      ~/Projects/colossus-legal/backend/Dockerfile
cp containerization/backend/.dockerignore   ~/Projects/colossus-legal/backend/.dockerignore
cp containerization/frontend/Dockerfile     ~/Projects/colossus-legal/frontend/Dockerfile
cp containerization/frontend/.dockerignore  ~/Projects/colossus-legal/frontend/.dockerignore
cp containerization/frontend/nginx.conf     ~/Projects/colossus-legal/frontend/nginx.conf
cp containerization/frontend/docker-entrypoint.sh ~/Projects/colossus-legal/frontend/docker-entrypoint.sh
```

---

## Part 3: Build Images

### Backend

```bash
cd ~/Projects/colossus-legal/backend
podman build -t colossus-backend:v0.1.0 .

# Test it (needs Neo4j running)
podman run --rm -it \
  -e NEO4J_URI="bolt://10.10.100.200:7687" \
  -e NEO4J_USER="neo4j" \
  -e NEO4J_PASSWORD="your-password" \
  -e RUST_LOG="info" \
  -p 3403:3403 \
  colossus-backend:v0.1.0
```

### Frontend

```bash
cd ~/Projects/colossus-legal/frontend
podman build -t colossus-frontend:v0.1.0 .

# Test it
podman run --rm -it \
  -e COLOSSUS_API_URL="http://localhost:3403" \
  -p 5473:5473 \
  colossus-frontend:v0.1.0
```

---

## Part 4: Push to ghcr.io

```bash
# One-time login
echo "YOUR_GITHUB_PAT" | podman login ghcr.io -u rhrywnak --password-stdin

# Tag and push
podman tag colossus-backend:v0.1.0 ghcr.io/rhrywnak/colossus-backend:v0.1.0
podman tag colossus-frontend:v0.1.0 ghcr.io/rhrywnak/colossus-frontend:v0.1.0
podman push ghcr.io/rhrywnak/colossus-backend:v0.1.0
podman push ghcr.io/rhrywnak/colossus-frontend:v0.1.0
```
