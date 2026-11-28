//! Account-private, bounded carriage. Consumers authenticate reports themselves.
use super::{error, subject, Operation, Reply};
use crate::AppState;
use atem_client::{
    canonical::{jcs, StrictValue},
    member_report::{verify_verifier_report, ReportChallenge},
    membership::{Head, MemberKind, MemberStatus, Membership},
};
use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeMap, time::Duration};

const MAX_PENDING: usize = 128;
const MAX_PER_SLOT: usize = 16;
const MAX_REPORTS: usize = 4;
const MAX_BODY: usize = 16_640;
const TOMBSTONE_MS: u64 = 30_000;

#[path = "verifier_reports/external.rs"]
pub(super) mod external;

/// Check the authenticated owner of an account-private verifier operation.
/// Mailbox callers already hold the root lock, so do not wait for a policy writer.
pub(super) async fn portal_allows(
    tx: &mut sqlx::PgConnection, portal: &crate::integration_feed::FeedBinding,
    principal: &str, account: &str, genesis: &str,
) -> Result<bool, sqlx::Error> {
    let invalid = || sqlx::Error::Protocol("invalid verifier feed policy".into());
    let owner: Option<String> = sqlx::query_scalar(
        "SELECT subject FROM account_identities WHERE issuer=$1 AND principal=$2",
    ).bind(&portal.issuer).bind(principal).fetch_optional(&mut *tx).await?;
    let Some(owner) = owner else { return Ok(false) };
    let row: Option<String> = sqlx::query_scalar(
        "SELECT checkpoint FROM station_integration_policy WHERE binding=$1 FOR SHARE NOWAIT",
    ).bind(portal.storage_key().map_err(|_| invalid())?).fetch_optional(&mut *tx).await?;
    let policy = crate::integration_feed::PolicyStore::decode_checkpoint(portal, row).map_err(|_| invalid())?;
    if !policy.recent_d27_read(chrono::Utc::now().timestamp_millis()) { return Ok(false); }
    let allowed = policy.allows_list_release_in(tx, &owner, account, genesis).await.map_err(|_| invalid())?;
    Ok(allowed && policy.recent_d27_read(chrono::Utc::now().timestamp_millis()))
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Record {
    challenge: Value,
    head: Value,
    reports: BTreeMap<String, Value>,
    closed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    external_grant: Option<external::Grant>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    first_external_fetch_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    external_answered: bool,
}

pub(super) enum Command {
    Create {
        challenge: ReportChallenge,
        expected: Head,
    },
    Inbox {
        signer: String,
        slot: String,
        expected: Head,
    },
    Read {
        nonce: String,
    },
    Publish {
        nonce: String,
        report: Value,
    },
    Close {
        nonce: String,
    },
}

fn invalid() -> Reply {
    error(StatusCode::BAD_REQUEST, "invalid_verifier_report_request")
}
fn changed() -> Reply {
    error(StatusCode::CONFLICT, "verifier_report_context_changed")
}
fn closed() -> Reply {
    error(StatusCode::GONE, "verifier_report_closed")
}
fn fields(value: &Value, keys: &[&str]) -> bool {
    value
        .as_object()
        .is_some_and(|o| o.len() == keys.len() && keys.iter().all(|k| o.contains_key(*k)))
}

fn active(log: &Membership, signer: &str, now: u64) -> bool {
    let Some((kind, id)) = signer.split_once(':') else {
        return false;
    };
    log.member(id).is_some_and(|m| {
        m.status == MemberStatus::Active
            && match (&m.member.kind, kind) {
                (MemberKind::Native { .. }, "member") => true,
                (MemberKind::Service { expires_at, .. }, "service") => now < *expires_at,
                _ => false,
            }
    })
}

pub(super) fn collect(records: &mut BTreeMap<String, Record>, now: u64) {
    records.retain(|_, r| {
        r.challenge["expires_at"]
            .as_u64()
            .is_some_and(|expiry| now < expiry.saturating_add(TOMBSTONE_MS))
    });
}

fn reply(record: &Record) -> Reply {
    (
        StatusCode::OK,
        Json(json!({"challenge":record.challenge,"expected":record.head,
        "reports":record.reports.values().collect::<Vec<_>>()})),
    )
}

fn inbox_challenges(
    records: &BTreeMap<String, Record>, log: &Membership, origin: &str, signer: &str,
    slot: &str, expected: Head, now: u64, grant: Option<&external::Grant>,
) -> Result<Vec<ReportChallenge>, Reply> {
    ReportChallenge::new(signer, slot, origin, 1, now, now.saturating_add(1)).map_err(|_| invalid())?;
    if log.frozen().is_some() || expected != log.head() || !active(log, signer, now) { return Err(changed()) }
    let mut challenges = Vec::new();
    for record in records.values() {
        if record.closed || grant.is_some_and(|g| record.external_grant.as_ref() != Some(g) || !record.reports.is_empty()) {
            continue;
        }
        let challenge = ReportChallenge::parse(record.challenge.to_string().as_bytes()).map_err(|_| changed())?;
        if challenge.origin() == origin && challenge.signer() == signer && challenge.slot() == slot
            && challenge.issued_at() <= now && now < challenge.expires_at() && record.head == expected.to_json()
        {
            challenges.push(challenge);
        }
    }
    Ok(challenges)
}

pub(super) fn apply(
    records: &mut BTreeMap<String, Record>,
    log: &Membership,
    origin: &str,
    command: Command,
    now: u64,
) -> Result<Reply, Reply> {
    if log.frozen().is_some() {
        return Err(changed());
    }
    collect(records, now);
    let nonce = match command {
        Command::Inbox {
            signer,
            slot,
            expected,
        } => {
            let challenges = inbox_challenges(records, log, origin, &signer, &slot, expected, now, None)?
                .into_iter().map(|c| c.to_json()).collect::<Vec<_>>();
            return Ok((StatusCode::OK, Json(json!({"challenges":challenges}))));
        }
        Command::Create {
            challenge,
            expected,
        } => {
            if challenge.origin() != origin
                || challenge.issued_at() > now
                || now >= challenge.expires_at()
                || expected != log.head()
                || !active(log, challenge.signer(), now)
            {
                return Err(changed());
            }
            let nonce = URL_SAFE_NO_PAD.encode(challenge.nonce());
            let record = Record {
                challenge: challenge.to_json(),
                head: expected.to_json(),
                reports: BTreeMap::new(),
                closed: false,
                external_grant: None,
                first_external_fetch_ms: None,
                external_answered: false,
            };
            if let Some(previous) = records.get(&nonce) {
                if previous.challenge != record.challenge || previous.head != record.head {
                    return Err(changed());
                }
                if previous.closed {
                    return Err(closed());
                }
                return Ok(reply(previous));
            }
            if records.len() >= MAX_PENDING
                || records
                    .values()
                    .filter(|r| {
                        r.challenge["signer"] == record.challenge["signer"]
                            && r.challenge["slot"] == record.challenge["slot"]
                            && r.challenge["expires_at"]
                                .as_u64()
                                .is_some_and(|expiry| now < expiry)
                    })
                    .count()
                    >= MAX_PER_SLOT
            {
                return Err(error(
                    StatusCode::TOO_MANY_REQUESTS,
                    "verifier_report_limit",
                ));
            }
            records.insert(nonce.clone(), record);
            return Ok(reply(&records[&nonce]));
        }
        Command::Read { ref nonce }
        | Command::Publish { ref nonce, .. }
        | Command::Close { ref nonce } => nonce.clone(),
    };
    if !URL_SAFE_NO_PAD
        .decode(&nonce)
        .is_ok_and(|v| v.len() == 32 && URL_SAFE_NO_PAD.encode(v) == nonce)
    {
        return Err(invalid());
    }
    let record = records
        .get_mut(&nonce)
        .ok_or_else(|| error(StatusCode::NOT_FOUND, "verifier_report_not_found"))?;
    let challenge =
        ReportChallenge::parse(record.challenge.to_string().as_bytes()).map_err(|_| changed())?;
    if record.closed || now >= challenge.expires_at() {
        return Err(closed());
    }
    if challenge.origin() != origin
        || challenge.issued_at() > now
        || record.head != log.head().to_json()
        || !active(log, challenge.signer(), now)
    {
        return Err(changed());
    }
    match command {
        Command::Publish { report, .. } => {
            let bytes = jcs(&report).map_err(|_| invalid())?;
            let proof = verify_verifier_report(log, bytes.as_bytes(), &challenge, now)
                .map_err(|_| invalid())?;
            let process = URL_SAFE_NO_PAD.encode(proof.process);
            if let Some(previous) = record.reports.get(&process) {
                if previous["body"] != report["body"] {
                    return Err(changed());
                }
            } else {
                if record.reports.len() >= MAX_REPORTS {
                    return Err(error(
                        StatusCode::TOO_MANY_REQUESTS,
                        "verifier_report_limit",
                    ));
                }
                // Keep distinct authenticated processes: never hide a conflict by
                // selecting the latest response. Ancestors remain non-live evidence.
                record.reports.insert(process, report);
            }
        }
        Command::Close { .. } => {
            record.closed = true;
            record.reports.clear();
            return Ok((StatusCode::OK, Json(json!({"closed":true}))));
        }
        _ => {}
    }
    Ok(reply(record))
}

async fn access(state: &AppState, headers: &HeaderMap) -> Result<(String, String), Reply> {
    let owner = subject(state, headers).await?;
    let origin = state
        .recovery
        .delegated_origin
        .get()
        .cloned()
        .ok_or_else(|| {
            error(
                StatusCode::SERVICE_UNAVAILABLE,
                "delegated_host_work_not_verified",
            )
        })?;
    Ok((owner, origin))
}

async fn read_body(body: Body) -> Result<Value, Reply> {
    let bytes = to_bytes(body, MAX_BODY).await.map_err(|_| invalid())?;
    StrictValue::parse(&bytes, MAX_BODY)
        .map(|v| v.value().clone())
        .map_err(|_| invalid())
}

async fn perform(
    state: &AppState,
    genesis: &str,
    owner: &str,
    origin: String,
    command: Command,
) -> Reply {
    match tokio::time::timeout(
        Duration::from_secs(10),
        state.recovery.perform(
            genesis,
            owner,
            Operation::VerifierReport { origin, command },
        ),
    )
    .await
    {
        Ok(reply) => reply,
        Err(_) => error(
            StatusCode::SERVICE_UNAVAILABLE,
            "verifier_report_unavailable",
        ),
    }
}

pub(crate) async fn create(
    State(state): State<AppState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let (owner, origin) = match access(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let value = match read_body(body).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    if !fields(&value, &["challenge", "expected"]) {
        return invalid();
    }
    let (Ok(challenge), Some(expected)) = (
        ReportChallenge::parse(value["challenge"].to_string().as_bytes()),
        Head::from_json(&value["expected"]),
    ) else {
        return invalid();
    };
    perform(
        &state,
        &genesis,
        &owner,
        origin,
        Command::Create {
            challenge,
            expected,
        },
    )
    .await
}

pub(crate) async fn inbox(
    State(state): State<AppState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let (owner, origin) = match access(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let value = match read_body(body).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    if !fields(&value, &["signer", "slot", "expected"]) {
        return invalid();
    }
    let (Some(signer), Some(slot), Some(expected)) = (
        value["signer"].as_str(),
        value["slot"].as_str(),
        Head::from_json(&value["expected"]),
    ) else {
        return invalid();
    };
    perform(
        &state,
        &genesis,
        &owner,
        origin,
        Command::Inbox {
            signer: signer.into(),
            slot: slot.into(),
            expected,
        },
    )
    .await
}

pub(crate) async fn get(
    State(state): State<AppState>,
    Path((genesis, nonce)): Path<(String, String)>,
    headers: HeaderMap,
) -> Reply {
    let (owner, origin) = match access(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    perform(&state, &genesis, &owner, origin, Command::Read { nonce }).await
}

pub(crate) async fn publish(
    State(state): State<AppState>,
    Path((genesis, nonce)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let (owner, origin) = match access(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    let value = match read_body(body).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    if !fields(&value, &["report"]) {
        return invalid();
    }
    perform(
        &state,
        &genesis,
        &owner,
        origin,
        Command::Publish {
            nonce,
            report: value["report"].clone(),
        },
    )
    .await
}

pub(crate) async fn close(
    State(state): State<AppState>,
    Path((genesis, nonce)): Path<(String, String)>,
    headers: HeaderMap,
) -> Reply {
    let (owner, origin) = match access(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    perform(&state, &genesis, &owner, origin, Command::Close { nonce }).await
}

#[cfg(test)]
#[path = "verifier_reports/tests.rs"]
mod tests;
