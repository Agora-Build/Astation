//! Recovery storage is separate from the still-closed independent channel gate.
use axum::{
    http::{header::CACHE_CONTROL, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    extract::{DefaultBodyLimit, State},
    Json, Router,
};
use serde_json::json;

use crate::AppState;

// Transport preparation only. The authenticated, durable r9 push ingress is
// still gated below; it must supply shared-core identities after storage.
#[allow(dead_code)]
pub(crate) mod push_ack;
pub(crate) mod recovery;
pub(crate) mod recovery_probe;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/capabilities", get(capabilities))
        .route("/logs/:genesis/entries", get(recovery::entries).post(recovery::append))
        .route("/logs/:genesis/backups/:version", get(recovery::backup).put(recovery::upload))
        .route("/logs/:genesis/probes/:host", axum::routing::post(recovery_probe::probe))
        .layer(DefaultBodyLimit::max(262_144))
        .layer(axum::middleware::map_response(|mut response: Response| async move {
            response.headers_mut().insert(CACHE_CONTROL, axum::http::HeaderValue::from_static("no-store"));
            response
        }))
        .fallback(unavailable)
}

async fn capabilities(State(state): State<AppState>) -> Response {
    (
        [(CACHE_CONTROL, "no-store")],
        Json(json!({
            "api": "atem-remote",
            "version": 1,
            "status": "not_ready",
            "admission_enabled": false,
            "recovery_storage_durable": state.recovery.is_durable(),
            "recovery_head_probe": state.recovery.is_durable(),
            "required_session_revision": 9,
            "supported_session_revisions": [],
            "transports": [],
            "blocked_by": [
                "r9_contract_conformance",
                "shared_client_core",
                "membership_admission"
            ]
        })),
    )
        .into_response()
}

async fn unavailable() -> Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        [(CACHE_CONTROL, "no-store")],
        Json(json!({
            "error": {
                "code": "remote_api_unavailable",
                "message": "Independent agent access is awaiting verified membership and encrypted channels."
            },
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

    fn app() -> Router {
        Router::new()
            .nest("/api/remote/v1", routes())
            .with_state(crate::tests::test_state())
    }

    #[tokio::test]
    async fn readiness_cannot_be_mistaken_for_implemented_r9_admission() {
        let response = app()
            .oneshot(
                Request::builder()
                    .uri("/api/remote/v1/capabilities")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        let bytes = to_bytes(response.into_body(), 4096).await.unwrap();
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["status"], "not_ready");
        assert_eq!(value["admission_enabled"], false);
        assert_eq!(value["required_session_revision"], 9);
        assert_eq!(value["supported_session_revisions"], json!([]));
        assert_eq!(value["transports"], json!([]));
        assert!(!value["blocked_by"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn admission_routes_stay_closed_regardless_of_claimed_credentials() {
        for path in [
            "channels",
            "enrollments",
            "hosts",
            "events",
        ] {
            for method in [Method::GET, Method::POST] {
                let response = app()
                    .oneshot(
                        Request::builder()
                            .method(method)
                            .uri(format!("/api/remote/v1/{path}"))
                            .header("authorization", "Bearer local-or-account-token")
                            .body(Body::from(r#"{"device_id":"manager","verified":true}"#))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
                assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
                let bytes = to_bytes(response.into_body(), 4096).await.unwrap();
                let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                assert_eq!(value["error"]["code"], "remote_api_unavailable");
                assert_eq!(value["admission_enabled"], false);
            }
        }
    }

    #[tokio::test]
    async fn recovery_routes_require_login_before_reading_records() {
        let root = "a".repeat(64);
        for (method, suffix) in [(Method::GET, "entries"), (Method::POST, "entries"),
            (Method::GET, "backups/1"), (Method::PUT, "backups/1"), (Method::POST, "probes/host-a")] {
            let response = app().oneshot(Request::builder().method(method)
                .uri(format!("/api/remote/v1/logs/{root}/{suffix}"))
                .body(Body::from("{}" )).unwrap()).await.unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
            assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        }
    }
}
