// Runtime configuration stub for local development (npm run dev).
// In container deployments, docker-entrypoint.sh overwrites this file
// with the real API URL from the COLOSSUS_API_URL environment variable.
window.__COLOSSUS_CONFIG__ = {
  apiUrl: "http://localhost:3403"
};
