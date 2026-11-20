//! Import the native export whole: signed stops, unsigned intent and original
//! destinations stay distinct. An unsigned review never becomes a stop or clock.
use super::super::Binding;
use super::{checkpoint, invalid, source_hash, stops, Prepared};
use atem_client::{
    canonical::StrictValue,
    control::{ControlAction, ControlBody, ControlRecord, ControlSigner},
    membership::Membership,
    station_route::normalize_relay,
};
use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const INPUT_LIMIT: usize = 8 * 1024 * 1024;
const MAX_ARCHIVES: i64 = 128;
const MAX_BYTES: i64 = 16 * 1024 * 1024;

struct Archive {
    value: Value,
    signed: Vec<ControlRecord>,
    bodies: BTreeMap<String, ControlBody>,
    unsigned: BTreeSet<String>,
}

fn parse(bytes: &[u8]) -> Result<Archive, sqlx::Error> {
    let value = StrictValue::parse(bytes, INPUT_LIMIT)
        .map_err(|_| invalid())?
        .value()
        .clone();
    let fields = [
        "type",
        "version",
        "account_id",
        "genesis_hash",
        "station_origin",
        "destinations",
        "retained_history_only",
        "complete_history",
        "signing_clock_complete",
        "snapshot_complete",
        "records",
        "unsigned_reviews",
    ];
    let object = value.as_object().ok_or_else(invalid)?;
    if object.len() != fields.len()
        || !fields.iter().all(|key| object.contains_key(*key))
        || value["type"] != "astation-native-control-recovery-evidence"
        || value["version"] != 1
        || value["retained_history_only"] != true
        || value["complete_history"] != false
        || value["signing_clock_complete"] != false
        || value["snapshot_complete"] != false
    {
        return Err(invalid());
    }
    let origin = value["station_origin"].as_str().ok_or_else(invalid)?;
    if normalize_relay(origin).ok().as_deref() != Some(origin) {
        return Err(invalid());
    }
    let signed_values = value["records"].as_array().ok_or_else(invalid)?;
    let unsigned_values = value["unsigned_reviews"].as_array().ok_or_else(invalid)?;
    if signed_values.len() + unsigned_values.len() > 256 {
        return Err(invalid());
    }
    let signed = signed_values
        .iter()
        .map(|record| {
            ControlRecord::parse(&serde_json::to_vec(record).map_err(|_| invalid())?)
                .map_err(|_| invalid())
        })
        .collect::<Result<Vec<_>, _>>()?;
    let mut unsigned = BTreeSet::new();
    let mut bodies = BTreeMap::new();
    for body in signed
        .iter()
        .map(|record| Ok::<_, sqlx::Error>(record.body().clone()))
        .chain(unsigned_values.iter().map(|body| {
            let body = ControlBody::from_json(body).map_err(|_| invalid())?;
            unsigned.insert(body.record_id.clone());
            Ok(body)
        }))
    {
        let body: ControlBody = body?;
        if value["account_id"] != body.account_id
            || value["genesis_hash"] != body.genesis_hash.to_hex()
            || !matches!(body.signer, ControlSigner::Member(_))
            || !matches!(
                body.action,
                ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. }
            )
            || body.feed.as_ref().is_some_and(|feed| feed.origin != origin)
            || bodies.insert(body.record_id.clone(), body).is_some()
        {
            return Err(invalid());
        }
    }
    let routes = value["destinations"].as_object().ok_or_else(invalid)?;
    if routes.len() != bodies.len() {
        return Err(invalid());
    }
    for (id, body) in &bodies {
        let destinations = routes
            .get(id)
            .and_then(Value::as_array)
            .ok_or_else(invalid)?;
        if destinations.is_empty()
            || destinations.len() > 64
            || destinations[0] != origin
            || (body.feed.is_some() && destinations.len() != 1)
        {
            return Err(invalid());
        }
        let mut seen = BTreeSet::new();
        for destination in destinations {
            let destination = destination.as_str().ok_or_else(invalid)?;
            if normalize_relay(destination).ok().as_deref() != Some(destination)
                || !seen.insert(destination)
            {
                return Err(invalid());
            }
        }
    }
    Ok(Archive {
        value,
        signed,
        bodies,
        unsigned,
    })
}

