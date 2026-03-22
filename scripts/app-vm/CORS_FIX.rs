// ==============================================================================
// CORS Configuration Change for main.rs
// ==============================================================================
// Replace the existing CORS block in backend/src/main.rs with this version.
// It reads allowed origins from CORS_ALLOWED_ORIGINS env var (comma-separated),
// falling back to localhost defaults for local development.
//
// RUST LEARNING NOTE — HeaderValue::from_str vs from_static:
// from_static() takes a &'static str (compile-time string literal).
// from_str() takes a &str (runtime string). Since we're reading from an env
// var at startup, the values are runtime strings, so we need from_str().
// The .expect() call panics if the string contains invalid HTTP header chars —
// this is fine at startup since we want to fail fast on bad config.
// ==============================================================================

    // CORS — configurable via environment variable
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
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers(Any);
