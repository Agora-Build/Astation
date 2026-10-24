//! Registration proof and closed runtime routes until verified provisioning.
use axum::{
    extract::State,
    http::{header::CACHE_CONTROL, StatusCode},
    response::{IntoResponse, Response},
    routing::{any, get},
    Json, Router,
};
use serde_json::json;
use std::sync::Arc;

const DEFAULT_STATION: &str = "https://station.agora.build";
const CUSTOM_REQUIRED: &str = "Station AI needs your own Station. Register a custom relay in Portal (Stations > Add Station) and select it in Astation.";

struct Configuration {
    custom: bool,
    challenge: Option<String>,
}

impl Configuration {
    fn new(
        public_origin: Option<&str>,
        audience: Option<&str>,
        challenge: Option<&str>,
    ) -> Result<Self, &'static str> {
        let origin = public_origin.or(audience).unwrap_or(DEFAULT_STATION);
        if !crate::account_identity::station_origin(origin)
            || audience.is_some_and(|value| value != origin)
        {
            return Err("Station origin and OIDC audience must be the same exact origin");
        }
        if challenge.is_some_and(|s| {
            s.is_empty()
                || s.len() > 256
                || !s
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
        }) {
            return Err("Station registration challenge must be 1-256 base64url characters");
        }
        Ok(Self {
            custom: origin != DEFAULT_STATION,
            challenge: challenge.map(String::from),
        })
    }

    fn from_env() -> Self {
        let public = std::env::var("PUBLIC_BASE_URL").ok();
        let audience = std::env::var("ACCOUNT_OIDC_AUDIENCE").ok();
        let challenge = std::env::var("STATION_REGISTRATION_CHALLENGE").ok();
        Self::new(public.as_deref(), audience.as_deref(), challenge.as_deref()).unwrap_or_else(
            |error| {
                tracing::error!("Station registration disabled: {error}");
                Self {
                    custom: false,
                    challenge: None,
                }
            },
        )
    }
}

pub fn routes() -> Router<crate::AppState> {
    configured_routes(Configuration::from_env())
}

fn configured_routes(config: Configuration) -> Router<crate::AppState> {
    Router::new()
        .route("/.well-known/agora-build-station", get(proof))
        .route("/api/agent/v1", any(unavailable))
        .route("/api/agent/v1/*path", any(unavailable))
        .route("/mcp", any(unavailable))
        .route("/mcp/*path", any(unavailable))
        .route("/v1/chat/completions", any(unavailable))
        // The former session-ID-only voice bridge must not bypass Auth/R9.
        .route("/api/llm/chat", any(unavailable))
        .route("/api/voice-sessions", any(unavailable))
        .route("/api/voice-sessions/*path", any(unavailable))
        .with_state(Arc::new(config))
}

async fn proof(State(config): State<Arc<Configuration>>) -> Response {
    match config.challenge.as_ref().filter(|_| config.custom) {
        Some(challenge) => ([(CACHE_CONTROL, "no-store")], challenge.clone()).into_response(),
        None => (StatusCode::NOT_FOUND, [(CACHE_CONTROL, "no-store")]).into_response(),
    }
}

