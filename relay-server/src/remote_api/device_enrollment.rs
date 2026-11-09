//! Account-private, expiring carriage only. A mailbox never grants membership.
use super::{error, subject, Operation, Reply, MAX_INTEGER};
use crate::AppState;
use atem_client::canonical::{jcs, StrictValue};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

const MAX_SLOTS: usize = 8;
const LIFETIME: u64 = 600_000;
const TOMBSTONE: u64 = 600_000;
const MAX_MESSAGE: usize = 16_384;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(super) struct Record {
    expires: u64,
    request: Option<Value>,
    response: Option<Value>,
    cancelled: bool,
}

pub(in crate::remote_api) enum Command {
    Create {
        id: String,
        expires: u64,
    },
    Get {
        id: String,
    },
    Publish {
        id: String,
        response: bool,
        message: Value,
    },
    Cancel {
        id: String,
    },
}

fn invalid() -> Reply {
    error(StatusCode::BAD_REQUEST, "invalid_device_enrollment")
}
fn id_valid(id: &str) -> bool {
    URL_SAFE_NO_PAD
        .decode(id)
        .is_ok_and(|v| v.len() == 32 && URL_SAFE_NO_PAD.encode(v) == id)
}
fn fields(value: &Value, expected: &[&str]) -> bool {
    value
        .as_object()
        .is_some_and(|v| v.len() == expected.len() && expected.iter().all(|k| v.contains_key(*k)))
}

/// Keep consumed IDs until well after their native invitation deadline. Neither
/// retries, cancellation nor re-creation can extend that original deadline.
pub(super) fn collect(records: &mut BTreeMap<String, Record>, now: u64) {
    records.retain(|_, record| now < record.expires.saturating_add(TOMBSTONE));
}

pub(super) fn apply(
    records: &mut BTreeMap<String, Record>,
    command: Command,
    now: u64,
) -> Result<Reply, Reply> {
    let id = match &command {
        Command::Create { id, .. }
        | Command::Get { id }
        | Command::Publish { id, .. }
        | Command::Cancel { id } => id,
    };
    if !id_valid(id) {
        return Err(invalid());
    }
    collect(records, now);
    if let Command::Create { expires, .. } = &command {
        if *expires <= now || *expires > MAX_INTEGER || expires.saturating_sub(now) > LIFETIME {
            return Err(invalid());
        }
        if let Some(previous) = records.get(id) {
            if previous.expires != *expires {
                return Err(error(StatusCode::CONFLICT, "device_enrollment_conflict"));
            }
        } else {
            if records.len() >= MAX_SLOTS {
                return Err(error(
                    StatusCode::TOO_MANY_REQUESTS,
                    "device_enrollment_limit",
                ));
            }
            records.insert(
                id.clone(),
                Record {
                    expires: *expires,
                    request: None,
                    response: None,
                    cancelled: false,
                },
            );
        }
    }
    let record = records
        .get_mut(id)
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "device_enrollment_not_found"))?;
    if now >= record.expires || record.cancelled {
        return Err(error(StatusCode::GONE, "device_enrollment_closed"));
    }
    match command {
        Command::Publish {
            response, message, ..
        } => {
            let valid = if response {
                fields(&message, &["context", "enc", "ciphertext", "mac"])
                    && fields(
                        &message["context"],
                        &["version", "invitation", "request", "seq", "head", "entry"],
                    )
            } else {
                fields(&message, &["body", "signature", "mac"])
                    && fields(
                        &message["body"],
                        &[
                            "version",
                            "invitation",
                            "device",
                            "name",
                            "auth",
                            "encryption",
                            "roles",
                            "nonce",
                        ],
                    )
            };
            if !valid || jcs(&message).map_or(true, |v| v.len() > MAX_MESSAGE) {
                return Err(invalid());
            }
            if response && record.request.is_none() {
                return Err(error(
                    StatusCode::CONFLICT,
                    "device_enrollment_request_required",
                ));
            }
            let slot = if response {
                &mut record.response
            } else {
                &mut record.request
            };
            if let Some(previous) = slot {
                if previous != &message {
                    return Err(error(StatusCode::CONFLICT, "device_enrollment_conflict"));
                }
            } else {
                *slot = Some(message);
            }
        }
        Command::Cancel { .. } => {
            record.cancelled = true;
            record.request = None;
            record.response = None;
            return Ok((StatusCode::OK, Json(json!({"closed":true}))));
        }
        _ => {}
    }
    Ok((
        StatusCode::OK,
        Json(json!({"expires":record.expires,"request":record.request,"response":record.response})),
    ))
}

