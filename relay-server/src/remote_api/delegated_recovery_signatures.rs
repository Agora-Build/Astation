//! Retain fresh manager copies for a recovery snapshot. These signatures never
//! supply missing history, clock completeness, publication or reopening authority.
use super::super::Binding;
use super::{invalid, source_hash, Prepared};
use atem_client::{
    canonical::StrictValue,
    control::{
        verify_control, ControlAction, ControlCheck, ControlFeed, ControlRecord, ControlSigner,
    },
    membership::Membership,
    Hash32,
};
use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const INPUT_LIMIT: usize = 262_144;
const MAX_RECORDS: i64 = 4096;
const MAX_BYTES: i64 = 16 * 1024 * 1024;

struct Input {
    evidence_hash: String,
    replacements: Vec<(String, ControlRecord)>,
}

fn parse(bytes: &[u8]) -> Result<Input, sqlx::Error> {
    let strict = StrictValue::parse(bytes, INPUT_LIMIT).map_err(|_| invalid())?;
    let value = strict.value();
    let object = value.as_object().ok_or_else(invalid)?;
    if object.len() != 2
        || !object.contains_key("evidence_hash")
        || !object.contains_key("replacements")
    {
        return Err(invalid());
    }
    let evidence_hash = value["evidence_hash"].as_str().ok_or_else(invalid)?;
    Hash32::from_hex(evidence_hash).map_err(|_| invalid())?;
    let values = value["replacements"]
        .as_array()
        .filter(|values| !values.is_empty() && values.len() <= 64)
        .ok_or_else(invalid)?;
    let mut originals = BTreeSet::new();
    let mut ids = BTreeSet::new();
    let mut replacements = Vec::new();
    for value in values {
        let row = value.as_object().ok_or_else(invalid)?;
        if row.len() != 2 || !row.contains_key("original_record_id") || !row.contains_key("record")
        {
            return Err(invalid());
        }
        let original = value["original_record_id"].as_str().ok_or_else(invalid)?;
        let record =
            ControlRecord::parse(&serde_json::to_vec(&value["record"]).map_err(|_| invalid())?)
                .map_err(|_| invalid())?;
        if !super::canonical_uuid(original)
            || !originals.insert(original.to_owned())
            || !ids.insert(record.record_id().to_owned())
        {
            return Err(invalid());
        }
        replacements.push((original.to_owned(), record));
    }
    Ok(Input {
        evidence_hash: evidence_hash.into(),
        replacements,
    })
}

fn check_copy(
    original: &ControlRecord,
    record: &ControlRecord,
    origin: &str,
    candidate: &str,
) -> Result<(), sqlx::Error> {
    if !matches!(original.signer(), ControlSigner::Member(_))
        || !matches!(record.signer(), ControlSigner::Member(_))
        || !matches!(
            original.action(),
            ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. }
        )
        || original.record_id() == record.record_id()
        || original.issued_at() >= record.issued_at()
        || original
            .feed()
            .is_some_and(|(old_origin, _)| old_origin != origin)
    {
        return Err(invalid());
    }
    let mut expected = original.body().clone();
    expected.feed = original.feed().map(|_| ControlFeed {
        origin: origin.into(),
        feed_id: candidate.into(),
    });
    expected.record_id = record.record_id().into();
    expected.issued_at = record.issued_at();
    expected.signer = record.signer().clone();
    if &expected != record.body() {
        return Err(invalid());
    }
    Ok(())
}

#[derive(sqlx::FromRow)]
struct Retained {
    plan_id: String,
    record_id: String,
    original_record_id: String,
    evidence_hash: String,
    record: Value,
    candidate_feed_id: String,
    subject: String,
    membership: Value,
}

