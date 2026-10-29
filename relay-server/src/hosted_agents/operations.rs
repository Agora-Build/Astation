use super::{admission::Admission, client::HostedConnection, invalid, lost, stale};
use crate::station_integrations::{error, IntegrationState, StationIntegrations};
use atem_client::session::{
    new_id,
    wire::{self, Envelope, Op, ReceiptKind, Target},
};
use axum::{
    extract::{
        ws::{Message, WebSocket},
        Path, State, WebSocketUpgrade,
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Call {
    target: Target,
    request_id: Option<String>,
    text: Option<String>,
    approval: Option<Value>,
    rule_id: Option<String>,
    approval_id: Option<String>,
    request_ids: Option<Vec<String>>,
    take_control: Option<bool>,
    takeover: Option<bool>,
    expected_controller: Option<wire::Controller>,
    before: Option<String>,
    next: Option<String>,
    turn_id: Option<String>,
}
#[derive(Clone, Copy)]
pub(super) enum Operation {
    History,
    Prompt,
    Interrupt,
    Stop,
    Approval,
    Seen,
    Revoke,
    Receipts,
}
impl Operation {
    fn scope(self) -> &'static str {
        match self {
            Self::Prompt => "agent.prompt",
            Self::Interrupt | Self::Stop => "agent.interrupt",
            Self::Approval | Self::Seen | Self::Revoke => "agent.approve",
            _ => "agent.view",
        }
    }
}

pub(super) async fn sessions(
    State(IntegrationState(runtime)): State<IntegrationState>,
    Path((id, host)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    let Some(runtime) = runtime else {
        return lost();
    };
    let result = async {
        let _permit = runtime
            .requests
            .try_acquire()
            .map_err(|_| error(StatusCode::TOO_MANY_REQUESTS, "integration_busy"))?;
        let admission = runtime.admit(&id, &headers, "agent.view").await?;
        let connection = HostedConnection::open(
            &runtime,
            &admission.context,
            &admission.token.service_fingerprint,
            &host,
        )
        .await?;
        connection.recheck(&runtime, &admission).await?;
        Ok::<_, Response>(
            Json(
                json!({"sessions":connection.attached.registry().sessions().collect::<Vec<_>>(),"targets":connection.attached.registry().sessions().filter_map(|s|connection.attached.target(&s.session_id)).collect::<Vec<_>>(),
            "approvals":connection.attached.registry().pending_approvals().collect::<Vec<_>>(),
            "approval_rules":connection.initial_rules}),
            )
            .into_response(),
        )
    }
    .await;
    result.unwrap_or_else(|e| e)
}

pub(super) async fn approvals(
    State(IntegrationState(runtime)): State<IntegrationState>,
    Path((id, host, session)): Path<(String, String, String)>,
    headers: HeaderMap,
) -> Response {
    let Some(runtime) = runtime else {
        return lost();
    };
    let result = async {
        let _permit = runtime
            .requests
            .try_acquire()
            .map_err(|_| error(StatusCode::TOO_MANY_REQUESTS, "integration_busy"))?;
        let admission = runtime.admit(&id, &headers, "agent.approve").await?;
        let connection = HostedConnection::open(
            &runtime,
            &admission.context,
            &admission.token.service_fingerprint,
            &host,
        )
        .await?;
        if connection.attached.target(&session).is_none() {
            return Err(stale());
        }
        connection.recheck(&runtime, &admission).await?;
        Ok::<_, Response>(
            Json(json!({
                "target": connection.attached.target(&session),
                "approval_rules": connection.initial_rules.iter().filter(|v|v["session_id"] == session).collect::<Vec<_>>(),
                "approvals": connection.attached.registry().pending_approvals()
                    .filter(|a| a.session_id == session).collect::<Vec<_>>()
            }))
            .into_response(),
        )
    }
    .await;
    result.unwrap_or_else(|e| e)
}

macro_rules! handler {
    ($name:ident,$op:ident) => {
        pub(super) async fn $name(
            State(IntegrationState(runtime)): State<IntegrationState>,
            Path((id, host, session)): Path<(String, String, String)>,
            headers: HeaderMap,
            Json(call): Json<Call>,
        ) -> Response {
            match runtime {
                Some(runtime) => execute(runtime, id, host, session, headers, call, Operation::$op)
                    .await
                    .unwrap_or_else(|e| e),
                None => lost(),
            }
        }
    };
}
handler!(history, History);
handler!(prompt, Prompt);
handler!(interrupt, Interrupt);
handler!(stop, Stop);
handler!(approval, Approval);
handler!(seen, Seen);
handler!(revoke, Revoke);
handler!(receipts, Receipts);

async fn execute(
    runtime: Arc<StationIntegrations>,
    id: String,
    host: String,
    session: String,
    headers: HeaderMap,
    call: Call,
    operation: Operation,
) -> Result<Response, Response> {
    let _permit = runtime
        .requests
        .try_acquire()
        .map_err(|_| error(StatusCode::TOO_MANY_REQUESTS, "integration_busy"))?;
    validate_call(&call, operation)?;
    let admission = runtime.admit(&id, &headers, operation.scope()).await?;
    let mut connection = HostedConnection::open(
        &runtime,
        &admission.context,
        &admission.token.service_fingerprint,
        &host,
    )
    .await?;
    connection.target(&call.target, &session)?;
    connection.recheck(&runtime, &admission).await?;
    let reply = perform(&mut connection, &call, operation, &runtime, &admission).await?;
    connection.recheck(&runtime, &admission).await?;
    Ok(Json(json!({"events":reply})).into_response())
}

fn validate_call(call: &Call, operation: Operation) -> Result<(), Response> {
    // Refuse misplaced fields instead of silently ignoring caller intent.
    let history = matches!(operation, Operation::History);
    let prompt = matches!(operation, Operation::Prompt);
    let control = matches!(operation, Operation::Interrupt | Operation::Stop);
    if (call.text.is_some() && !prompt)
        || (call.approval.is_some() && !matches!(operation, Operation::Approval))
        || (call.rule_id.is_some() && !matches!(operation, Operation::Revoke))
        || (call.approval_id.is_some() && !matches!(operation, Operation::Seen))
        || (call.request_ids.is_some() && !matches!(operation, Operation::Receipts))
        || (call.take_control.is_some() && !control)
        || ((call.takeover.is_some() || call.expected_controller.is_some()) && !prompt)
        || ((call.before.is_some() || call.next.is_some() || call.turn_id.is_some()) && !history)
        || (call.request_id.is_some() && matches!(operation, Operation::Seen | Operation::Receipts))
        || (control && call.take_control != Some(true))
    {
        return Err(invalid());
    }
    if matches!(
        operation,
        Operation::Prompt
            | Operation::Interrupt
            | Operation::Stop
            | Operation::Approval
            | Operation::Revoke
    ) && !call.request_id.as_deref().is_some_and(wire::is_uuid_v4)
    {
        return Err(invalid());
    }
    if matches!(operation, Operation::Prompt)
        && !call
            .text
            .as_ref()
            .is_some_and(|t| !t.is_empty() && t.len() <= 65_536)
    {
        return Err(invalid());
    }
    if call.takeover == Some(true) && call.expected_controller.is_none() {
        return Err(invalid());
    }
    if call.takeover != Some(true) && call.expected_controller.is_some() {
        return Err(invalid());
    }
    if matches!(
        operation,
        Operation::Approval | Operation::Seen | Operation::Revoke
    ) && (call.take_control.is_some()
        || call.takeover.is_some()
        || call.expected_controller.is_some())
    {
        return Err(invalid());
    }
    if matches!(operation, Operation::Seen)
        && !call.approval_id.as_deref().is_some_and(wire::is_uuid_v4)
    {
        return Err(invalid());
    }
    if matches!(operation, Operation::Revoke)
        && !call.rule_id.as_deref().is_some_and(wire::is_opaque_id)
    {
        return Err(invalid());
    }
    if matches!(operation, Operation::Approval)
        && !call
            .approval
            .as_ref()
            .is_some_and(|v| wire::ApprovalAnswer::parse(v).is_ok())
    {
        return Err(invalid());
    }
    if matches!(operation, Operation::Receipts)
        && !call.request_ids.as_ref().is_some_and(|ids| {
            !ids.is_empty() && ids.len() <= 64 && ids.iter().all(|s| wire::is_uuid_v4(s))
        })
    {
        return Err(invalid());
    }
    if matches!(operation, Operation::History) {
        if [
            call.before.as_ref(),
            call.next.as_ref(),
            call.turn_id.as_ref(),
            call.request_id.as_ref(),
        ]
        .into_iter()
        .flatten()
        .count()
            > 1
            || call
                .before
                .as_deref()
                .is_some_and(|s| !wire::is_opaque_id(s))
            || call
                .turn_id
                .as_deref()
                .is_some_and(|s| !wire::is_opaque_id(s))
            || call
                .request_id
                .as_deref()
                .is_some_and(|s| !wire::is_uuid_v4(s))
            || call.next.as_ref().is_some_and(|s| {
                s.is_empty() || s.len() > 2048 || !s.bytes().all(|b| b.is_ascii_graphic())
            })
        {
            return Err(invalid());
        }
    }
    Ok(())
}

async fn send_checked(
    connection: &HostedConnection,
    runtime: &StationIntegrations,
    admission: &Admission,
    frame: Vec<u8>,
) -> Result<(), Response> {
    connection.recheck(runtime, admission).await?;
    connection.send(frame).await
}

pub(super) async fn perform(
    connection: &mut HostedConnection,
    call: &Call,
    operation: Operation,
    runtime: &StationIntegrations,
    admission: &Admission,
) -> Result<Vec<Value>, Response> {
    let session = &call.target.session_id;
    if matches!(operation, Operation::History) {
        let conversation = new_id();
        connection.attached.chat_mut().open(&conversation, session);
        let binding = connection
            .attached
            .binding(session, connection.now())
            .ok_or_else(stale)?;
        let open = json!({"type":"agentChat","data":{"v":1,"op":"open","conversationId":conversation,"agentId":session,"binding":binding}});
        let frame = connection
            .attached
            .send(&open, connection.now())
            .map_err(|_| invalid())?;
        send_checked(connection, runtime, admission, frame).await?;
        let mut output = connection
            .until(|v| history_done(v) && v["data"]["conversationId"] == conversation)
            .await?;
        if call.before.is_some()
            || call.next.is_some()
            || call.turn_id.is_some()
            || call.request_id.is_some()
        {
            let generation = output
                .iter()
                .find_map(|v| v["data"]["generation"].as_str())
                .ok_or_else(stale)?
                .to_owned();
            let page_id = new_id();
            let mut data = json!({"v":1,"op":"history","conversationId":conversation,"agentId":session,"generation":generation,"binding":binding,"page_id":page_id});
            if let Some(before) = &call.before {
                data["before"] = json!(before);
            }
            if let Some(next) = &call.next {
                data["next"] = json!(next);
            }
            if let Some(turn) = &call.turn_id {
                data["turn_id"] = json!(turn);
            }
            if let Some(request) = &call.request_id {
                data["request_id"] = json!(request);
            }
            let frame = connection
                .attached
                .send(&json!({"type":"agentChat","data":data}), connection.now())
                .map_err(|_| invalid())?;
            send_checked(connection, runtime, admission, frame).await?;
            output = connection
                .until(|v| {
                    history_done(v)
                        && v["data"]["conversationId"] == conversation
                        && (v["data"]["op"] == "error" || v["data"]["page_id"] == page_id)
                })
                .await?;
        }
        return Ok(output);
    }
    if matches!(operation, Operation::Interrupt | Operation::Stop) {
        if call.take_control != Some(true) {
            return Err(error(StatusCode::CONFLICT, "take_control_required"));
        }
        let (id, frame) = connection
            .attached
            .acquire(session, false, connection.now())
            .map_err(|_| stale())?;
        send_checked(connection, runtime, admission, frame).await?;
        connection.until(|v| v["data"]["re"] == id).await?;
        if connection
            .attached
            .binding(session, connection.now())
            .and_then(|b| b.lease_epoch)
            .is_none()
        {
            return Err(error(StatusCode::CONFLICT, "lease_held"));
        }
    }
    let (id, frame) = match operation {
        Operation::Prompt if call.takeover == Some(true) => {
            let id = new_id();
            let binding = connection
                .attached
                .binding(session, connection.now())
                .ok_or_else(stale)?;
            let op = Op::Submit {
                binding,
                request_id: call.request_id.clone().ok_or_else(invalid)?,
                kind: ReceiptKind::Prompt,
                payload: json!({"text":call.text}),
                acquire: Some(true),
                takeover: Some(true),
                expected_controller: call.expected_controller.clone(),
            };
            let frame = connection
                .attached
                .send(
                    &wire::to_value(&Envelope::Session(wire::SessionMessage {
                        id: id.clone(),
                        re: None,
                        op,
                    })),
                    connection.now(),
                )
                .map_err(|_| invalid())?;
            (id, frame)
        }
        Operation::Prompt => connection
            .attached
            .submit_prompt(
                session,
                call.request_id.as_deref().ok_or_else(invalid)?,
                call.text.as_deref().ok_or_else(invalid)?,
                connection.now(),
            )
            .map_err(|_| stale())?,
        Operation::Receipts => connection
            .attached
            .receipt_query(
                session,
                call.request_ids.as_deref().ok_or_else(invalid)?,
                connection.now(),
            )
            .map_err(|_| stale())?,
        Operation::Seen => connection
            .attached
            .approval_seen(
                session,
                call.approval_id.as_deref().ok_or_else(invalid)?,
                connection.now(),
            )
            .map_err(|_| stale())?,
        _ => {
            let (kind, payload) = match operation {
                Operation::Interrupt => (ReceiptKind::Interrupt, json!({})),
                Operation::Stop => (ReceiptKind::Stop, json!({})),
                Operation::Approval => (
                    ReceiptKind::Approval,
                    call.approval.clone().ok_or_else(invalid)?,
                ),
                Operation::Revoke => (
                    ReceiptKind::ApprovalRuleRevoke,
                    json!({"rule_id":call.rule_id}),
                ),
                _ => return Err(invalid()),
            };
            connection
                .attached
                .submit(
                    session,
                    kind,
                    call.request_id.as_deref().ok_or_else(invalid)?,
                    payload,
                    connection.now(),
                )
                .map_err(|_| stale())?
        }
    };
    send_checked(connection, runtime, admission, frame).await?;
    // Never replay a mutation on timeout: reconnect and query its durable receipt.
    match connection.until(|v| v["data"]["re"] == id).await {
        Ok(events) => Ok(events),
        Err(e) if matches!(operation, Operation::Receipts | Operation::Seen) => Err(e),
        Err(_) => Err((
            StatusCode::GATEWAY_TIMEOUT,
            Json(json!({"error":{"code":"delivery_uncertain"},
            "request_id":call.request_id,"target":call.target,"recovery":"query_receipts"})),
        )
            .into_response()),
    }
}
fn history_done(v: &Value) -> bool {
    v["type"] == "agentChat" && matches!(v["data"]["op"].as_str(), Some("history_end" | "error"))
}

pub(super) async fn events(
    State(IntegrationState(runtime)): State<IntegrationState>,
    Path((id, host)): Path<(String, String)>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    let Some(runtime) = runtime else {
        return lost();
    };
    let permit = match runtime.requests.clone().try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => return error(StatusCode::TOO_MANY_REQUESTS, "integration_busy"),
    };
    let admission = match runtime.admit(&id, &headers, "agent.view").await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let connection = match HostedConnection::open(
        &runtime,
        &admission.context,
        &admission.token.service_fingerprint,
        &host,
    )
    .await
    {
        Ok(v) => v,
        Err(e) => return e,
    };
    upgrade
        .max_message_size(65_536)
        .max_frame_size(65_536)
        .on_upgrade(move |socket| event_socket(socket, runtime, admission, connection, permit))
        .into_response()
}
pub(super) async fn event_socket(
    mut socket: WebSocket,
    runtime: Arc<StationIntegrations>,
    admission: Admission,
    mut connection: HostedConnection,
    _permit: tokio::sync::OwnedSemaphorePermit,
) {
    use futures_util::StreamExt;
    if connection.recheck(&runtime, &admission).await.is_err() {
        return;
    }
    let initial = json!({"type":"snapshot","sessions":connection.attached.registry().sessions().collect::<Vec<_>>(),"targets":connection.attached.registry().sessions().filter_map(|s|connection.attached.target(&s.session_id)).collect::<Vec<_>>(),"approvals":connection.attached.registry().pending_approvals().collect::<Vec<_>>(),"approval_rules":connection.initial_rules});
    if !matches!(
        tokio::time::timeout(
            Duration::from_secs(5),
            socket.send(Message::Text(initial.to_string()))
        )
        .await,
        Ok(Ok(()))
    ) {
        return;
    }
    let mut check = tokio::time::interval(Duration::from_secs(1));
    let mut subscribed = false;
    loop {
        tokio::select! {
            _ = check.tick() => {
                if connection.recheck(&runtime, &admission).await.is_err() { break; }
            },
            frame = connection.next_frame() => {
                let Ok(frame) = frame else { break; };
                if connection.recheck(&runtime, &admission).await.is_err() { break; }
                let Ok(batch) = connection.apply(frame).await else { break; };
                if connection.recheck(&runtime, &admission).await.is_err() { break; }
                for event in batch {
                    if !send_event(&mut socket, Message::Text(event.to_string())).await { return; }
                }
            },
            incoming = socket.next() => match incoming {
                Some(Ok(Message::Text(text))) if !subscribed => {
                    if subscribe(&mut connection, &runtime, &admission, &text).await.is_err() { break; }
                    subscribed = true;
                },
                Some(Ok(Message::Ping(bytes))) => {
                    if !send_event(&mut socket, Message::Pong(bytes)).await { break; }
                },
                Some(Ok(Message::Pong(_))) => {},
                _ => break,
            }
        }
    }
    let _ = socket.close().await;
}

async fn send_event(socket: &mut WebSocket, message: Message) -> bool {
    matches!(
        tokio::time::timeout(Duration::from_secs(5), socket.send(message)).await,
        Ok(Ok(()))
    )
}

async fn subscribe(
    connection: &mut HostedConnection,
    runtime: &StationIntegrations,
    admission: &Admission,
    text: &str,
) -> Result<(), Response> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Subscription {
        target: Target,
    }
    let subscription: Subscription = serde_json::from_str(text).map_err(|_| invalid())?;
    let session = &subscription.target.session_id;
    connection.target(&subscription.target, session)?;
    let conversation = new_id();
    connection.attached.chat_mut().open(&conversation, session);
    let binding = connection
        .attached
        .binding(session, connection.now())
        .ok_or_else(stale)?;
    let open = json!({"type":"agentChat","data":{"v":1,"op":"open",
        "conversationId":conversation,"agentId":session,"binding":binding}});
    let frame = connection
        .attached
        .send(&open, connection.now())
        .map_err(|_| invalid())?;
    send_checked(connection, runtime, admission, frame).await
}

