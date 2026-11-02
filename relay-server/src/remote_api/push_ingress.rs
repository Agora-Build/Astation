//! Durable R9.9 dispositions. Only the shared verifier interprets signed hints.
use atem_client::{
    canonical::{jcs, StrictValue},
    membership::{Action, Membership},
    push::{
        Hint, Identity, Refusal, RelayLedger, Seen, Verdict, Verifier, CLIENT_SKEW_MS,
        MAX_PENDING_SEENS, PENDING_SEEN_MS,
    },
    SignedObject,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::{push_ack, recovery::RecoveryStore};

const MAX_EVENTS: usize = 2048;
const MAX_BYTES: usize = 4 * 1024 * 1024;

/// Captured after the socket's generation check, before awaiting storage.
/// These routing constraints never replace the signature or membership check.
#[derive(Clone)]
pub(crate) struct HostContext {
    pub room: String,
    pub host: String,
    pub connection: String,
}

pub(super) struct Ingress {
    pub context: HostContext,
    pub object: SignedObject,
    pub seen: bool,
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub(super) struct PushState {
    events: Vec<Event>,
}

impl std::fmt::Debug for PushState {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        out.debug_struct("PushState")
            .field("event_count", &self.events.len())
            .finish()
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct Event {
    object: Value,
    ack: Value,
    code: String,
    accepted: bool,
    received_at: u64,
    retain_until: u64,
}

impl PushState {
    pub(super) fn collect(&mut self, now: u64) {
        self.events.retain(|e| e.retain_until > now);
    }
    fn ledger(&self, log: &Membership) -> RelayLedger {
        let mut ledger = RelayLedger::new();
        for event in self.events.iter().filter(|e| e.accepted) {
            let Ok(object) = SignedObject::parse(event.object.to_string().as_bytes()) else {
                continue;
            };
            if object.body_type() == "atem-seen" {
                ledger.receive_seen(&object, log, event.received_at);
            } else {
                ledger.receive_hint(&object, log, event.received_at);
            }
        }
        ledger
    }

    pub(super) fn receive(
        &mut self,
        ingress: &Ingress,
        log: &Membership,
        now: u64,
    ) -> Result<Value, ()> {
        let context = &ingress.context;
        let object = &ingress.object;
        if context.connection.is_empty()
            || object.body()["host_id"] != context.host
            || log.frozen().is_some()
        {
            return Err(());
        }
        let host = log.host(&context.host).ok_or(())?;
        let room = log
            .entries()
            .iter()
            .rev()
            .find_map(|entry| match &entry.action {
                Action::AddHost { host: record } if record == host => Some(entry.signer.as_str()),
                _ => None,
            })
            .ok_or(())?;
        if room != context.room {
            return Err(());
        }

        self.collect(now);
        let bytes = jcs(&object.to_json()).map_err(|_| ())?;
        if let Some(event) = self
            .events
            .iter()
            .find(|e| jcs(&e.object).ok().as_deref() == Some(&bytes))
        {
            return Ok(
                json!({"ack":event.ack, "code":if event.accepted { "idempotent" } else { &event.code }}),
            );
        }

        let (identity, refusal) = if ingress.seen {
            (Seen::verify(object, log).map_err(|_| ())?.identity(), None)
        } else {
            match Hint::verify_reporting(object, log, now, Verifier::Relay) {
                Ok(hint) => (hint.identity(), None),
                Err((reason, Some(id))) => (*id, Some(reason)),
                Err(_) => return Err(()),
            }
        };
        let ack = identity.to_ack();
        if self.events.iter().any(|e| e.ack == ack) {
            return Ok(json!({"ack":ack,"code":"duplicate"}));
        }
        let mut ledger = self.ledger(log);
        let verdict = match refusal {
            Some(reason) => Verdict::Refused(reason),
            None if !self.times_match(&identity, object) => Verdict::Refused(Refusal::InvalidTimes),
            None if ingress.seen => ledger.receive_seen(object, log, now).0,
            None => ledger.receive_hint(object, log, now).0,
        };
        let accepted = !matches!(verdict, Verdict::Refused(_));
        if self.events.len() >= MAX_EVENTS {
            return Err(());
        }
        let end = if ingress.seen {
            object.body()["created_at"]
                .as_u64()
                .ok_or(())?
                .saturating_add(PENDING_SEEN_MS)
        } else {
            object.body()["expires_at"]
                .as_u64()
                .ok_or(())?
                .saturating_add(CLIENT_SKEW_MS)
        };
        self.events.push(Event {
            object: object.to_json(),
            ack: ack.clone(),
            code: verdict.code().into(),
            accepted,
            received_at: now,
            // Refusals with malicious times cannot retain records indefinitely.
            retain_until: end
                .max(now.saturating_add(10_000))
                .min(now.saturating_add(1_500_000)),
        });
        self.bound_pending_seen();
        if serde_json::to_vec(self).map_err(|_| ())?.len() > MAX_BYTES {
            return Err(());
        }
        Ok(json!({"ack":ack, "code":verdict.code()}))
    }

    fn times_match(&self, identity: &Identity, object: &SignedObject) -> bool {
        self.events.iter().filter(|e| e.accepted).all(|event| {
            let same = Identity::from_ack(&event.ack).is_ok_and(|old| old.key() == identity.key());
            !same
                || (event.object["body"]["created_at"] == object.body()["created_at"]
                    && (event.object["body"].get("expires_at").is_none()
                        || object.body().get("expires_at").is_none()
                        || event.object["body"]["expires_at"] == object.body()["expires_at"]))
        })
    }

    fn bound_pending_seen(&mut self) {
        let pending: Vec<usize> = self.events.iter().enumerate().filter_map(|(index, event)| {
            let Identity::Seen { key, device_id } = Identity::from_ack(&event.ack).ok()? else { return None };
            let has_open = self.events.iter().filter(|e| e.accepted).any(|e| {
                matches!(Identity::from_ack(&e.ack), Ok(Identity::Open { key: k, device_id: d }) if key == k && device_id == d)
            });
            (event.accepted && !has_open).then_some(index)
        }).collect();
        for index in pending.into_iter().rev().skip(MAX_PENDING_SEENS) {
            self.events.remove(index);
        }
    }
}

#[cfg(test)]
pub(crate) mod tests;

/// Consume relay-control frames from a current host socket. Every ACK follows
/// a committed root transaction; malformed/unidentified or failed writes get none.
pub(crate) async fn handle(
    store: &RecoveryStore,
    context: HostContext,
    text: &str,
) -> Option<Vec<String>> {
    let value: Value = serde_json::from_str(text).ok()?;
    if value["type"] != "relay"
        && value["type"] != "push_approval"
        && value["type"] != "push_resolved"
    {
        return None;
    }
    let Ok(strict) = StrictValue::parse(text.as_bytes(), push_ack::MAX_RELAY_MESSAGE_BYTES) else {
        return Some(vec![]);
    };
    let value = strict.value();
    let Some(fields) = value.as_object() else {
        return Some(vec![]);
    };
    if fields.len() != 3 || value["type"] != "relay" {
        return Some(vec![]);
    }
    let (objects, seen) = match value["op"].as_str() {
        Some("push_hint") => match value["hints"].as_array().filter(|a| a.len() <= 256) {
            Some(a) => (a.clone(), false),
            None => return Some(vec![]),
        },
        Some("push_seen") => match value.get("seen") {
            Some(v) => (vec![v.clone()], true),
            None => return Some(vec![]),
        },
        _ => return Some(vec![]),
    };
    let mut acks = Vec::new();
    for value in objects {
        let Ok(object) = SignedObject::parse(value.to_string().as_bytes()) else {
            continue;
        };
        if seen != (object.body_type() == "atem-seen") {
            continue;
        }
        if let Some(disposition) = store
            .push(Ingress {
                context: context.clone(),
                object,
                seen,
            })
            .await
        {
            if disposition["code"] != "accepted" && disposition["code"] != "idempotent" {
                // Codes only: never log ciphertext, approval metadata, tokens or content.
                tracing::debug!(
                    code = disposition["code"].as_str().unwrap_or("refused"),
                    "r9 push disposition"
                );
            }
            acks.push(disposition["ack"].clone());
        }
    }
    Some(push_ack::encode(&acks).unwrap_or_default())
}
