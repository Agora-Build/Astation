//! Prepare the Station's own unsigned records while its recovery fence is closed.
use super::{invalid, source_hash, Binding, Prepared};
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

fn batches(review: &Value) -> Result<Vec<Batch<'_>>, sqlx::Error> {
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
    let mut result = Vec::new();
    for row in portal["services"].as_array().ok_or_else(invalid)? {
        let service = row["service_id"].as_str().ok_or_else(invalid)?;
        let key = row["key_fingerprint"].as_str().ok_or_else(invalid)?;
        let mark = &marks[format!("service:{service}")];
        let Some(ceiling) = matched
            .get(&(service, key))
            .and_then(|value| value.as_u64())
        else {
            continue;
        };
        if mark["key_fingerprint"] != key || mark["highest_reserved_ms"].as_u64() != Some(ceiling) {
            continue;
        }
        let snapshot = &row["snapshot_review"];
        let actions = match snapshot["status"].as_str() {
            Some("reviewed") => snapshot["fresh_actions"].as_array(),
            Some("coverage_ended" | "coverage_unresolved")
                if snapshot.get("fresh_stop_actions").is_some() =>
            {
                snapshot["fresh_stop_actions"].as_array()
            }
            _ => continue,
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
        if !actions.is_empty() {
            result.push(Batch {
                service,
                key: Hash32::from_hex(key).map_err(|_| invalid())?,
                above: mark["sign_above_ms"].as_u64().ok_or_else(invalid)?,
                actions,
            });
        }
    }
    Ok(result)
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
    let batches = batches(review)?;
    let source = source_hash(&json!({
        "reconstruction":review["reconstruction_hash"],
        "service_clock":review["service_clock_evidence_hash"],
        "portal":review["portal_service_evidence_hash"],
    }))?;
    let now = super::super::super::now().wall_ms;
    // Only elapsed milliseconds can be used. A future reservation can become
    // usable without any change to the Portal checkpoint or recovery evidence.
    let mut waiting = Vec::new();
    for batch in &batches {
        if now
            .checked_sub(batch.actions.len() as u64 - 1)
            .is_none_or(|first| first <= batch.above)
        {
            waiting.push(batch.service);
        }
    }
    if !waiting.is_empty() {
        return Ok(json!({"status":"waiting_for_clock","services":waiting,"source_hash":source}));
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
    for batch in &batches {
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
                    json!({"status":"waiting_for_clock","services":[batch.service],"source_hash":source}),
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
    Ok(
        json!({"status":"prepared","source_hash":source,"bodies_hash":hash,"unsigned_bodies":bodies}),
    )
}