#[cfg(test)]
mod tests {
    use super::*;
    fn call(fields: Value) -> Call {
        let mut base = json!({"target":{"account_id":"a","atem_device_id":"host-a","host_trust_gen":1,
            "session_id":"ses-aaaaaaaaaaaa","process_gen":"11111111-1111-4111-8111-111111111111"}});
        base.as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        serde_json::from_value(base).unwrap()
    }
    #[test]
    fn rejects_ambiguous_or_misplaced_command_fields() {
        let id = new_id();
        assert!(validate_call(
            &call(json!({"request_id":id,"text":"hello"})),
            Operation::Prompt
        )
        .is_ok());
        for fields in [
            json!({"request_id":id,"text":"hello","rule_id":"r"}),
            json!({"request_id":id,"text":"hello","takeover":true}),
            json!({"request_id":id,"text":"hello","take_control":true}),
        ] {
            assert!(validate_call(&call(fields), Operation::Prompt).is_err());
        }
        assert!(validate_call(
            &call(json!({"request_id":id,"approval":{"approval_id":id,"decision":"allow_once"}})),
            Operation::Approval
        )
        .is_ok());
        assert!(validate_call(&call(json!({"request_id":id,"approval":{"approval_id":id,"decision":"allow_once"},"takeover":false})),Operation::Approval).is_err());
        assert!(validate_call(
            &call(json!({"before":"m1","next":"next"})),
            Operation::History
        )
        .is_err());
        assert!(validate_call(
            &call(json!({"request_ids":[id],"text":"ignored?"})),
            Operation::Receipts
        )
        .is_err());
        assert!(validate_call(&call(json!({"request_id":id})), Operation::Interrupt).is_err());
    }
}
