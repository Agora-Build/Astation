//! Prepare the Station's own unsigned records while its recovery fence is closed.
use super::{invalid, source_hash, Binding, Prepared};
use crate::service_signing_ceilings::SigningMark;
use atem_client::{
    control::{
        ControlAbout, ControlAction, ControlBody, ControlFeed, ControlPrincipal, ControlSigner,
    },
    membership::Membership,
    Hash32,
};
use serde_json::{json, Value};
use sqlx::PgConnection;
use std::collections::BTreeMap;

struct Batch<'a> {
    service: &'a str,
    key: Hash32,
    above: u64,
    actions: Vec<ControlAction>,
}

struct DraftBatches<'a> {
    ready: Vec<Batch<'a>>,
    unresolved: Vec<Value>,
}

fn batches(review: &Value) -> Result<DraftBatches<'_>, sqlx::Error> {
    let portal = &review["portal_service_evidence"];
    let mut matched = BTreeMap::new();
    for row in portal["protected_service_keys"]
        .as_array()
        .ok_or_else(invalid)?
    {
        if row["status"] == "matched" {
            let id = row["service_id"].as_str().ok_or_else(invalid)?;
            let key = row["key_fingerprint"].as_str().ok_or_else(invalid)?;
            if matched
                .insert(
                    (id, key),
                    &row["signing_reservation"]["highest_reserved_ms"],
                )
                .is_some()
            {
                return Err(invalid());
            }
        }
    }
    let marks = &review["service_clock_evidence"]["snapshot_signing_marks"];
    let mut ready = Vec::new();
    let mut unresolved = Vec::new();
    for row in portal["services"].as_array().ok_or_else(invalid)? {
        let service = row["service_id"].as_str().ok_or_else(invalid)?;
        let key = row["key_fingerprint"].as_str().ok_or_else(invalid)?;
        let problem =
            |reason: &str| json!({"service_id":service,"key_fingerprint":key,"reason":reason});
        let snapshot = &row["snapshot_review"];
        let status = snapshot["status"].as_str().ok_or_else(invalid)?;
        let actions = match status {
            "reviewed" => snapshot["fresh_actions"].as_array(),
            "coverage_ended" | "coverage_unresolved"
                if snapshot.get("fresh_stop_actions").is_some() =>
            {
                snapshot["fresh_stop_actions"].as_array()
            }
            reason => {
                unresolved.push(problem(reason));
                continue;
            }
        }
        .ok_or_else(invalid)?;
        let actions = actions
            .iter()
            .map(|item| match item["action"].as_str() {
                Some("cover") => Ok(ControlAction::Cover),
                Some("hold") => Ok(ControlAction::Hold),
                Some("release") => Ok(ControlAction::Release),
                Some("revoke") => Ok(ControlAction::Revoke {
                    interrupt_running: item["interrupt_running"].as_bool().ok_or_else(invalid)?,
                }),
                Some("interrupt_running") => {
                    Ok(ControlAction::InterruptRunning { revoke_seq: None })
                }
                _ => Err(invalid()),
            })
            .collect::<Result<Vec<_>, _>>()?;
        // A new revoke can end coverage once signed. An interrupt alone cannot.
        if status == "coverage_unresolved"
            && !actions
                .iter()
                .any(|a| matches!(a, ControlAction::Revoke { .. }))
        {
            unresolved.push(problem(status));
        }
        if actions.is_empty() {
            continue;
        }
        let Some(reservation) = matched.get(&(service, key)) else {
            unresolved.push(problem("protected_key_unavailable"));
            continue;
        };
        let Some(ceiling) = reservation.as_u64() else {
            unresolved.push(problem("signing_reservation_missing"));
            continue;
        };
        let mark = serde_json::from_value::<SigningMark>(marks[format!("service:{service}")].clone()).ok();
        let Some(mark) = mark.filter(|m| m.key_fingerprint == key
            && m.highest_reserved_ms == ceiling && m.sign_above_ms >= ceiling) else {
            unresolved.push(problem("signing_mark_unavailable"));
            continue;
        };
        ready.push(Batch {
            service,
            key: Hash32::from_hex(key).map_err(|_| invalid())?,
            above: mark.sign_above_ms,
            actions,
        });
    }
    Ok(DraftBatches { ready, unresolved })
}

pub(super) fn review_source(review: &Value) -> Result<String, sqlx::Error> {
    source_hash(&json!({
        "reconstruction":review["reconstruction_hash"],
        "service_clock":review["service_clock_evidence_hash"],
        "portal":review["portal_service_evidence_hash"],
    }))
}

