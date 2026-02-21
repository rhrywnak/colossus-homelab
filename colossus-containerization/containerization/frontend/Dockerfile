# ==============================================================================
# Colossus-Legal Frontend — Multi-Stage Dockerfile
# ==============================================================================
#
# Same multi-stage pattern as the backend, but for a different reason:
#
# Stage 1 ("builder"): Uses Node.js to run `npm install` and `vite build`.
#   Produces static files (HTML, JS, CSS) in a dist/ directory.
#
# Stage 2 ("runtime"): Uses nginx to serve those static files.
#   No Node.js in production — it's just a web server serving files.
#
# RUNTIME CONFIG INJECTION:
# Vite normally bakes VITE_API_URL into the JS bundle at build time, meaning
# you'd need separate builds for DEV and PROD. Instead, we use a pattern where:
#   1. Build with a placeholder API URL
#   2. At container startup, a script writes the real URL to config.js
#   3. The React app reads window.__COLOSSUS_CONFIG__ at runtime
#
# This means ONE image works in every environment. Ansible just sets the
# environment variable differently per deployment.
# ==============================================================================

# ── Stage 1: Build ──────────────────────────────────────────────────────────────
FROM docker.io/library/node:20-bookworm-slim AS builder

WORKDIR /build

# Same dependency-caching trick: copy package files first
COPY package.json package-lock.json ./

# Install dependencies (cached if package*.json unchanged)
RUN npm ci

# Copy source and build
COPY . .

# Build with a placeholder — the real URL is injected at runtime
ENV VITE_API_URL="__RUNTIME_CONFIG__"
RUN npm run build

# ── Stage 2: Runtime (nginx) ────────────────────────────────────────────────────
FROM docker.io/library/nginx:1.27-bookworm

# Copy the built static files to nginx's serve directory
COPY --from=builder /build/dist /usr/share/nginx/html

# Custom nginx config for SPA routing
# IMPORTANT: React Router uses client-side routing. Without this config,
# refreshing on /documents/123 would return 404 because nginx doesn't know
# about React routes. The try_files directive says "if the file doesn't exist,
# serve index.html and let React Router handle it."
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Runtime config injection script
# This runs at container startup, BEFORE nginx starts serving
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 5473

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:5473/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
