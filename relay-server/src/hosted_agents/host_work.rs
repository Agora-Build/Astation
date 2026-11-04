//! Online host-work adapters. Stable caller identities recover outcomes; these
//! routes never retry launch or publish requests after an ambiguous transport loss.
use super::{client::HostedConnection, invalid, lost, stale};
use crate::station_integrations::{error, IntegrationState};
use atem_client::session::{
    host_work::{HostTarget, Request as WorkRequest},
    messages::{Destination, Message as AgentMessage},
    new_id,
};
use axum::{
    extract::{DefaultBodyLimit, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::json;

pub(super) fn routes() -> Router<IntegrationState> {
    Router::new()
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/profiles",
            get(profiles),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/launches",
            post(launch),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/launches/:request",
            post(launch_query),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/messages",
            post(publish),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/messages/:message",
            post(message_query),
        )
        .route(
            "/api/agent/v1/integrations/:id/hosts/:host/tasks/:task",
            post(work_query),
        )
        .layer(DefaultBodyLimit::max(262_144))
        .layer(axum::middleware::from_fn(gate))
}

async fn gate(request: axum::extract::Request, next: axum::middleware::Next) -> Response {
    if cfg!(feature = "host-work-api") {
        next.run(request).await
    } else {
        error(StatusCode::SERVICE_UNAVAILABLE, "host_work_not_verified")
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Launch {
    host: HostTarget,
    request_id: String,
    profile_id: String,
    profile_revision: u64,
    expires_at: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Publish {
    host: HostTarget,
    message: AgentMessage,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Query {
    host: HostTarget,
}

#[derive(Clone, Copy)]
enum Operation {
    Profiles,
    Launch,
    LaunchQuery,
    Publish,
    MessageQuery,
    WorkQuery,
}

// Auth #14 / Portal #25 confirmed these scopes. The separate build gate
// remains off until participating verifiers and live acceptance are ready.
impl Operation {
    fn scope(self) -> &'static str {
        match self {
            Self::Profiles | Self::Launch | Self::LaunchQuery => "agent.launch",
            Self::Publish | Self::MessageQuery => "agent.message",
            Self::WorkQuery => "agent.notify",
        }
    }
}

async fn profiles(
    State(state): State<IntegrationState>,
    Path((id, host)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    execute(state.0, id, host, headers, Operation::Profiles, None)
        .await
        .unwrap_or_else(|e| e)
}

async fn launch(
    State(state): State<IntegrationState>,
    Path((id, host)): Path<(String, String)>,
    headers: HeaderMap,
    Json(call): Json<Launch>,
) -> Response {
    let request = WorkRequest::Launch {
        v: 1,
        id: new_id(),
        host: call.host,
        request_id: call.request_id,
        profile_id: call.profile_id,
        profile_revision: call.profile_revision,
        expires_at: call.expires_at,
    };
    execute(state.0, id, host, headers, Operation::Launch, Some(request))
        .await
        .unwrap_or_else(|e| e)
}

async fn publish(
    State(state): State<IntegrationState>,
    Path((id, host)): Path<(String, String)>,
    headers: HeaderMap,
    Json(call): Json<Publish>,
) -> Response {
    let request = WorkRequest::Publish {
        v: 1,
        id: new_id(),
        host: call.host,
        message: call.message,
    };
    execute(
        state.0,
        id,
        host,
        headers,
        Operation::Publish,
        Some(request),
    )
    .await
    .unwrap_or_else(|e| e)
}

macro_rules! query {
    ($handler:ident, $operation:ident, $request:ident, $field:ident) => {
        async fn $handler(
            State(state): State<IntegrationState>,
            Path((id, host, identity)): Path<(String, String, String)>,
            headers: HeaderMap,
            Json(call): Json<Query>,
        ) -> Response {
            let request = WorkRequest::$request {
                v: 1,
                id: new_id(),
                host: call.host,
                $field: identity,
            };
            execute(
                state.0,
                id,
                host,
                headers,
                Operation::$operation,
                Some(request),
            )
            .await
            .unwrap_or_else(|e| e)
        }
    };
}
query!(launch_query, LaunchQuery, LaunchQuery, request_id);
query!(message_query, MessageQuery, MessageQuery, message_id);
query!(work_query, WorkQuery, WorkQuery, task_id);

async fn execute(
    state: Option<std::sync::Arc<crate::station_integrations::StationIntegrations>>,
    integration: String,
    host_id: String,
    headers: HeaderMap,
    operation: Operation,
    request: Option<WorkRequest>,
) -> Result<Response, Response> {
    let runtime = state.ok_or_else(lost)?;
    let _permit = runtime
        .requests
        .try_acquire()
        .map_err(|_| error(StatusCode::TOO_MANY_REQUESTS, "integration_busy"))?;
    if let Some(request) = &request {
        WorkRequest::from_data(&request.to_json()["data"]).map_err(|_| invalid())?;
        if request.host().atem_device_id != host_id {
            return Err(stale());
        }
    }
    let mut admission = runtime
        .admit(&integration, &headers, operation.scope())
        .await?;
    if matches!(operation, Operation::WorkQuery) {
        admission
            .additional_operations
            .extend(["agent.message", "agent.prompt"]);
        runtime.recheck(&admission).await?;
    }
    // An executable recipient additionally needs both token permissions. The
    // host independently enforces message/notify/prompt membership and route consent.
    if let Some(WorkRequest::Publish { message, .. }) = &request {
        if message.sender != format!("service:{}", admission.context.service_id) {
            return Err(error(StatusCode::FORBIDDEN, "invalid_message_sender"));
        }
        // Immutable context publication and PNG upload use their dedicated
        // authorized paths; this first generic adapter accepts inline messages.
        if !message.context.is_empty() || message.mark.is_some() {
            return Err(error(
                StatusCode::BAD_REQUEST,
                "context_publication_not_supported",
            ));
        }
        if message
            .recipients
            .iter()
            .any(|r| matches!(r.destination, Destination::Agent { .. }))
        {
            admission
                .additional_operations
                .extend(["agent.notify", "agent.prompt"]);
            runtime.recheck(&admission).await?;
        }
    }
    let mut connection = HostedConnection::open(
        &runtime,
        &admission.context,
        &admission.token.service_fingerprint,
        &host_id,
    )
    .await?;
    let welcome = connection.attached.welcome();
    let host = HostTarget {
        account_id: welcome.account_id.clone(),
        atem_device_id: welcome.atem_device_id.clone(),
        host_trust_gen: welcome.host_trust_gen,
    };
    let request = request.unwrap_or_else(|| WorkRequest::Profiles {
        v: 1,
        id: new_id(),
        host: host.clone(),
    });
    if request.host() != &host {
        return Err(stale());
    }
    connection.recheck(&runtime, &admission).await?;
    let frame = connection
        .attached
        .send(&request.to_json(), connection.now())
        .map_err(|_| invalid())?;
    connection.send(frame).await?;
    let events = connection
        .until(|v| v["type"] == "session" && v["data"]["re"] == request.id())
        .await?;
    connection.recheck(&runtime, &admission).await?;
    let event = events
        .into_iter()
        .find(|v| v["type"] == "session" && v["data"]["re"] == request.id())
        .ok_or_else(lost)?;
    if event["data"]["op"] == "error" {
        let code = event["data"]["code"]
            .as_str()
            .unwrap_or("invalid_agent_request");
        return Err(error(
            match code {
                "forbidden" | "unauthorized" => StatusCode::FORBIDDEN,
                "busy" => StatusCode::SERVICE_UNAVAILABLE,
                "request_id_reused" | "stale_target" => StatusCode::CONFLICT,
                _ => StatusCode::BAD_REQUEST,
            },
            code,
        ));
    }
    let response =
        atem_client::session::host_work::Response::from_data(&event["data"]).map_err(|_| lost())?;
    if !response.answers(&request) {
        return Err(lost());
    }
    Ok(Json(json!({"host": response.host, "result": response.result})).into_response())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request};
    use serde_json::Value;
    use tower::ServiceExt;

    #[tokio::test]
    async fn routes_remain_disabled_in_an_existing_hosted_build() {
        let router = routes().with_state(IntegrationState(None));
        for (method, path, body) in [
            ("GET", "profiles", Value::Null),
            (
                "POST",
                "launches",
                json!({"host":{"account_id":"account","atem_device_id":"host","host_trust_gen":1},
                "request_id":new_id(),"profile_id":"backend","profile_revision":1,"expires_at":100}),
            ),
            (
                "POST",
                "messages/not-a-message",
                json!({"host":{"account_id":"account","atem_device_id":"host","host_trust_gen":1}}),
            ),
        ] {
            let response = router
                .clone()
                .oneshot(
                    Request::builder()
                        .method(method)
                        .uri(format!("/api/agent/v1/integrations/test/hosts/host/{path}"))
                        .header("content-type", "application/json")
                        .body(Body::from(body.to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
            let bytes = axum::body::to_bytes(response.into_body(), 4096)
                .await
                .unwrap();
            let value: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(
                value["error"]["code"],
                if cfg!(feature = "host-work-api") {
                    "host_connection_lost"
                } else {
                    "host_work_not_verified"
                }
            );
        }
    }

    #[test]
    fn shared_request_vectors_run_through_the_actual_sdk() {
        let vectors: Value = serde_json::from_str(include_str!(
            "../../../native-remote/Tests/AstationRemoteTests/Fixtures/host-work-requests-v1.json"
        ))
        .unwrap();
        for case in vectors["cases"].as_array().unwrap() {
            let raw = case["raw"]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| case["message"].to_string());
            assert_eq!(
                WorkRequest::decode(raw.as_bytes()).is_ok(),
                case["valid"].as_bool().unwrap(),
                "{}",
                case["name"]
            );
        }
    }

    #[test]
    fn http_launch_rejects_commands_paths_environment_and_unrelated_fields() {
        let valid = json!({"host":{"account_id":"account","atem_device_id":"host","host_trust_gen":1},
            "request_id":new_id(),"profile_id":"approved","profile_revision":1,"expires_at":1_793_620_860_000_u64});
        assert!(serde_json::from_value::<Launch>(valid.clone()).is_ok());
        for field in ["command", "cwd", "args", "env", "takeover", "text"] {
            let mut bad = valid.clone();
            bad[field] = json!("unapproved");
            assert!(serde_json::from_value::<Launch>(bad).is_err(), "{field}");
        }
    }

    #[test]
    fn prompt_scope_never_implies_launch_and_notice_scope_never_implies_execution() {
        assert_eq!(Operation::Launch.scope(), "agent.launch");
        assert_eq!(Operation::Profiles.scope(), "agent.launch");
        assert_eq!(Operation::Publish.scope(), "agent.message");
        assert_eq!(Operation::WorkQuery.scope(), "agent.notify");
    }
}
