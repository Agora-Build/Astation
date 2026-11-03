//! Typed hosted APIs require an approved build and current integration authority.
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
mod host_work;

#[cfg(test)]
mod live;
#[cfg(test)]
mod tests;

// Runtime configuration cannot enable an unapproved build.
pub(crate) const HOSTED_EXECUTION_ENABLED: bool = cfg!(feature = "hosted-agent-api");

pub(crate) fn routes() -> Router<IntegrationState> {
    operation_routes().layer(axum::middleware::from_fn(release_gate))
}

fn operation_routes() -> Router<IntegrationState> {
    Router::new()
        .merge(host_work::routes())
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
    let origin = std::env::var("PUBLIC_BASE_URL")
        .unwrap_or_else(|_| crate::account_identity::BUILT_IN_STATION_ORIGIN.into());
    let configured = crate::account_identity::integration_station_origin(&origin);
    error(
        if configured {
            StatusCode::SERVICE_UNAVAILABLE
        } else {
            StatusCode::FORBIDDEN
        },
        if configured {
            "hosted_execution_not_verified"
        } else {
            "invalid_station_configuration"
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