async fn read(body: Body) -> Result<Value, Reply> {
    let bytes = to_bytes(body, MAX_MESSAGE + 256)
        .await
        .map_err(|_| error(StatusCode::PAYLOAD_TOO_LARGE, "device_enrollment_too_large"))?;
    StrictValue::parse(&bytes, MAX_MESSAGE + 256)
        .map(|v| v.value().clone())
        .map_err(|_| invalid())
}

pub async fn create(
    State(state): State<AppState>,
    Path((genesis, id)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let owner = match subject(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let value = match read(body).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let Some(expires) = value["expires"]
        .as_u64()
        .filter(|_| fields(&value, &["expires"]))
    else {
        return invalid();
    };
    state
        .recovery
        .perform(
            &genesis,
            &owner,
            Operation::DeviceEnrollment(Command::Create { id, expires }),
        )
        .await
}
pub async fn get(
    State(state): State<AppState>,
    Path((genesis, id)): Path<(String, String)>,
    headers: HeaderMap,
) -> Reply {
    let owner = match subject(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    state
        .recovery
        .perform(
            &genesis,
            &owner,
            Operation::DeviceEnrollment(Command::Get { id }),
        )
        .await
}
pub async fn publish(
    State(state): State<AppState>,
    Path((genesis, id)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let owner = match subject(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let value = match read(body).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    if !fields(&value, &["stage", "message"]) {
        return invalid();
    }
    let response = match value["stage"].as_str() {
        Some("request") => false,
        Some("response") => true,
        _ => return invalid(),
    };
    state
        .recovery
        .perform(
            &genesis,
            &owner,
            Operation::DeviceEnrollment(Command::Publish {
                id,
                response,
                message: value["message"].clone(),
            }),
        )
        .await
}
pub async fn cancel(
    State(state): State<AppState>,
    Path((genesis, id)): Path<(String, String)>,
    headers: HeaderMap,
) -> Reply {
    let owner = match subject(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    state
        .recovery
        .perform(
            &genesis,
            &owner,
            Operation::DeviceEnrollment(Command::Cancel { id }),
        )
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Method, Request},
    };
    use std::sync::Arc;
    use tower::ServiceExt;

    fn id(byte: u8) -> String {
        URL_SAFE_NO_PAD.encode([byte; 32])
    }
    fn create(id: String, expires: u64) -> Command {
        Command::Create { id, expires }
    }
    fn message(response: bool) -> Value {
        if response {
            json!({"context":{"version":1,"invitation":"digest","request":"digest","seq":2,"head":"hash","entry":"hash"},
            "enc":"sealed-enc","ciphertext":"sealed-content","mac":"mac"})
        } else {
            json!({"body":{"version":1,"invitation":"digest","device":"phone","name":"Phone","auth":"public","encryption":"public","roles":["view"],"nonce":"nonce"},
            "signature":"proof","mac":"mac"})
        }
    }
    fn publish(id: String, response: bool, message: Value) -> Command {
        Command::Publish {
            id,
            response,
            message,
        }
    }

    #[test]
    fn retries_are_immutable_and_cannot_extend_expiry_or_replace_requests() {
        let mut records = BTreeMap::new();
        let _ = apply(&mut records, create(id(1), 10_000), 1_000).unwrap();
        let _ = apply(&mut records, create(id(1), 10_000), 2_000).unwrap();
        assert_eq!(
            apply(&mut records, create(id(1), 11_000), 2_000)
                .unwrap_err()
                .0,
            StatusCode::CONFLICT
        );
        assert_eq!(
            apply(&mut records, publish(id(1), true, message(true)), 2_000)
                .unwrap_err()
                .0,
            StatusCode::CONFLICT
        );
        let first = apply(&mut records, publish(id(1), false, message(false)), 2_000).unwrap();
        assert_eq!(
            apply(&mut records, publish(id(1), false, message(false)), 2_000)
                .unwrap()
                .1
                 .0,
            first.1 .0
        );
        let mut other = message(false);
        other["body"]["device"] = json!("another-phone");
        assert_eq!(
            apply(&mut records, publish(id(1), false, other), 2_000)
                .unwrap_err()
                .0,
            StatusCode::CONFLICT
        );
        let _ = apply(&mut records, publish(id(1), true, message(true)), 2_000).unwrap();
        let mut restored = serde_json::from_value(serde_json::to_value(&records).unwrap()).unwrap();
        assert_eq!(
            apply(&mut restored, publish(id(1), true, message(true)), 2_000)
                .unwrap()
                .1
                 .0["response"],
            message(true)
        );
        assert_eq!(
            apply(&mut restored, Command::Get { id: id(1) }, 10_000)
                .unwrap_err()
                .0,
            StatusCode::GONE
        );
    }

    #[test]
    fn limits_tombstones_and_cancellation_bound_account_storage() {
        let mut records = BTreeMap::new();
        for n in 0..MAX_SLOTS {
            let _ = apply(&mut records, create(id(n as u8), 2_000), 1_000).unwrap();
        }
        assert_eq!(
            apply(&mut records, create(id(20), 2_000), 1_000)
                .unwrap_err()
                .0,
            StatusCode::TOO_MANY_REQUESTS
        );
        let _ = apply(&mut records, Command::Cancel { id: id(0) }, 1_000).unwrap();
        assert_eq!(
            apply(&mut records, publish(id(0), false, message(false)), 1_000)
                .unwrap_err()
                .0,
            StatusCode::GONE
        );
        assert_eq!(
            apply(&mut records, create(id(0), 2_000), 1_000)
                .unwrap_err()
                .0,
            StatusCode::GONE
        );
        assert_eq!(records.len(), MAX_SLOTS);
        collect(&mut records, 2_000 + TOMBSTONE);
        assert!(records.is_empty());
        for (id, expiry) in [
            ("../bad".into(), 2_000),
            (id(1), 1_000),
            (id(1), 1_000 + LIFETIME + 1),
        ] {
            assert_eq!(
                apply(&mut records, create(id, expiry), 1_000)
                    .unwrap_err()
                    .0,
                StatusCode::BAD_REQUEST
            );
        }
    }

    #[test]
    fn invitation_secrets_and_plaintext_key_handoffs_are_not_valid_carrier_messages() {
        let mut records = BTreeMap::new();
        let _ = apply(&mut records, create(id(1), 2_000), 1_000).unwrap();
        for message in [
            json!({"secret":"must-never-be-uploaded"}),
            json!({"keys":[{"kid":"key","k":"plaintext"}]}),
            {
                let mut v = message(false);
                v["secret"] = json!("extra");
                v
            },
        ] {
            assert_eq!(
                apply(&mut records, publish(id(1), false, message), 1_000)
                    .unwrap_err()
                    .0,
                StatusCode::BAD_REQUEST
            );
        }
        let mut oversized = message(false);
        oversized["body"]["name"] = json!("x".repeat(MAX_MESSAGE));
        assert_eq!(
            apply(&mut records, publish(id(1), false, oversized), 1_000)
                .unwrap_err()
                .0,
            StatusCode::BAD_REQUEST
        );
    }

    #[tokio::test]
    #[ignore = "requires a local isolated Postgres test database"]
    async fn postgres_mailbox_serializes_replicas_and_survives_restart_and_failed_writes() {
        use super::super::RecoveryStore;
        let db =
            crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
        let store = RecoveryStore::postgres(db.pool.clone());
        let replica_pool = db.reconnect(4).await;
        let replica = RecoveryStore::postgres(replica_pool.clone());
        let now = chrono::Utc::now().timestamp_millis() as u64;
        let fixture = crate::remote_api::push_ingress::tests::Fixture::new(now);
        fixture.publish(&store).await;
        let genesis = fixture.log.genesis_hash().to_hex();
        let op = Operation::DeviceEnrollment;
        assert_eq!(
            store
                .perform(&genesis, "alice", op(create(id(1), now + 60_000)))
                .await
                .0,
            StatusCode::OK
        );
        let mut competing = message(false);
        competing["body"]["device"] = json!("another-phone");
        let (left, right) = tokio::join!(
            store.perform(&genesis, "alice", op(publish(id(1), false, message(false)))),
            replica.perform(&genesis, "alice", op(publish(id(1), false, competing)))
        );
        assert!(matches!(
            (left.0, right.0),
            (StatusCode::OK, StatusCode::CONFLICT) | (StatusCode::CONFLICT, StatusCode::OK)
        ));
        let committed = replica
            .perform(&genesis, "alice", op(Command::Get { id: id(1) }))
            .await
            .1
             .0;
        assert!(committed["request"].is_object());
        assert!(committed["response"].is_null());

        // A transaction failure must not report or retain a published handoff.
        sqlx::query("ALTER TABLE remote_recovery_roots ADD CONSTRAINT inject_failure CHECK (false) NOT VALID")
            .execute(&db.pool).await.unwrap();
        assert_eq!(
            store
                .perform(&genesis, "alice", op(publish(id(1), true, message(true))))
                .await
                .0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        sqlx::query("ALTER TABLE remote_recovery_roots DROP CONSTRAINT inject_failure")
            .execute(&db.pool)
            .await
            .unwrap();
        assert_eq!(
            replica
                .perform(&genesis, "alice", op(Command::Get { id: id(1) }))
                .await
                .1
                 .0,
            committed
        );
        assert_eq!(
            replica
                .perform(&genesis, "alice", op(publish(id(1), true, message(true))))
                .await
                .0,
            StatusCode::OK
        );

        drop(store);
        drop(replica);
        replica_pool.close().await;
        let restarted = RecoveryStore::postgres(db.reconnect(2).await);
        assert_eq!(
            restarted
                .perform(&genesis, "alice", op(Command::Get { id: id(1) }))
                .await
                .1
                 .0["response"],
            message(true)
        );
        assert_eq!(
            restarted
                .perform(&genesis, "mallory", op(Command::Get { id: id(1) }))
                .await
                .0,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            restarted
                .perform(&genesis, "alice", op(Command::Cancel { id: id(1) }))
                .await
                .0,
            StatusCode::OK
        );
        assert_eq!(
            restarted
                .perform(&genesis, "alice", op(create(id(1), now + 60_000)))
                .await
                .0,
            StatusCode::GONE
        );
        restarted.pool().unwrap().close().await;
        db.cleanup().await;
    }

    #[tokio::test]
    async fn actual_routes_require_account_tokens_and_hide_foreign_rooms() {
        let mut state = crate::tests::test_state();
        state.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
            state.knowledge.clone(),
            state.vault.clone(),
            Arc::new(super::super::tests::TestAccountVerifier),
        ));
        state.recovery = super::super::RecoveryStore::memory();
        let f = crate::remote_api::push_ingress::tests::Fixture::new(
            chrono::Utc::now().timestamp_millis() as u64,
        );
        f.publish(&state.recovery).await;
        let genesis = f.log.genesis_hash().to_hex();
        let app = axum::Router::new()
            .nest("/api/remote/v1", crate::remote_api::routes())
            .with_state(state);
        let path = format!("/api/remote/v1/logs/{genesis}/device-enrollments/{}", id(1));
        for (method, owner, body, expected) in [
            (Method::GET, None, json!({}), StatusCode::UNAUTHORIZED),
            (
                Method::PUT,
                Some("mallory"),
                json!({"expires":chrono::Utc::now().timestamp_millis() as u64 + 60_000}),
                StatusCode::NOT_FOUND,
            ),
            (
                Method::PUT,
                Some("alice"),
                json!({"expires":chrono::Utc::now().timestamp_millis() as u64 + 60_000}),
                StatusCode::OK,
            ),
            (
                Method::POST,
                Some("alice"),
                json!({"stage":"request","message":message(false)}),
                StatusCode::OK,
            ),
            (
                Method::POST,
                Some("alice"),
                json!({"stage":"response","message":message(true)}),
                StatusCode::OK,
            ),
            (
                Method::GET,
                Some("mallory"),
                json!({}),
                StatusCode::NOT_FOUND,
            ),
            (Method::DELETE, Some("alice"), json!({}), StatusCode::OK),
            (Method::GET, Some("alice"), json!({}), StatusCode::GONE),
        ] {
            let mut request = Request::builder()
                .method(method)
                .uri(&path)
                .header("content-type", "application/json");
            if let Some(owner) = owner {
                request = request.header("authorization", format!("Bearer {owner}"));
            }
            let response = app
                .clone()
                .oneshot(request.body(Body::from(body.to_string())).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), expected);
            assert_eq!(response.headers()["cache-control"], "no-store");
        }
    }
}
