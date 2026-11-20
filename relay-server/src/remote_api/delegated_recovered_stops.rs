//! Retain later native stops for recovery review. Importing evidence does not
//! reconstruct missing history, grant effects, sign, or open the recovery fence.
use super::super::Binding;
use super::{checkpoint, invalid};
use atem_client::{
    canonical::StrictValue,
    control::{verify_control, ControlAction, ControlCheck, ControlRecord, ControlSigner},
    membership::Membership,
};
use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool};
use std::collections::BTreeMap;

const MAX_INPUT: usize = 262_144;
const MAX_BATCH: usize = 64;
const MAX_RECORDS: i64 = 4096;
const MAX_BYTES: i64 = 16 * 1024 * 1024;

pub(crate) fn input_limit() -> usize {
    MAX_INPUT
}

fn parse(bytes: &[u8]) -> Result<(String, String, Vec<ControlRecord>), sqlx::Error> {
    let strict = StrictValue::parse(bytes, MAX_INPUT).map_err(|_| invalid())?;
    let value = strict.value();
    let object = value.as_object().ok_or_else(invalid)?;
    if object.len() != 3
        || !["plan_id", "source_hash", "records"]
            .iter()
            .all(|key| object.contains_key(*key))
    {
        return Err(invalid());
    }
    let plan = value["plan_id"].as_str().ok_or_else(invalid)?;
    let source = value["source_hash"].as_str().ok_or_else(invalid)?;
    let values = value["records"]
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= MAX_BATCH)
        .ok_or_else(invalid)?;
    let records = values
        .iter()
        .map(|value| {
            ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| invalid())?)
                .map_err(|_| invalid())
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok((plan.to_owned(), source.to_owned(), records))
}

pub(super) fn review(record: &ControlRecord, log: &Membership, origin: &str) -> Result<Value, sqlx::Error> {
    if record.account_id() != log.account_id()
        || record.genesis_hash() != log.genesis_hash()
        || !matches!(record.signer(), ControlSigner::Member(_))
        || !matches!(
            record.action(),
            ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. }
        )
        || record
            .feed()
            .is_some_and(|(record_origin, _)| record_origin != origin)
    {
        return Err(invalid());
    }
    // Unknown/removed authority is retained as an unresolved obligation, never
    // promoted to a currently effective stop or a clock-completeness claim.
    // A valid native signature identifies a future recovery obligation only;
    // it does not settle missing authority/history or make recovery ready.
    let (verification, requirement) = match verify_control(record, log) {
        ControlCheck::Valid(_) => (
            "valid".to_owned(),
            if record.feed().is_some() {
                "fresh_manager_signature"
            } else {
                "retain_host_record"
            },
        ),
        ControlCheck::Pending(reason) => (format!("pending:{}", reason.code()), "authority_review"),
        ControlCheck::Refused(reason) => (reason.code().to_owned(), "authority_review"),
    };
    Ok(json!({
        "record_id": record.record_id(), "principal": record.principal().name(),
        "signer": record.signer().name(record.principal()), "action": record.action().name(),
        "interrupt_running": matches!(record.action(), ControlAction::Revoke { interrupt_running: true } | ControlAction::InterruptRunning { .. }),
        "revoke_seq": match record.action() { ControlAction::InterruptRunning { revoke_seq } => revoke_seq, _ => None },
        "issued_at": record.issued_at(), "verification": verification, "requirement": requirement,
    }))
}

pub(crate) async fn retain(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    bytes: &[u8],
) -> Result<Value, sqlx::Error> {
    let (plan_id, source_hash, incoming) = parse(bytes)?;
    let mut tx = pool.begin().await?;
    let (prepared, log, mut report) = checkpoint(&mut tx, binding, genesis, false).await?;
    if plan_id != prepared.plan_id || source_hash != prepared.source_hash {
        return Err(invalid());
    }
    retain_records(&mut tx, &prepared, &log, binding, incoming).await?;
    super::review_evidence(&mut tx, &prepared, &log, binding, &mut report).await?;
    tx.commit().await?;
    Ok(report)
}

pub(super) async fn retain_records(
    connection: &mut PgConnection,
    prepared: &super::Prepared,
    log: &Membership,
    binding: &Binding,
    incoming: Vec<ControlRecord>,
) -> Result<(), sqlx::Error> {
    let mut retained = BTreeMap::new();
    for value in prepared.retained["feed"]["records"]
        .as_array()
        .ok_or_else(invalid)?
    {
        let record = ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        retained.insert(record.record_id().to_owned(), value.clone());
    }
    let mut recovered = load(connection, binding, &log.genesis_hash().to_hex()).await?;
    for (id, value) in &recovered {
        if retained.get(id).is_some_and(|prior| prior != value) {
            return Err(invalid());
        }
    }
    for record in incoming {
        review(&record, log, &binding.origin)?;
        let value = record.object().to_json();
        let id = record.record_id();
        if recovered
            .get(id)
            .or_else(|| retained.get(id))
            .is_some_and(|prior| prior != &value)
        {
            return Err(invalid());
        }
        if recovered.contains_key(id) {
            continue;
        }
        // Checkpoint equality is not an imported obligation: a later restored
        // source may omit it, so retain the accepted import independently.
        recovered.insert(id.to_owned(), value.clone());
        sqlx::query("INSERT INTO station_delegated_recovered_stops(plan_id,record_id,record) VALUES ($1,$2,$3)")
            .bind(&prepared.plan_id).bind(id).bind(value).execute(&mut *connection).await?;
    }
    Ok(())
}