pub(crate) async fn retain(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    plan_id: &str,
    bytes: &[u8],
) -> Result<Value, sqlx::Error> {
    let archive = parse(bytes)?;
    let mut tx = pool.begin().await?;
    let (prepared, log, mut report) = checkpoint(&mut tx, binding, genesis, false).await?;
    if prepared.plan_id != plan_id
        || archive.value["account_id"] != log.account_id()
        || archive.value["genesis_hash"] != genesis
        || archive.value["station_origin"] != binding.origin
    {
        return Err(invalid());
    }
    let hash = source_hash(&archive.value)?;
    sqlx::query("INSERT INTO station_delegated_native_recovery(plan_id,evidence_hash,archive) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING")
        .bind(plan_id).bind(hash).bind(&archive.value).execute(&mut *tx).await?;
    stops::retain_records(&mut tx, &prepared, &log, binding, archive.signed).await?;
    super::review_evidence(&mut tx, &prepared, &log, binding, &mut report).await?;
    tx.commit().await?;
    Ok(report)
}

pub(super) async fn inspection(
    connection: &mut PgConnection,
    prepared: &Prepared,
    log: &Membership,
    binding: &Binding,
    signed: &BTreeMap<String, Value>,
) -> Result<Value, sqlx::Error> {
    let selection = "FROM station_delegated_native_recovery n JOIN station_delegated_recovery_plans p ON p.plan_id=n.plan_id \
        WHERE p.origin=$1 AND p.genesis_hash=$2 AND p.generation <= $3";
    let (count, bytes): (i64, i64) = sqlx::query_as(&format!(
        "SELECT count(*)::bigint,COALESCE(sum(octet_length(archive::text)),0)::bigint {selection}"
    ))
    .bind(&binding.origin)
    .bind(log.genesis_hash().to_hex())
    .bind(binding.generation)
    .fetch_one(&mut *connection)
    .await?;
    if count > MAX_ARCHIVES || bytes > MAX_BYTES {
        return Err(invalid());
    }
    let archives: Vec<(String, Value, String)> = sqlx::query_as(&format!(
        "SELECT n.evidence_hash,n.archive,p.retained->>'account_subject' {selection} ORDER BY n.evidence_hash,p.generation"))
        .bind(&binding.origin).bind(log.genesis_hash().to_hex()).bind(binding.generation)
        .fetch_all(&mut *connection).await?;
    let mut commitments = BTreeMap::new();
    let mut bodies = BTreeMap::new();
    let mut summaries = BTreeMap::new();
    for (hash, value, subject) in archives {
        let archive = parse(&serde_json::to_vec(&value).map_err(|_| invalid())?)?;
        if source_hash(&value)? != hash
            || value["account_id"] != log.account_id()
            || value["genesis_hash"] != log.genesis_hash().to_hex()
            || value["station_origin"] != binding.origin
            || prepared.retained["account_subject"] != subject
        {
            return Err(invalid());
        }
        if archive
            .signed
            .iter()
            .any(|record| signed.get(record.record_id()) != Some(&record.object().to_json()))
        {
            // The whole archive is retained evidence. Missing a signed-stop
            // row must refuse reconstruction, never silently drop its stop.
            return Err(invalid());
        }
        let mut reviews = Vec::new();
        for (id, body) in &archive.bodies {
            let value = body.to_json();
            if signed.get(id).is_some_and(|record| record["body"] != value)
                || bodies
                    .insert(id.clone(), value.clone())
                    .is_some_and(|old| old != value)
                || bodies.len() > 4096
            {
                return Err(invalid());
            }
            if archive.unsigned.contains(id) {
                reviews.push(json!({"record_id": id, "principal": body.principal.name(),
                    "signer": body.signer.name(&body.principal), "action": body.action.name(),
                    "issued_at": body.issued_at,
                    "interrupt_running": matches!(body.action, ControlAction::Revoke { interrupt_running: true } | ControlAction::InterruptRunning { .. }),
                    "requirement": "unsigned_owner_intent"}));
            }
        }
        summaries.insert(
            hash.clone(),
            json!({"evidence_hash": hash, "signed_records": archive.signed.len(),
            "unsigned_reviews": reviews, "destinations": archive.value["destinations"]}),
        );
        commitments.insert(hash, value);
    }
    Ok(
        json!({"archives": summaries.into_values().collect::<Vec<_>>(),
        "evidence_hash": source_hash(&json!(commitments))?,
        "unsigned_intent_is_authority": false, "complete_history": false, "signing_clock_complete": false}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Value {
        let vectors: Value = serde_json::from_str(include_str!(
            "fixtures/delegated/r9-vectors-host-work-control.json"
        ))
        .unwrap();
        let record = vectors["records"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| &row["record"])
            .find(|record| {
                record["body"]["signer"]
                    .as_str()
                    .is_some_and(|s| s.starts_with("member:"))
                    && record["body"]["origin"].is_string()
            })
            .unwrap();
        let body = &record["body"];
        let mut destinations = serde_json::Map::new();
        destinations.insert(
            body["record_id"].as_str().unwrap().into(),
            json!([body["origin"]]),
        );
        json!({"type":"astation-native-control-recovery-evidence", "version":1,
            "account_id":body["account_id"], "genesis_hash":body["genesis_hash"], "station_origin":body["origin"],
            "destinations":destinations, "retained_history_only":true, "complete_history":false,
            "signing_clock_complete":false, "snapshot_complete":false, "records":[record], "unsigned_reviews":[]})
    }

    #[test]
    fn native_recovery_archive_parser_is_strict_and_never_accepts_added_authority() {
        let sample = sample();
        let bytes = serde_json::to_vec(&sample).unwrap();
        assert!(parse(&bytes).is_ok());
        let text = String::from_utf8(bytes).unwrap();
        for key in ["version", "station_origin", "record_id"] {
            let duplicate = text.replacen(
                &format!("\"{key}\":"),
                &format!("\"{key}\":null,\"{key}\":"),
                1,
            );
            assert_ne!(duplicate, text);
            assert!(parse(duplicate.as_bytes()).is_err());
        }
        for (key, value) in [
            ("version", json!(2)),
            ("complete_history", json!(true)),
            ("snapshot_complete", json!(true)),
            ("signing_clock_complete", json!(true)),
            ("retained_history_only", json!(false)),
            ("extra", Value::Null),
            ("destinations", json!({})),
        ] {
            let mut bad = sample.clone();
            bad[key] = value;
            assert!(parse(&serde_json::to_vec(&bad).unwrap()).is_err(), "{key}");
        }
        assert!(parse(&vec![b' '; INPUT_LIMIT + 1]).is_err());
    }

    #[test]
    fn native_recovery_archive_refuses_route_substitution_and_signed_unsigned_id_collisions() {
        let sample = sample();
        let id = sample["records"][0]["body"]["record_id"].as_str().unwrap();
        for routes in [
            json!([]),
            json!(["https://other.example"]),
            json!([sample["station_origin"], sample["station_origin"]]),
            json!([sample["station_origin"], "https://other.example"]),
            json!([sample["station_origin"], null]),
        ] {
            let mut bad = sample.clone();
            bad["destinations"][id] = routes;
            assert!(parse(&serde_json::to_vec(&bad).unwrap()).is_err());
        }
        let mut bad = sample.clone();
        bad["unsigned_reviews"] = json!([bad["records"][0]["body"]]);
        assert!(parse(&serde_json::to_vec(&bad).unwrap()).is_err());
        bad = sample.clone();
        bad["records"] = json!(vec![bad["records"][0].clone(); 257]);
        assert!(parse(&serde_json::to_vec(&bad).unwrap()).is_err());
    }
}
