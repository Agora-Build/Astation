//! Reconcile every retained checkpoint. A newer restored source cannot erase
//! known stops, clock reservations or unresolved reporting evidence.
use super::super::super::{delegated::Stored, MAX_STATE};
use super::super::Binding;
use super::{canonical_uuid, invalid, signer_reports, source_hash, stops, Prepared};
use atem_client::{
    control::{verify_control, ControlCheck, ControlRecord, RefusalReason},
    membership::Membership,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::PgConnection;
use std::collections::{BTreeMap, BTreeSet};

const MAX_CHECKPOINTS: i64 = 128;
pub(super) const MAX_RECORDS: usize = 4096;

#[derive(sqlx::FromRow)]
struct Historical {
    generation: i64,
    #[sqlx(flatten)]
    plan: Prepared,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Retained {
    account_subject: String,
    account_id: String,
    membership: Value,
    feed: Stored,
}

fn add_record(
    records: &mut BTreeMap<String, (Value, Value)>,
    value: Value,
    review: Value,
) -> Result<(), sqlx::Error> {
    let record = ControlRecord::parse(&serde_json::to_vec(&value).map_err(|_| invalid())?)
        .map_err(|_| invalid())?;
    let id = record.record_id().to_owned();
    if let Some((previous, previous_review)) = records.get(&id) {
        if previous != &value || previous_review != &review {
            return Err(invalid());
        }
    } else {
        if records.len() >= MAX_RECORDS {
            return Err(invalid());
        }
        records.insert(id, (value, review));
    }
    Ok(())
}

pub(super) struct History {
    pub review: Value,
    pub signed: BTreeMap<String, Value>,
    pub authors: Value,
    pub current_report_hashes: Vec<String>,
}

pub(super) async fn inspection(
    connection: &mut PgConnection,
    prepared: &Prepared,
    log: &Membership,
    binding: &Binding,
    operator_review: bool,
) -> Result<History, sqlx::Error> {
    // The caller holds the deployment fence and account root through commit;
    // every prepare/import uses these same locks, including other replicas.
    let (count, bytes): (i64, i64) = sqlx::query_as(
        "SELECT count(*)::bigint,COALESCE(sum(octet_length(retained::text)),0)::bigint \
         FROM station_delegated_recovery_plans \
         WHERE origin=$1 AND genesis_hash=$2 AND generation <= $3",
    )
    .bind(&binding.origin)
    .bind(log.genesis_hash().to_hex())
    .bind(binding.generation)
    .fetch_one(&mut *connection)
    .await?;
    if count == 0 || count > MAX_CHECKPOINTS || bytes > MAX_STATE as i64 {
        return Err(invalid());
    }
    let checkpoints: Vec<Historical> = sqlx::query_as(
        "SELECT generation,abandoned,plan_id,candidate_feed_id,source_hash,retained \
         FROM station_delegated_recovery_plans \
         WHERE origin=$1 AND genesis_hash=$2 AND generation <= $3 ORDER BY generation",
    )
    .bind(&binding.origin)
    .bind(log.genesis_hash().to_hex())
    .bind(binding.generation)
    .fetch_all(&mut *connection)
    .await?;
    let subject = prepared.retained["account_subject"]
        .as_str()
        .ok_or_else(invalid)?;
    let mut summaries = Vec::new();
    let mut records = BTreeMap::new();
    let mut lower_bounds = BTreeMap::<String, u64>::new();
    let mut commitments = Vec::new();
    let mut retained_feed_ids = BTreeSet::new();
    let mut found_current = false;
    let mut current_authors = None;
    let mut prior_authors = Vec::new();
    let mut current_report_hashes = Vec::new();
    for Historical {
        generation,
        plan: checkpoint,
    } in checkpoints
    {
        if generation <= 0
            || !canonical_uuid(&checkpoint.plan_id)
            || !canonical_uuid(&checkpoint.candidate_feed_id)
            || source_hash(&checkpoint.retained)? != checkpoint.source_hash
        {
            return Err(invalid());
        }
        let retained: Retained =
            serde_json::from_value(checkpoint.retained.clone()).map_err(|_| invalid())?;
        if retained.account_subject != subject || retained.account_id != log.account_id() {
            return Err(invalid());
        }
        let old_log =
            Membership::from_stored(log.account_id(), &log.genesis_hash(), &retained.membership)
                .map_err(|_| invalid())?;
        if old_log.frozen().is_some() {
            return Err(invalid());
        }
        // Validate the historical checkpoint, then classify every obligation
        // under current authority. Removed managers never regain authority.
        retained
            .feed
            .recovery_review(&binding.origin, &old_log)
            .map_err(|_| invalid())?;
        let review = retained
            .feed
            .recovery_review(&binding.origin, log)
            .map_err(|_| invalid())?;
        retained_feed_ids.insert(
            review["retained_feed_id"]
                .as_str()
                .ok_or_else(invalid)?
                .to_owned(),
        );
        if checkpoint.candidate_feed_id == review["retained_feed_id"] {
            return Err(invalid());
        }
        if checkpoint.plan_id == prepared.plan_id {
            if generation != binding.generation
                || checkpoint.retained != prepared.retained
                || checkpoint.source_hash != prepared.source_hash
                || checkpoint.candidate_feed_id != prepared.candidate_feed_id
            {
                return Err(invalid());
            }
            found_current = true;
        }
        let values = checkpoint.retained["feed"]["records"]
            .as_array()
            .ok_or_else(invalid)?;
        let reviews = review["records"].as_array().ok_or_else(invalid)?;
        if values.len() != reviews.len() {
            return Err(invalid());
        }
        for (value, review) in values.iter().zip(reviews) {
            add_record(&mut records, value.clone(), review.clone())?;
        }
        for (principal, value) in review["retained_signing_watermarks"]
            .as_object()
            .ok_or_else(invalid)?
        {
            let lower = lower_bounds.entry(principal.clone()).or_default();
            *lower = (*lower).max(value.as_u64().ok_or_else(invalid)?);
        }
        let mut authors = operator_review.then(|| super::author_history::inventory(&old_log));
        let mut hashes = Vec::new();
        signer_reports::visit(connection, &checkpoint, &old_log, &binding.origin, generation, |verified, hash| {
            for record in verified.records {
                // Signing a journal export does not establish authority for its target.
                // Keep the original verified clock across later membership changes.
                if matches!(verify_control(&record, &old_log),
                    ControlCheck::Valid(_) | ControlCheck::Refused(RefusalReason::RemovedManager))
                {
                    let lower = lower_bounds.entry(record.principal().name()).or_default();
                    *lower = (*lower).max(record.issued_at());
                }
                add_record(&mut records, record.object().to_json(), stops::review(&record, log, &binding.origin)?)?;
            }
            if let Some(authors) = &mut authors {
                let author = authors.get_mut(&verified.signer).ok_or_else(invalid)?;
                let first = author["first_manage_seq"].as_u64().ok_or_else(invalid)?;
                author["reports"].as_array_mut().ok_or_else(invalid)?.push(json!({
                    "connection": verified.connection, "slot": verified.slot,
                    "process": atem_client::encoding::b64u(&verified.process), "journal": verified.journal.to_json(),
                    "missing_early_range": verified.journal.since > first, "submission_hash": hash,
                }));
            }
            hashes.push(hash);
            Ok(())
        }).await?;
        let mut commitment = json!({
            "generation": generation, "plan_id": checkpoint.plan_id,
            "candidate_feed_id": checkpoint.candidate_feed_id, "source_hash": checkpoint.source_hash,
        });
        if checkpoint.plan_id == prepared.plan_id {
            // Existing active challenges already commit to these hashes at the outer level.
            current_report_hashes = hashes;
            current_authors = authors;
        } else {
            if !hashes.is_empty() {
                commitment["signer_reports"] = json!(hashes);
            }
            if let Some(members) = authors {
                prior_authors.push(json!({"generation": generation, "plan_id": checkpoint.plan_id,
                    "membership_head": old_log.head().to_json(), "members": members}));
            }
        }
        commitments.push(commitment);
        summaries.push(json!({
            "generation": generation, "plan_id": checkpoint.plan_id,
            "source_hash": checkpoint.source_hash, "membership_head": old_log.head().to_json(),
            "retained_feed_id": review["retained_feed_id"], "inspection": review["inspection"],
        }));
    }
    if !found_current || retained_feed_ids.contains(&prepared.candidate_feed_id) {
        return Err(invalid());
    }
    let imports = stops::load(connection, binding, &log.genesis_hash().to_hex()).await?;
    for (id, value) in &imports {
        let record = ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
        if id != record.record_id() {
            return Err(invalid());
        }
        if matches!(verify_control(&record, log), ControlCheck::Valid(_)) {
            let lower = lower_bounds.entry(record.principal().name()).or_default();
            *lower = (*lower).max(record.issued_at());
        }
        add_record(
            &mut records,
            value.clone(),
            stops::review(&record, log, &binding.origin)?,
        )?;
    }
    let report = json!({
        "checkpoints": summaries,
        "records": records.values().map(|(_, review)| review).collect::<Vec<_>>(),
        "observed_signing_lower_bounds": lower_bounds,
        "evidence_hash": source_hash(&json!({"checkpoints": commitments, "imports": imports}))?,
        "complete_history": false,
        "signing_clock_complete": false,
    });
    Ok(History {
        review: report,
        signed: records
            .into_iter()
            .map(|(id, (record, _))| (id, record))
            .collect(),
        authors: json!({"members": current_authors, "prior_plans": prior_authors, "complete_history": false}),
        current_report_hashes,
    })
}
