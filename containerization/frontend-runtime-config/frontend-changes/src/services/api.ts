// =============================================================================
// API Configuration — Runtime Config with Local Dev Fallback
// =============================================================================
//
// RUST PARALLEL: This is similar to how your Rust backend reads config from
// environment variables at startup (AppConfig::from_env). The frontend equivalent
// is reading from window.__COLOSSUS_CONFIG__ which gets injected at container
// startup, or falling back to VITE_API_URL for local development.
//
// WHY RUNTIME CONFIG?
// Vite normally bakes VITE_API_URL into the JS bundle at build time. That means
// you'd need separate docker builds for DEV and PROD. With runtime config,
// ONE image works everywhere — the container entrypoint writes config.js with
// the correct API URL before nginx starts serving.
//
// RESOLUTION ORDER:
// 1. window.__COLOSSUS_CONFIG__.apiUrl  (container deployment)
// 2. import.meta.env.VITE_API_URL       (npm run dev)
// 3. "http://localhost:3403"             (bare fallback)
// =============================================================================

export type StatusResponse = {
    app: string;
    version: string;
    status: string;
};

// TypeScript: Extend the Window interface to include our runtime config.
// The 'declare global' block tells TypeScript "this property might exist on window"
// without actually creating it — the container entrypoint creates it at runtime.
declare global {
    interface Window {
        __COLOSSUS_CONFIG__?: {
            apiUrl: string;
        };
    }
}

// Single source of truth for the API base URL.
// Every service file imports this — no other files need to change.
export const API_BASE_URL: string =
    window.__COLOSSUS_CONFIG__?.apiUrl
    || import.meta.env.VITE_API_URL
    || "http://localhost:3403";

export async function getStatus(): Promise<StatusResponse> {
    const response = await fetch(`${API_BASE_URL}/api/status`);

    if (!response.ok) {
        throw new Error(`Status request failed with ${response.status}`);
    }

    let data: unknown;
    try {
        data = await response.json();
    } catch (error) {
        throw new Error("Failed to parse status response");
    }

    const parsed = data as Partial<StatusResponse>;
    if (!parsed.app || !parsed.version || !parsed.status) {
        throw new Error("Invalid status response shape");
    }

    return {
        app: parsed.app,
        version: parsed.version,
        status: parsed.status,
    };
}
