//! Typed hosted APIs stay closed until the joint Auth/native/host release gate.
use crate::station_integrations::{error, IntegrationState};
use axum::{
    http::StatusCode,
    response::Response,
    routing::{get, post},
    Router,
};

mod admission;
pub(crate) mod client;
mod operations;

#[cfg(test)]
mod tests;

// Deliberately not an environment switch. Enable only after recorded live E2E.
pub(crate) const HOSTED_EXECUTION_ENABLED: bool = false;

pub(crate) fn routes() -> Router<IntegrationState> {
    operation_routes().layer(axum::middleware::from_fn(release_gate))
}

fn operation_routes() -> Router<IntegrationState> {
    Router::new()
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/sessions",
            get(operations::sessions),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/events",
            get(operations::events),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/sessions/:session/history",
            post(operations::history),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/sessions/:session/prompts",
            post(operations::prompt),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/sessions/:session/interrupt",
            post(operations::interrupt),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/sessions/:session/stop",
            post(operations::stop),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/sessions/:session/approvals",
            get(operations::approvals).post(operations::approval),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/sessions/:session/approval-seen",
            post(operations::seen),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/sessions/:session/rules/revoke",
            post(operations::revoke),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/sessions/:session/receipts",
            post(operations::receipts),
        )
}

async fn release_gate(request: axum::extract::Request, next: axum::middleware::Next) -> Response {
    if HOSTED_EXECUTION_ENABLED {
        return next.run(request).await;
    }
    let custom = std::env::var("PUBLIC_BASE_URL")
        .is_ok_and(|v| crate::account_identity::custom_station_origin(&v));
    error(
        if custom {
            StatusCode::SERVICE_UNAVAILABLE
        } else {
            StatusCode::FORBIDDEN
        },
        if custom {
            "hosted_execution_not_verified"
        } else {
            "custom_station_required"
        },
    )
}

fn invalid() -> Response {
    error(StatusCode::BAD_REQUEST, "invalid_agent_request")
}
fn lost() -> Response {
    error(StatusCode::SERVICE_UNAVAILABLE, "host_connection_lost")
}
fn stale() -> Response {
    error(StatusCode::CONFLICT, "stale_target")
}