async fn load(
    connection: &mut PgConnection,
    prepared: &Prepared,
    log: &Membership,
    binding: &Binding,
    signed: &BTreeMap<String, Value>,
    report: &Value,
) -> Result<(Vec<Retained>, BTreeMap<String, u64>), sqlx::Error> {
    let selection = "FROM station_delegated_recovery_signatures s \
        JOIN station_delegated_recovery_plans p ON p.plan_id=s.plan_id \
        WHERE p.origin=$1 AND p.genesis_hash=$2 AND p.generation <= $3";
    let (count, bytes): (i64, i64) = sqlx::query_as(&format!(
        "SELECT count(*)::bigint,COALESCE(sum(octet_length(record::text)),0)::bigint {selection}"
    ))
    .bind(&binding.origin)
    .bind(log.genesis_hash().to_hex())
    .bind(binding.generation)
    .fetch_one(&mut *connection)
    .await?;
    if count > MAX_RECORDS || bytes > MAX_BYTES {
        return Err(invalid());
    }
    let rows: Vec<Retained> = sqlx::query_as(&format!(
        "SELECT s.plan_id,s.record_id,s.original_record_id,s.evidence_hash,s.record, \
         p.candidate_feed_id,p.retained->>'account_subject' AS subject,p.retained->'membership' AS membership \
         {selection} ORDER BY p.generation,s.record_id"))
        .bind(&binding.origin).bind(log.genesis_hash().to_hex()).bind(binding.generation)
        .fetch_all(&mut *connection).await?;
    let mut lower_bounds = BTreeMap::new();
    let mut ids = BTreeSet::new();
    for row in &rows {
        let original = signed.get(&row.original_record_id).ok_or_else(invalid)?;
        let original = ControlRecord::parse(&serde_json::to_vec(original).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        let record = ControlRecord::parse(&serde_json::to_vec(&row.record).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        check_copy(&original, &record, &binding.origin, &row.candidate_feed_id)?;
        let accepted_log =
            Membership::from_stored(log.account_id(), &log.genesis_hash(), &row.membership)
                .map_err(|_| invalid())?;
        if prepared.retained["account_subject"] != row.subject
            || !super::canonical_uuid(&row.plan_id)
            || !super::canonical_uuid(&row.candidate_feed_id)
            || row.record_id != record.record_id()
            || Hash32::from_hex(&row.evidence_hash).is_err()
            || signed
                .get(&row.record_id)
                .is_some_and(|known| known != &row.record)
            || unsigned_id(report, &row.record_id)
            || accepted_log.frozen().is_some()
            || !matches!(
                verify_control(&record, &accepted_log),
                ControlCheck::Valid(_)
            )
            || !ids.insert(row.record_id.clone())
        {
            return Err(invalid());
        }
        // Even a subsequently removed manager's accepted signature stays a
        // clock obligation. Its current authority is reported separately.
        let lower = lower_bounds
            .entry(record.principal().name())
            .or_insert(0u64);
        *lower = (*lower).max(record.issued_at());
    }
    Ok((rows, lower_bounds))
}

fn unsigned_id(report: &Value, id: &str) -> bool {
    report["native_archives"]["archives"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|archive| {
            archive["unsigned_reviews"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|review| review["record_id"] == id)
        })
}

pub(crate) async fn retain(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    plan_id: &str,
    bytes: &[u8],
) -> Result<Value, sqlx::Error> {
    retain_checked(pool, binding, genesis, plan_id, bytes, None).await
}

pub(crate) async fn retain_for_owner(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    plan_id: &str,
    bytes: &[u8],
    owner: &str,
) -> Result<Value, sqlx::Error> {
    retain_checked(pool, binding, genesis, plan_id, bytes, Some(owner)).await
}

async fn retain_checked(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    plan_id: &str,
    bytes: &[u8],
    owner: Option<&str>,
) -> Result<Value, sqlx::Error> {
    let input = parse(bytes)?;
    let record_ids: Vec<_> = input.replacements.iter().map(|(_, record)| record.record_id().to_owned()).collect();
    let mut tx = pool.begin().await?;
    let (prepared, log, mut report) = super::checkpoint_for_owner(&mut tx, binding, genesis, false, owner).await?;
    let signed = super::review_source_evidence(&mut tx, &prepared, &log, binding, &mut report, false).await?;
    if prepared.plan_id != plan_id || report["evidence_hash"] != input.evidence_hash {
        return Err(invalid());
    }
    let (rows, mut lower_bounds) =
        load(&mut tx, &prepared, &log, binding, &signed, &report).await?;
    for (principal, value) in report["known_history"]["observed_signing_lower_bounds"]
        .as_object()
        .ok_or_else(invalid)?
    {
        let lower = lower_bounds.entry(principal.clone()).or_default();
        *lower = (*lower).max(value.as_u64().ok_or_else(invalid)?);
    }
    for (original_id, record) in input.replacements {
        let original = signed.get(&original_id).ok_or_else(invalid)?;
        let original = ControlRecord::parse(&serde_json::to_vec(original).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        check_copy(
            &original,
            &record,
            &binding.origin,
            &prepared.candidate_feed_id,
        )?;
        if !matches!(verify_control(&record, &log), ControlCheck::Valid(_))
            || signed.contains_key(record.record_id())
            || unsigned_id(&report, record.record_id())
        {
            return Err(invalid());
        }
        let value = record.object().to_json();
        if let Some(prior) = rows.iter().find(|row| {
            row.record_id == record.record_id()
                || (row.plan_id == plan_id
                    && row.original_record_id == original_id
                    && row.evidence_hash == input.evidence_hash)
        }) {
            if prior.plan_id != plan_id
                || prior.original_record_id != original_id
                || prior.evidence_hash != input.evidence_hash
                || prior.record != value
            {
                return Err(invalid());
            }
            continue;
        }
        let lower = lower_bounds.entry(record.principal().name()).or_default();
        if record.issued_at() <= *lower {
            return Err(invalid());
        }
        *lower = record.issued_at();
        sqlx::query(
            "INSERT INTO station_delegated_recovery_signatures \
            (plan_id,record_id,original_record_id,evidence_hash,record) VALUES ($1,$2,$3,$4,$5)",
        )
        .bind(plan_id)
        .bind(record.record_id())
        .bind(&original_id)
        .bind(&input.evidence_hash)
        .bind(value)
        .execute(&mut *tx)
        .await?;
    }
    super::review_evidence(&mut tx, &prepared, &log, binding, &mut report, owner.is_none()).await?;
    if owner.is_some() {
        report = json!({"version":1,"account_id":log.account_id(),"genesis_hash":genesis,
            "origin":binding.origin,"generation":binding.generation.to_string(),"plan_id":plan_id,
            "evidence_hash":input.evidence_hash,"record_ids":record_ids,
            "reconstruction_hash":report["reconstruction_hash"],"retained_only":true,"recovery_ready":false});
    }
    tx.commit().await?;
    Ok(report)
}

pub(super) async fn inspection(
    connection: &mut PgConnection,
    prepared: &Prepared,
    log: &Membership,
    binding: &Binding,
    report: &Value,
    signed: &BTreeMap<String, Value>,
) -> Result<Value, sqlx::Error> {
    let (rows, lower_bounds) = load(connection, prepared, log, binding, signed, report).await?;
    let mut commitments = Vec::new();
    let mut summaries = Vec::new();
    let mut current_copies = BTreeMap::new();
    for row in rows {
        let record = ControlRecord::parse(&serde_json::to_vec(&row.record).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        let verification = match verify_control(&record, log) {
            ControlCheck::Valid(_) => "valid".to_owned(),
            ControlCheck::Pending(reason) => format!("pending:{}", reason.code()),
            ControlCheck::Refused(reason) => reason.code().to_owned(),
        };
        let current_review =
            row.plan_id == prepared.plan_id && report["evidence_hash"] == row.evidence_hash;
        if current_review
            && verification == "valid"
            && current_copies
                .insert(row.original_record_id.clone(), row.record_id.clone())
                .is_some()
        {
            return Err(invalid());
        }
        summaries.push(json!({"original_record_id":row.original_record_id,"record_id":row.record_id,
            "principal":record.principal().name(),"issued_at":record.issued_at(),"verification":verification,
            "current_review":current_review,
            "source_evidence_hash":row.evidence_hash,"plan_id":row.plan_id}));
        commitments.push(json!({"plan_id":row.plan_id,"record_id":row.record_id,
            "original_record_id":row.original_record_id,"evidence_hash":row.evidence_hash,"record":row.record}));
    }
    let mut obligations = Vec::new();
    for value in signed.values() {
        let record = ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        if !matches!(record.signer(), ControlSigner::Member(_)) {
            continue;
        }
        let original = super::stops::review(&record, log, &binding.origin)?;
        let copy = current_copies.get(record.record_id());
        let requirement = if copy.is_some() {
            "signed_copy_retained"
        } else {
            original["requirement"].as_str().ok_or_else(invalid)?
        };
        // Preserve each original independently. A newer stop for its principal,
        // an old-review copy or unsigned intent cannot discharge this mapping.
        obligations
            .push(json!({"original":original,"copy_record_id":copy,"requirement":requirement}));
    }
    Ok(
        json!({"records":summaries,"evidence_hash":source_hash(&json!(commitments))?,
        "known_native_obligations":obligations,
        "observed_signing_lower_bounds":lower_bounds,"signing_clock_complete":false,
        "snapshot_complete":false,"recovery_ready":false}),
    )
}