pub(super) async fn load(
    connection: &mut PgConnection,
    binding: &Binding,
    genesis: &str,
) -> Result<BTreeMap<String, Value>, sqlx::Error> {
    // A later recovery generation cannot hide an earlier imported stop.
    // Deduplicate identical objects, but preserve conflicts as a refusal.
    let history = "SELECT DISTINCT r.record_id,r.record FROM station_delegated_recovered_stops r \
        JOIN station_delegated_recovery_plans p ON p.plan_id=r.plan_id \
        WHERE p.origin=$1 AND p.genesis_hash=$2 AND p.generation <= $3";
    // PostgreSQL's persisted JSONB text size, not just canonical input length.
    let (count, size): (i64, i64) = sqlx::query_as(&format!(
        "SELECT count(*)::bigint,COALESCE(sum(octet_length(record::text)),0)::bigint FROM ({history}) history"))
    .bind(&binding.origin).bind(genesis).bind(binding.generation)
    .fetch_one(&mut *connection)
    .await?;
    if count > MAX_RECORDS || size > MAX_BYTES {
        return Err(invalid());
    }
    let records: Vec<(String, Value)> = sqlx::query_as(&format!("{history} ORDER BY record_id"))
        .bind(&binding.origin)
        .bind(genesis)
        .bind(binding.generation)
        .fetch_all(&mut *connection)
        .await?;
    let mut recovered = BTreeMap::new();
    for (id, value) in records {
        if recovered
            .insert(id, value.clone())
            .is_some_and(|prior| prior != value)
        {
            return Err(invalid());
        }
    }
    Ok(recovered)
}

pub(super) async fn inspection(
    connection: &mut PgConnection,
    prepared: &super::Prepared,
    log: &Membership,
    binding: &Binding,
) -> Result<Value, sqlx::Error> {
    let recovered = load(connection, binding, &log.genesis_hash().to_hex()).await?;
    let mut retained = BTreeMap::new();
    for value in prepared.retained["feed"]["records"]
        .as_array()
        .ok_or_else(invalid)?
    {
        let record = ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        retained.insert(record.record_id().to_owned(), value);
    }
    let mut lower_bounds = BTreeMap::<String, u64>::new();
    let mut reviews = Vec::new();
    for (id, value) in &recovered {
        let record = ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        if id != record.record_id() || retained.get(id).is_some_and(|prior| *prior != value) {
            return Err(invalid());
        }
        // These are only observed lower bounds. Even a valid signature cannot
        // establish that a later signature or reservation was never made.
        if matches!(verify_control(&record, &log), ControlCheck::Valid(_)) {
            let time = lower_bounds.entry(record.principal().name()).or_default();
            *time = (*time).max(record.issued_at());
        }
        reviews.push(review(&record, log, &binding.origin)?);
    }
    let evidence_hash = super::source_hash(&json!(recovered))?;
    Ok(json!({
        "evidence_hash": evidence_hash, "records": reviews,
        "observed_issued_at_lower_bounds": lower_bounds,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovered_stop_import_refuses_duplicate_keys_on_otherwise_accepted_input() {
        let vectors: Value = serde_json::from_str(include_str!(
            "fixtures/delegated/r9-vectors-host-work-control.json"
        )).unwrap();
        let payload = json!({
            "plan_id": "plan", "source_hash": "hash",
            "records": [vectors["records"][0]["record"].clone()],
        });
        let accepted = payload.to_string();
        assert!(parse(accepted.as_bytes()).is_ok());
        for (key, prior) in [("plan_id", "wrong"), ("signer", "member:other")] {
            let duplicate = accepted.replacen(
                &format!("\"{key}\":"),
                &format!("\"{key}\":\"{prior}\",\"{key}\":"),
                1,
            );
            assert_ne!(duplicate, accepted);
            assert_eq!(serde_json::from_str::<Value>(&duplicate).unwrap(), payload);
            assert!(parse(duplicate.as_bytes()).is_err());
        }
    }

    #[test]
    fn recovered_stop_import_is_strict_and_bounded_before_storage() {
        for bytes in [
            b"null".as_slice(),
            b"{}",
            b"{\"plan_id\":\"a\",\"plan_id\":\"b\",\"source_hash\":\"h\",\"records\":[]}",
            b"{\"plan_id\":null,\"source_hash\":\"h\",\"records\":[]}",
            b"{\"plan_id\":\"a\",\"source_hash\":\"h\",\"records\":[]}",
        ] {
            assert!(parse(bytes).is_err());
        }
        assert!(parse(&vec![b' '; MAX_INPUT + 1]).is_err());
    }
}
