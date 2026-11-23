//! Account-private storage and opaque r9 routing. Endpoint authority stays on Atem.
use axum::{
    http::{header::CACHE_CONTROL, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    extract::{DefaultBodyLimit, State},
    Json, Router,
};
use serde_json::json;

use crate::AppState;

pub(crate) mod push_ack;
pub(crate) mod push_ingress;
pub(crate) mod recovery;
pub(crate) mod recovery_probe;
pub(crate) mod channels;
#[cfg(test)]
pub(crate) mod host_route_tests;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/capabilities", get(capabilities))
        .route("/channels", get(channels::connect))
        .route("/logs/:genesis/entries", get(recovery::entries).post(recovery::append))
        .route("/logs/:genesis/control", get(recovery::delegated_http::heads))
        .route("/logs/:genesis/control/recovery/signer-reports", axum::routing::post(recovery::delegated_http::signer_report))
        .route("/logs/:genesis/control/recovery/signer-challenges", axum::routing::post(recovery::delegated_http::signer_challenge))
        .route("/logs/:genesis/control/recovery", get(recovery::delegated_http::recovery_review))
        .route("/logs/:genesis/control/recovery/:plan/signatures", axum::routing::post(recovery::delegated_http::retain_recovery_copies))
        .route("/logs/:genesis/control/sync", axum::routing::post(recovery::delegated_http::sync))
        .route("/logs/:genesis/control/reservations", axum::routing::post(recovery::delegated_http::reserve))
        .route("/logs/:genesis/control/records", axum::routing::post(recovery::delegated_http::publish))
        .route("/logs/:genesis/control/status", axum::routing::post(recovery::delegated_http::status))
        .route("/logs/:genesis/verifiers", get(recovery::delegated_http::verifiers))
        .route("/logs/:genesis/verifier-reports", axum::routing::post(recovery::verifier_reports::create))
        .route("/logs/:genesis/verifier-requests", axum::routing::post(recovery::verifier_reports::inbox))
        .route("/logs/:genesis/verifier-reports/:nonce", get(recovery::verifier_reports::get)
            .post(recovery::verifier_reports::publish).delete(recovery::verifier_reports::close))
        .route("/logs/:genesis/backups/:version", get(recovery::backup).put(recovery::upload))
        .route("/logs/:genesis/probes/:host", axum::routing::post(recovery_probe::probe))
        .route("/logs/:genesis/device-enrollments/:id", get(recovery::device_enrollment::get)
            .put(recovery::device_enrollment::create).post(recovery::device_enrollment::publish)
            .delete(recovery::device_enrollment::cancel))
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
            "status": if state.recovery.is_durable() { "r9_transport_ready" } else { "not_ready" },
            "admission_enabled": state.recovery.is_durable(),
            "admission_authority": "host_signed_membership",
            "recovery_storage_durable": state.recovery.is_durable(),
            "recovery_head_probe": state.recovery.is_durable(),
            "required_session_revision": 9,
            "supported_session_revisions": [9],
            "transports": ["websocket"],
            "transport_implemented": true,
            "push_ready": false
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
                "message": "This remote API operation is not implemented. Use the encrypted r9 channels endpoint."
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
    async fn transport_readiness_still_reports_missing_durable_storage() {
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
        assert_eq!(value["supported_session_revisions"], json!([9]));
        assert_eq!(value["transports"], json!(["websocket"]));
        assert_eq!(value["admission_authority"], "host_signed_membership");
        assert_eq!(value["push_ready"], false);
    }

    #[tokio::test]
    async fn admission_routes_stay_closed_regardless_of_claimed_credentials() {
        for path in [
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
            (Method::GET, "backups/1"), (Method::PUT, "backups/1"), (Method::POST, "probes/host-a"),
            (Method::GET, "control/recovery"),
            (Method::POST, "control/recovery/165ec51c-9b59-433a-b43b-fbc6ca805db4/signatures")] {
            let response = app().oneshot(Request::builder().method(method)
                .uri(format!("/api/remote/v1/logs/{root}/{suffix}"))
                .body(Body::from("{}" )).unwrap()).await.unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
            assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        }
    }
}
