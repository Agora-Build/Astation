//! Online screenshot delivery. The response owns the authenticated host channel.
use super::{admission::Admission, client::HostedConnection, invalid, lost, stale};
use crate::station_integrations::{error, IntegrationState, StationIntegrations};
use atem_client::{
    membership::service_grant,
    session::{
        attachments::{self, CHUNK_BYTES},
        host_work::{self, HostTarget, Request, ResultBody, WorkState},
        mark::MarkTask,
        messages::{Delivery, Destination, Message, Recipient},
        new_id,
        wire::Target,
    },
};
use axum::{
    body::{Body, Bytes},
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{convert::Infallible, time::Duration};
use tokio::sync::mpsc;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct MarkCall {
    target: Target,
    route_id: String,
    route_revision: u64,
    message_id: String,
    workflow_id: String,
    recipient_id: String,
    created_at: u64,
    expires_at: u64,
    mark: MarkTask,
    png_base64: String,
}

impl MarkCall {
    fn message(&self, sender: String) -> Message {
        Message {
            message_id: self.message_id.clone(),
            workflow_id: self.workflow_id.clone(),
            sender,
            created_at: self.created_at,
            expires_at: self.expires_at,
            recipients: vec![Recipient {
                recipient_id: self.recipient_id.clone(),
                host: self.host(),
                destination: Destination::Agent {
                    route_id: self.route_id.clone(),
                    route_revision: self.route_revision,
                    target: self.target.clone(),
                },
            }],
            text: String::new(),
            context: vec![],
            mark: Some(self.mark.clone()),
        }
    }
    fn host(&self) -> HostTarget {
        HostTarget {
            account_id: self.target.account_id.clone(),
            atem_device_id: self.target.atem_device_id.clone(),
            host_trust_gen: self.target.host_trust_gen,
        }
    }
    pub(super) fn validate(&self) -> Result<Vec<u8>, Response> {
        let now = chrono::Utc::now().timestamp_millis().max(0) as u64;
        if !self.message("service:validation".into()).valid()
            || self.created_at > now.saturating_add(60_000)
            || self.expires_at <= now
            || self.png_base64.len() > (attachments::MAX_BYTES as usize).div_ceil(3) * 4
        {
            return Err(invalid());
        }
        let png = STANDARD.decode(&self.png_base64).map_err(|_| invalid())?;
        if png.len() as u64 != self.mark.screenshot.size
            || host_work::digest(&png) != self.mark.screenshot.digest
            || !valid_png(&png)
        {
            return Err(invalid());
        }
        Ok(png)
    }
}

fn valid_png(bytes: &[u8]) -> bool {
    if bytes.len() < 33
        || &bytes[..8] != b"\x89PNG\r\n\x1a\n"
        || bytes[8..12] != 13_u32.to_be_bytes()
        || &bytes[12..16] != b"IHDR"
    {
        return false;
    }
    let w = u32::from_be_bytes(bytes[16..20].try_into().unwrap());
    let h = u32::from_be_bytes(bytes[20..24].try_into().unwrap());
    (1..=16384).contains(&w)
        && (1..=16384).contains(&h)
        && u64::from(w) * u64::from(h) <= 40_000_000
}

pub(super) async fn publish(
    State(IntegrationState(runtime)): State<IntegrationState>,
    Path((id, host, session)): Path<(String, String, String)>,
    headers: HeaderMap,
    Json(call): Json<MarkCall>,
) -> Response {
    let Some(runtime) = runtime else {
        return lost();
    };
    let result = async {
        let _setup_permit = runtime.requests.clone().try_acquire_owned()
            .map_err(|_| error(StatusCode::TOO_MANY_REQUESTS, "integration_busy"))?;
        // Waiting work must leave capacity for approvals and other short API calls.
        let stream_permit = runtime.mark_streams.clone().try_acquire_owned()
            .map_err(|_| error(StatusCode::TOO_MANY_REQUESTS, "online_marks_busy"))?;
        let png = call.validate()?;
        let admission = runtime.admit(&id, &headers, "agent.prompt").await?;
        let mut connection = HostedConnection::open(&runtime, &admission.context,
            &admission.token.service_fingerprint, &host).await?;
        connection.target(&call.target, &session)?;
        check_capabilities(&runtime, &admission, &connection).await?;
        connection.recheck(&runtime, &admission).await?;
        let (tx, rx) = mpsc::channel::<Value>(8);
        tokio::spawn(async move {
            let _permit = stream_permit;
            let mut delivery = "not_published";
            let result = tokio::select! {
                _ = tx.closed() => return,
                result = tokio::time::timeout(Duration::from_secs(600), transfer(
                    &runtime, &admission, &mut connection, &call, &png, &tx, &mut delivery
                )) => result.unwrap_or_else(|_| Err(error(StatusCode::GATEWAY_TIMEOUT, "online_deadline"))),
            };
            if let Err(response) = result {
                // Only fixed error codes are returned; host content and credentials are never reflected.
                let code = axum::body::to_bytes(response.into_body(), 4096).await.ok()
                    .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
                    .and_then(|v| v["error"]["code"].as_str().map(str::to_owned))
                    .unwrap_or_else(|| "host_connection_lost".into());
                let _ = tokio::time::timeout(Duration::from_secs(2), tx.send(json!({"event":"error",
                    "code":code,"delivery":delivery,"message_id":call.message_id,"task_id":call.recipient_id}))).await;
            }
        });
        let stream = futures_util::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|v| (Ok::<_, Infallible>(Bytes::from(format!("{v}\n"))), rx))
        });
        Ok::<_, Response>(([("content-type", "application/x-ndjson"), ("cache-control", "no-store"),
            ("x-accel-buffering", "no")], Body::from_stream(stream)).into_response())
    }.await;
    result.unwrap_or_else(|e| e)
}