pub(super) async fn prepare(
    db: &mut PgConnection,
    plan: &Prepared,
    log: &Membership,
    binding: &Binding,
    review: &Value,
) -> Result<Value, sqlx::Error> {
    let observation = &review["portal_service_evidence"]["status"];
    if observation != "observed" {
        return Ok(json!({"status":"awaiting_policy","observation":observation}));
    }
    let DraftBatches { ready, unresolved } = batches(review)?;
    let source = review_source(review)?;
    let now = super::super::super::now().wall_ms;
    // Only elapsed milliseconds can be used. A future reservation can become
    // usable without any change to the Portal checkpoint or recovery evidence.
    let mut waiting = Vec::new();
    for batch in &ready {
        if now
            .checked_sub(batch.actions.len() as u64 - 1)
            .is_none_or(|first| first <= batch.above)
        {
            waiting.push(batch.service);
        }
    }
    if !waiting.is_empty() {
        return Ok(
            json!({"status":"waiting_for_clock","services":waiting,"source_hash":source,"unresolved_services":unresolved}),
        );
    }

    let saved: Option<(Value, String)> = sqlx::query_as(
        "SELECT bodies,bodies_hash FROM station_delegated_service_drafts WHERE plan_id=$1 AND source_hash=$2",
    ).bind(&plan.plan_id).bind(&source).fetch_optional(&mut *db).await?;
    let retry = saved.is_some();
    let mut saved_bodies = match &saved {
        Some((stored, hash)) if source_hash(stored)? == *hash => {
            Some(stored.as_array().ok_or_else(invalid)?.iter())
        }
        Some(_) => return Err(invalid()),
        None => None,
    };
    let mut bodies = Vec::new();
    let mut ids = std::collections::BTreeSet::new();
    for batch in &ready {
        let mut previous: Option<u64> = None;
        let first = now - (batch.actions.len() as u64 - 1);
        for (action, elapsed) in batch.actions.iter().zip(first..=now) {
            let persisted = match &mut saved_bodies {
                Some(values) => Some(values.next().ok_or_else(invalid)?),
                None => None,
            };
            let (record_id, issued_at) = match persisted {
                Some(value) => {
                    let body = ControlBody::from_json(value).map_err(|_| invalid())?;
                    (body.record_id, body.issued_at)
                }
                None => (uuid::Uuid::new_v4().to_string(), elapsed),
            };
            if issued_at <= batch.above
                || previous.is_some_and(|v| v.checked_add(1) != Some(issued_at))
                || !ids.insert(record_id.clone())
            {
                return Err(invalid());
            }
            if issued_at > now {
                return Ok(
                    json!({"status":"waiting_for_clock","services":[batch.service],"source_hash":source,"unresolved_services":unresolved}),
                );
            }
            previous = Some(issued_at);
            let body = ControlBody {
                account_id: log.account_id().into(),
                genesis_hash: log.genesis_hash(),
                feed: Some(ControlFeed {
                    origin: binding.origin.clone(),
                    feed_id: plan.candidate_feed_id.clone(),
                }),
                principal: ControlPrincipal::Service(batch.service.into()),
                principal_key: Some(batch.key),
                signer: ControlSigner::Principal,
                action: *action,
                record_id,
                issued_at,
                about: ControlAbout {
                    by: "reconciled".into(),
                    integration_id: Some(
                        batch
                            .service
                            .strip_prefix("svc-")
                            .ok_or_else(invalid)?
                            .into(),
                    ),
                },
            }
            .to_json();
            // A restored body's ID and time may be reused only for the same exact intent.
            if persisted.is_some_and(|value| value != &body) {
                return Err(invalid());
            }
            bodies.push(body);
        }
    }
    if saved_bodies.is_some_and(|mut v| v.next().is_some()) {
        return Err(invalid());
    }
    let bodies = Value::Array(bodies);
    let hash = source_hash(&bodies)?;
    if !retry {
        sqlx::query("INSERT INTO station_delegated_service_drafts(plan_id,source_hash,bodies,bodies_hash)
            VALUES ($1,$2,$3,$4) ON CONFLICT (plan_id) DO UPDATE SET source_hash=EXCLUDED.source_hash,
            bodies=EXCLUDED.bodies,bodies_hash=EXCLUDED.bodies_hash")
            .bind(&plan.plan_id).bind(&source).bind(&bodies).bind(&hash).execute(db).await?;
    }
    let status = if unresolved.is_empty() {
        "prepared"
    } else {
        "partial"
    };
    Ok(
        json!({"status":status,"source_hash":source,"bodies_hash":hash,
        "unsigned_bodies":bodies,"unresolved_services":unresolved}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_review_keeps_other_services_and_needs_no_key_for_a_carried_revoke() {
        let key = "a".repeat(64);
        let row = |id: &str, snapshot: Value| {
            json!({
                "service_id":id,"key_fingerprint":key,"snapshot_review":snapshot
            })
        };
        let matched = |id: &str, reservation: Value| {
            json!({
                "service_id":id,"key_fingerprint":key,"status":"matched","signing_reservation":reservation
            })
        };
        let hold =
            json!({"status":"reviewed","fresh_actions":[{"action":"cover"},{"action":"hold"}]});
        let revoke = json!({"status":"coverage_unresolved","fresh_stop_actions":[{"action":"revoke","interrupt_running":true}]});
        let review = json!({
            "portal_service_evidence":{
                "services":[row("svc-a",hold.clone()),row("svc-b",hold.clone()),row("svc-c",revoke),
                    row("svc-d",json!({"status":"coverage_ended","fresh_stop_actions":[]})),
                    row("svc-e",json!({"status":"coverage_unresolved","fresh_stop_actions":[]})),
                    row("svc-f",hold)],
                "protected_service_keys":[matched("svc-a",json!({"highest_reserved_ms":0})),
                    matched("svc-b",json!({"status":"missing"})),matched("svc-c",json!({"highest_reserved_ms":8})),
                    matched("svc-f",json!({"highest_reserved_ms":4}))]
            },
            "service_clock_evidence":{"snapshot_signing_marks":{
                "service:svc-a":{"key_fingerprint":key,"highest_reserved_ms":0,"sign_above_ms":3},
                "service:svc-c":{"key_fingerprint":key,"highest_reserved_ms":8,"sign_above_ms":8}
            }}
        });
        let plan = batches(&review).unwrap();
        assert_eq!(
            plan.ready
                .iter()
                .map(|batch| batch.service)
                .collect::<Vec<_>>(),
            ["svc-a", "svc-c"]
        );
        assert_eq!(
            plan.unresolved,
            vec![
                json!({"service_id":"svc-b","key_fingerprint":key,"reason":"signing_reservation_missing"}),
                json!({"service_id":"svc-e","key_fingerprint":key,"reason":"coverage_unresolved"}),
                json!({"service_id":"svc-f","key_fingerprint":key,"reason":"signing_mark_unavailable"}),
            ]
        );
    }
}
