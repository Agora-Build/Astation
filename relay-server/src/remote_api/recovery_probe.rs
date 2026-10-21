//! A bounded public-head probe. No finish/record or controller admission is routed here.
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use atem_client::canonical::StrictValue;
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use serde_json::{json, Value};
use tokio::sync::oneshot;

use crate::{cluster::ConnRef, AppState};

struct Pending {
    subject: String,
    connection: String,
    expires: Instant,
    sender: oneshot::Sender<Value>,
}

#[derive(Clone, Default)]
pub(crate) struct ProbeBroker(Arc<Mutex<HashMap<String, Pending>>>);

impl ProbeBroker {
    fn register(
        &self,
        subject: &str,
        connection: &str,
    ) -> Option<(String, oneshot::Receiver<Value>)> {
        let mut pending = self.0.lock().unwrap_or_else(|e| e.into_inner());
        pending.retain(|_, p| p.expires > Instant::now() && !p.sender.is_closed());
        if pending.len() >= 128 || pending.values().filter(|p| p.subject == subject).count() >= 4 {
            return None;
        }
        let handle = format!("rp_{}", uuid::Uuid::new_v4().simple());
        let (sender, receiver) = oneshot::channel();
        pending.insert(
            handle.clone(),
            Pending {
                subject: subject.into(),
                connection: connection.into(),
                expires: Instant::now() + Duration::from_secs(10),
                sender,
            },
        );
        Some((handle, receiver))
    }

    pub(crate) fn reply(&self, handle: &str, connection: &str, frame: Value) {
        let mut pending = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if pending
            .get(handle)
            .is_some_and(|p| p.connection == connection && p.expires > Instant::now())
        {
            if let Some(p) = pending.remove(handle) {
                let _ = p.sender.send(frame);
            }
        }
    }

    fn remove(&self, handle: &str) {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(handle);
    }
}

struct ProbeGuard {
    hub: crate::relay::RelayHub,
    handle: String,
    target: ConnRef,
}
impl Drop for ProbeGuard {
    fn drop(&mut self) {
        self.hub.probes().remove(&self.handle);
        let (hub, target, handle) = (self.hub.clone(), self.target.clone(), self.handle.clone());
        tokio::spawn(async move {
            hub.deliver(
                &target,
                json!({"type":"channel","event":"close","channel":handle,"reason":"closed"})
                    .to_string(),
            )
            .await;
        });
    }
}

pub(super) async fn probe(
    State(state): State<AppState>,
    Path((genesis, host)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> (StatusCode, Json<Value>) {
    let error = |status, code| (status, Json(json!({"error":{"code":code}})));
    let subject = match super::recovery::subject(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let bytes = match to_bytes(body, 65_536).await {
        Ok(v) => v,
        Err(_) => return error(StatusCode::PAYLOAD_TOO_LARGE, "recovery_record_too_large"),
    };
    let init = match StrictValue::parse(&bytes, 65_536) {
        Ok(v) => v,
        Err(_) => return error(StatusCode::BAD_REQUEST, "invalid_recovery_probe"),
    };
    let frame = init.value();
    if frame["ch"] != "atem-ch1"
        || frame["op"] != "init"
        || frame.as_object().map(|o| o.len()) != Some(7)
        || frame["genesis_hash"] != genesis
        || frame["e"].as_str().is_none()
        || frame["n"].as_str().is_none()
        || frame["host_id"] != host
        || !frame["host_trust_gen"]
            .as_u64()
            .is_some_and(|g| (1..=9_007_199_254_740_991).contains(&g))
    {
        return error(StatusCode::BAD_REQUEST, "invalid_recovery_probe");
    }
    let room = match super::recovery::probe_room(&state, &genesis, &subject, &host).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let target = match state.relay.room(&room).await {
        Ok(Some(room)) => match room.atems.get(&host) {
            Some(v) => v.clone(),
            None => return error(StatusCode::SERVICE_UNAVAILABLE, "recovery_host_unreachable"),
        },
        _ => return error(StatusCode::SERVICE_UNAVAILABLE, "recovery_host_unreachable"),
    };
    let Some((handle, reply)) = state.relay.probes().register(&subject, &target.conn) else {
        return error(StatusCode::TOO_MANY_REQUESTS, "recovery_probe_busy");
    };
    let _guard = ProbeGuard {
        hub: state.relay.clone(),
        handle: handle.clone(),
        target: target.clone(),
    };
    state
        .relay
        .deliver(
            &target,
            json!({"type":"channel","event":"open","channel":handle,"transport":"relay"})
                .to_string(),
        )
        .await;
    state
        .relay
        .deliver(
            &target,
            json!({"type":"channel","event":"frame","channel":handle,"frame":frame}).to_string(),
        )
        .await;
    match tokio::time::timeout(Duration::from_secs(10), reply).await {
        Ok(Ok(frame)) if frame["ch"] == "atem-ch1" && frame["op"] == "accept" => {
            (StatusCode::OK, Json(frame))
        }
        _ => error(StatusCode::SERVICE_UNAVAILABLE, "recovery_host_unreachable"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn generation_bound_single_reply_and_bounded_pending() {
        let broker = ProbeBroker::default();
        let (handle, mut receiver) = broker.register("alice", "socket-1").unwrap();
        broker.reply(&handle, "socket-2", json!({"op":"accept"}));
        assert!(receiver.try_recv().is_err());
        broker.reply(&handle, "socket-1", json!({"op":"accept"}));
        assert_eq!(receiver.await.unwrap()["op"], "accept");
        let mut keep = Vec::new();
        for _ in 0..4 {
            keep.push(broker.register("alice", "socket-1").unwrap());
        }
        assert!(broker.register("alice", "socket-1").is_none());
        drop(keep);
        assert!(broker.register("alice", "socket-1").is_some());
    }
}