async fn check_capabilities(
    runtime: &StationIntegrations,
    admission: &Admission,
    connection: &HostedConnection,
) -> Result<(), Response> {
    let welcome = connection.attached.welcome();
    if [
        attachments::FEATURE,
        host_work::WORK_FEATURE,
        atem_client::session::messages::FEATURE,
    ]
    .iter()
    .any(|feature| !welcome.features.iter().any(|f| f == feature))
    {
        return Err(error(StatusCode::CONFLICT, "host_upgrade_required"));
    }
    let log = runtime
        .service_log(
            &admission.context,
            &admission.token.service_fingerprint,
            &welcome.atem_device_id,
        )
        .await?;
    let (scope, _) = service_grant(&log, &admission.context.service_id).ok_or_else(stale)?;
    if ["view", "message", "notify", "prompt"]
        .iter()
        .any(|op| !scope.ops.iter().any(|s| s == op))
    {
        return Err(error(StatusCode::FORBIDDEN, "mark_grant_required"));
    }
    Ok(())
}

async fn request(
    runtime: &StationIntegrations,
    admission: &Admission,
    connection: &mut HostedConnection,
    request: Request,
) -> Result<ResultBody, Response> {
    connection.recheck(runtime, admission).await?;
    let frame = connection
        .attached
        .send(&request.to_json(), connection.now())
        .map_err(|_| invalid())?;
    connection.send(frame).await?;
    // Recheck authority during a delayed reply, not only between chunks/queries.
    let mut check = tokio::time::interval(Duration::from_secs(1));
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        tokio::select! {
            _ = check.tick() => connection.recheck(runtime, admission).await?,
            _ = tokio::time::sleep_until(deadline) => return Err(lost()),
            events = connection.receive() => for event in events? {
                let data = &event["data"];
                if data["re"] != request.id() { continue; }
                if data["op"] == "error" {
                    let code = match data["code"].as_str() {
                        Some("forbidden") => "mark_forbidden",
                        Some("stale_target") => "stale_target",
                        Some("request_id_reused") => "request_id_reused",
                        _ => "mark_request_refused",
                    };
                    return Err(error(StatusCode::CONFLICT, code));
                }
                let reply = host_work::Response::from_data(data).map_err(|_| lost())?;
                if !reply.answers(&request) { return Err(lost()); }
                connection.recheck(runtime, admission).await?;
                return Ok(reply.result);
            },
        }
    }
}

async fn emit(tx: &mpsc::Sender<Value>, event: Value) -> Result<(), Response> {
    tokio::time::timeout(Duration::from_secs(5), tx.send(event))
        .await
        .map_err(|_| lost())?
        .map_err(|_| lost())
}

async fn transfer(
    runtime: &StationIntegrations,
    admission: &Admission,
    connection: &mut HostedConnection,
    call: &MarkCall,
    png: &[u8],
    tx: &mpsc::Sender<Value>,
    delivery: &mut &'static str,
) -> Result<(), Response> {
    for (i, chunk) in png.chunks(CHUNK_BYTES).enumerate() {
        let result = request(
            runtime,
            admission,
            connection,
            Request::AttachmentPut {
                v: 1,
                id: new_id(),
                host: call.host(),
                attachment: call.mark.screenshot.clone(),
                offset: (i * CHUNK_BYTES) as u64,
                data: STANDARD.encode(chunk),
            },
        )
        .await?;
        let ResultBody::Attachment { upload } = result else {
            return Err(lost());
        };
        if upload.received < ((i * CHUNK_BYTES) + chunk.len()) as u64 {
            return Err(lost());
        }
        if i * CHUNK_BYTES + chunk.len() == png.len() && !upload.ready {
            return Err(lost());
        }
    }
    let message = call.message(format!("service:{}", admission.context.service_id));
    // From this point a lost reply is uncertain; callers retain the immutable IDs.
    *delivery = "uncertain";
    let result = request(
        runtime,
        admission,
        connection,
        Request::Publish {
            v: 1,
            id: new_id(),
            host: call.host(),
            message,
        },
    )
    .await?;
    let ResultBody::Message { message } = result else {
        return Err(lost());
    };
    let Some(recipient) = message.recipients.first() else {
        return Err(lost());
    };
    let Delivery::Work { work } = &recipient.delivery else {
        *delivery = "not_published";
        return Err(error(StatusCode::FORBIDDEN, "mark_recipient_refused"));
    };
    *delivery = "accepted";
    emit(
        tx,
        json!({"event":"accepted","message_id":call.message_id,"work":work}),
    )
    .await?;
    let mut last = None;
    let mut last_emitted = tokio::time::Instant::now();
    loop {
        let result = request(
            runtime,
            admission,
            connection,
            Request::WorkQuery {
                v: 1,
                id: new_id(),
                host: call.host(),
                task_id: call.recipient_id.clone(),
            },
        )
        .await?;
        let ResultBody::Work { work } = result else {
            return Err(lost());
        };
        if last.as_ref() != Some(&work) || last_emitted.elapsed() >= Duration::from_secs(5) {
            emit(tx, json!({"event":"work","work":work})).await?;
            last = Some(work.clone());
            last_emitted = tokio::time::Instant::now();
        }
        if work.state.terminal() || work.state == WorkState::AwaitingResult {
            // A turn ending is reported honestly; only work_complete supplies a result.
            emit(
                tx,
                json!({"event":"end","state":work.state,"task_id":call.recipient_id}),
            )
            .await?;
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}