async fn unavailable(State(config): State<Arc<Configuration>>) -> Response {
    let (status, code, message) = if config.custom {
        (StatusCode::SERVICE_UNAVAILABLE, "station_ai_unavailable",
            "Station AI is not provisioned. Auth validation, native approval and runtime setup must complete before access is enabled.")
    } else {
        (
            StatusCode::FORBIDDEN,
            "custom_station_required",
            CUSTOM_REQUIRED,
        )
    };
    (
        status,
        [(CACHE_CONTROL, "no-store")],
        Json(json!({
            "error": {"code": code, "message": message},
            "admission_enabled": false
        })),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{to_bytes, Body},
        http::{Method, Request},
    };
    use tower::ServiceExt;

    #[tokio::test]
    async fn public_station_refuses_all_runtime_surfaces_regardless_of_claimed_identity() {
        for path in [
            "/api/agent/v1",
            "/api/agent/v1/sessions",
            "/mcp",
            "/mcp/tools",
            "/v1/chat/completions",
            "/api/llm/chat?session_id=claimed-session",
            "/api/voice-sessions",
            "/api/voice-sessions/claimed-session/trigger",
            "/api/voice-sessions/response",
        ] {
            for method in [Method::GET, Method::POST] {
                let app = configured_routes(Configuration::new(None, None, None).unwrap())
                    .with_state(crate::tests::test_state());
                let response = app
                    .oneshot(
                        Request::builder()
                            .method(method)
                            .uri(path)
                            .header("host", "custom.example")
                            .header("x-forwarded-host", "custom.example")
                            .header("authorization", "Bearer claimed-token")
                            .body(Body::from(r#"{"station":"custom.example","enabled":true}"#))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                assert_eq!(response.status(), StatusCode::FORBIDDEN);
                assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
                let body: serde_json::Value =
                    serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap())
                        .unwrap();
                assert_eq!(body["error"]["message"], CUSTOM_REQUIRED);
                assert_eq!(body["admission_enabled"], false);
            }
        }
    }

    #[tokio::test]
    async fn custom_origin_or_registration_proof_never_implicitly_activates_ai() {
        let app = configured_routes(
            Configuration::new(
                Some("https://custom.example"),
                Some("https://custom.example"),
                Some("public-control-challenge"),
            )
            .unwrap(),
        )
        .with_state(crate::tests::test_state());
        let proof = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/.well-known/agora-build-station")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(proof.status(), StatusCode::OK);
        assert_eq!(proof.headers()[CACHE_CONTROL], "no-store");
        assert_eq!(
            to_bytes(proof.into_body(), 4096).await.unwrap(),
            "public-control-challenge"
        );
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/agent/v1/sessions")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[tokio::test]
    async fn production_router_cannot_use_the_legacy_bridge_to_store_or_read_agent_content() {
        let state = crate::tests::test_state();
        state
            .voice_sessions
            .create(
                "private-session".into(),
                "private-host".into(),
                "private-channel".into(),
            )
            .await
            .unwrap();
        let app = crate::router(state.clone());
        for path in [
            "/api/llm/chat?session_id=private-session",
            "/api/voice-sessions/response",
        ] {
            let response = app.clone().oneshot(Request::builder().method(Method::POST).uri(path)
                .header("x-forwarded-for", "127.0.0.123")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"session_id":"private-session","response":"private reply","messages":[{"role":"user","content":"private prompt"}]}"#)).unwrap()).await.unwrap();
            assert!(matches!(
                response.status(),
                StatusCode::FORBIDDEN | StatusCode::SERVICE_UNAVAILABLE
            ));
            let bytes = to_bytes(response.into_body(), 4096).await.unwrap();
            let body = String::from_utf8(bytes.to_vec()).unwrap();
            assert!(
                !body.contains("private-session")
                    && !body.contains("private reply")
                    && !body.contains("private prompt")
            );
        }
        let session = state
            .voice_sessions
            .get("private-session")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(session.request_count, 0);
        assert!(session.get_accumulated_text().is_empty());
        assert!(session.response.is_none());
    }

    #[tokio::test]
    async fn registration_is_absent_by_default_and_cannot_be_advertised_by_the_public_relay() {
        for (origin, challenge) in [
            (None, None),
            (Some(DEFAULT_STATION), Some("public-proof")),
            (Some("https://custom.example"), None),
        ] {
            let app = configured_routes(Configuration::new(origin, None, challenge).unwrap())
                .with_state(crate::tests::test_state());
            let response = app
                .oneshot(
                    Request::builder()
                        .uri("/.well-known/agora-build-station")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NOT_FOUND);
        }
    }

    #[test]
    fn configuration_rejects_ambiguous_origins_and_unsafe_challenges() {
        for origin in [
            "https://custom.example/",
            "https://custom.example/path",
            "http://custom.example",
        ] {
            assert!(Configuration::new(Some(origin), None, None).is_err());
        }
        assert!(
            Configuration::new(Some("https://custom.example"), Some(DEFAULT_STATION), None)
                .is_err()
        );
        for challenge in ["", "line\nbreak", "<html>", &"x".repeat(257)] {
            assert!(
                Configuration::new(Some("https://custom.example"), None, Some(challenge)).is_err()
            );
        }
    }
}
