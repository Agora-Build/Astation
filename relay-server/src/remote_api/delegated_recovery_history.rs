//! Reconcile every retained checkpoint. A newer restored source cannot erase
//! known stops, clock reservations or unresolved reporting evidence.
use super::super::super::{delegated::{recovery_record_review, Stored}, MAX_STATE};
use super::super::Binding;
use super::{canonical_uuid, invalid, signer_reports, source_hash, stops, Prepared};
use atem_client::{
    channel::HeadRelation,
    control::{principal_key_of, verify_control, ControlCheck, ControlPrincipal, ControlRecord, RefusalReason},
    membership::{Action, MemberKind, Membership},
    Hash32,
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
    feed: Option<Stored>,
}

fn add_record(
    records: &mut BTreeMap<String, (Value, Value)>,
    record: &ControlRecord,
    review: Value,
) -> Result<(), sqlx::Error> {
    let value = record.object().to_json();
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
    pub new_export_digests: BTreeMap<String, String>,
    pub confirmation_hashes: Vec<String>,
    // One latest verified export per signer, slot and process, in this plan.
    pub latest_exports: Vec<(Hash32, Vec<String>)>,
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
        "WITH plans AS (SELECT plan_id,octet_length(retained::text) AS bytes
         FROM station_delegated_recovery_plans WHERE origin=$1 AND genesis_hash=$2 AND generation <= $3)
         SELECT count(*)::bigint,COALESCE(sum(bytes),0)::bigint FROM
         (SELECT bytes FROM plans UNION ALL SELECT octet_length(m.membership::text)
          FROM station_delegated_recovery_memberships m JOIN plans USING(plan_id)) AS sources",
    )
    .bind(&binding.origin)
    .bind(log.genesis_hash().to_hex())
    .bind(binding.generation)
    .fetch_one(&mut *connection)
    .await?;
    if count == 0 || count > MAX_CHECKPOINTS || bytes > MAX_STATE as i64 {
        return Err(invalid());
    }
    super::service_components::check_size(connection, &binding.origin, &log.genesis_hash().to_hex(), &json!([]))
        .await?;
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
    let mut membership_gaps = Vec::new();
    let mut records = BTreeMap::new();
    // Keep a key's authenticated signatures even if the restored list predates
    // its enrollment. Record IDs and today's authority are reviewed separately.
    let mut service_keys = BTreeMap::<(String, String), Option<u64>>::new();
    let mut lower_bounds = BTreeMap::<String, u64>::new();
    let mut commitments = Vec::new();
    let mut retained_feed_ids = BTreeSet::new();
    let mut found_current = false;
    let mut journals = super::author_history::JournalHistory::default();
    let mut current_authors = None;
    let mut prior_authors = Vec::new();
    let mut new_export_digests = BTreeMap::new();
    let mut confirmation_hashes = Vec::new();
    let mut latest_exports = BTreeMap::new();
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
        let old_review = super::retained_feed_review(retained.feed.as_ref(), &binding.origin, &old_log)?;
        let heads = super::memberships::history(connection, &checkpoint, old_log).await?;
        let latest = heads.last_key_value().ok_or_else(invalid)?.1;
        // Both logs have been verified. When the retained log is longer, compare
        // the overlapping entry too: length alone cannot distinguish a fork.
        let gap = match HeadRelation::of(log, latest.head()) {
            HeadRelation::Same | HeadRelation::HostBehind => None,
            HeadRelation::HostAhead if HeadRelation::of(latest, log.head()) == HeadRelation::HostBehind => {
                Some("restored_head_behind")
            }
            _ => Some("divergent_history"),
        };
        if let Some(reason) = gap {
            membership_gaps.push(json!({"generation":generation,"plan_id":checkpoint.plan_id,
                "membership_head":latest.head().to_json(),"reason":reason}));
        }
        // Validate the historical checkpoint, then classify every obligation
        // under current authority. Removed managers never regain authority.
        let review = super::retained_feed_review(retained.feed.as_ref(), &binding.origin, log)?;
        if let Some(feed_id) = review["retained_feed_id"].as_str() {
            retained_feed_ids.insert(feed_id.to_owned());
        }
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
        let values = checkpoint.retained_records()?;
        let reviews = review["records"].as_array().ok_or_else(invalid)?;
        let old_reviews = old_review["records"].as_array().ok_or_else(invalid)?;
        if values.len() != reviews.len() || values.len() != old_reviews.len() {
            return Err(invalid());
        }
        for entry in latest.entries() {
            let member = match &entry.action {
                Action::Add { member } | Action::RecoveryAdd { member } | Action::Genesis { member, .. }
                    if matches!(member.kind, MemberKind::Service { .. }) => member,
                _ => continue,
            };
            let key = principal_key_of(&member.auth_key).map_err(|_| invalid())?.to_hex();
            service_keys.entry((member.device_id.clone(), key)).or_default();
        }
        for ((value, review), old) in values.iter().zip(reviews).zip(old_reviews) {
            let record = ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| invalid())?)
                .map_err(|_| invalid())?;
            if let Some((_, id)) = record.feed() {
                retained_feed_ids.insert(id.to_owned());
            }
            let principal = review["principal"].as_str().ok_or_else(invalid)?;
            if review["signer"] == principal && (old["verification"] == "valid" || review["verification"] == "valid") {
                let service = principal.strip_prefix("service:").ok_or_else(invalid)?;
                let key = review["principal_key"].as_str().ok_or_else(invalid)?;
                let issued = review["issued_at"].as_u64().ok_or_else(invalid)?;
                let highest = service_keys.entry((service.to_owned(), key.to_owned())).or_default();
                *highest = Some(highest.map_or(issued, |prior| prior.max(issued)));
            }
            add_record(&mut records, &record, review.clone())?;
        }
        for (principal, value) in review["retained_signing_watermarks"]
            .as_object()
            .ok_or_else(invalid)?
        {
            let lower = lower_bounds.entry(principal.clone()).or_default();
            *lower = (*lower).max(value.as_u64().ok_or_else(invalid)?);
        }
        let mut authors = operator_review.then(|| super::author_history::inventory(latest));
        let mut hashes = Vec::new();
        let current_plan = checkpoint.plan_id == prepared.plan_id;
        signer_reports::visit(connection, &checkpoint, &heads, &binding.origin, generation, |verified, hash, accepted_log| {
            if operator_review {
                journals.observe(&verified.signer, &verified.journal, generation, current_plan,
                    verified.records.iter().map(ControlRecord::record_id));
            }
            if current_plan {
                latest_exports.insert((verified.signer.clone(), verified.slot.clone(), verified.process),
                    (verified.recovery.evidence_hash(), verified.records.iter().map(|r| r.record_id().to_owned()).collect()));
            }
            for record in verified.records {
                // Checkpoint records and older plans already contribute to the base.
                if current_plan && !records.contains_key(record.record_id()) {
                    new_export_digests.insert(record.record_id().to_owned(), source_hash(&record.object().to_json())?);
                }
                // Signing a journal export does not establish authority for its target.
                // Keep the original verified clock across later membership changes.
                if matches!(verify_control(&record, accepted_log),
                    ControlCheck::Valid(_) | ControlCheck::Refused(RefusalReason::RemovedManager))
                {
                    let lower = lower_bounds.entry(record.principal().name()).or_default();
                    *lower = (*lower).max(record.issued_at());
                }
                add_record(&mut records, &record, stops::review(&record, log, &binding.origin)?)?;
            }
            if let Some(authors) = &mut authors {
                let author = authors.get_mut(&verified.signer).ok_or_else(invalid)?;
                let first = author["first_manage_seq"].as_u64().ok_or_else(invalid)?;
                author["reports"].as_array_mut().ok_or_else(invalid)?.push(json!({
                    "connection": verified.connection, "slot": verified.slot,
                    "process": atem_client::encoding::b64u(&verified.process), "journal": verified.journal.to_json(),
                    "missing_early_range": verified.journal.since > first, "submission_hash": hash,
                    "signed_evidence_hash": verified.recovery.evidence_hash().to_hex(),
                }));
            }
            if current_plan {
                confirmation_hashes.push(hash);
            } else {
                hashes.push(hash);
            }
            Ok(())
        }).await?;
        let mut commitment = json!({
            "generation": generation, "plan_id": checkpoint.plan_id,
            "candidate_feed_id": checkpoint.candidate_feed_id, "source_hash": checkpoint.source_hash,
        });
        let components = super::service_components::visit(connection, &checkpoint, &binding.origin, &heads, |record| {
            let ControlPrincipal::Service(service) = record.principal() else { return Err(invalid()); };
            let key = record.principal_key().ok_or_else(invalid)?.to_hex();
            let highest = service_keys.entry((service.clone(), key)).or_default();
            *highest = Some(highest.map_or(record.issued_at(), |v| v.max(record.issued_at())));
            let lower = lower_bounds.entry(record.principal().name()).or_default();
            *lower = (*lower).max(record.issued_at());
            add_record(&mut records, &record, recovery_record_review(&record, log))
        }).await?;
        if !components.is_empty() {
            if !current_plan {
                retained_feed_ids.insert(checkpoint.candidate_feed_id.clone());
            }
            commitment["service_components"] = source_hash(&json!(components))?.into();
        }
        if heads.len() > 1 {
            commitment["observed_membership"] = source_hash(&latest.to_stored())?.into();
        }
        if checkpoint.plan_id == prepared.plan_id {
            current_authors = authors;
        } else {
            if !hashes.is_empty() {
                commitment["signer_reports"] = json!(hashes);
            }
            if let Some(members) = authors {
                prior_authors.push(json!({"generation": generation, "plan_id": checkpoint.plan_id,
                    "membership_head": latest.head().to_json(), "members": members}));
            }
        }
        commitments.push(commitment);
        let mut summary = json!({
            "generation": generation, "plan_id": checkpoint.plan_id,
            "source_hash": checkpoint.source_hash, "membership_head": retained.membership["head"],
            "retained_feed_id": review["retained_feed_id"], "inspection": review["inspection"],
        });
        if heads.len() > 1 {
            summary["observed_membership_head"] = latest.head().to_json();
        }
        if !components.is_empty() {
            summary["service_components"] = json!(components);
        }
        summaries.push(summary);
    }
    if !found_current || retained_feed_ids.contains(&prepared.candidate_feed_id) {
        return Err(invalid());
    }
    let imports = stops::load(connection, binding, &log.genesis_hash().to_hex()).await?;
    for (id, value) in &imports {
        // Imported records have their own commitment, regardless of discovery order.
        new_export_digests.remove(id);
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
            &record,
            stops::review(&record, log, &binding.origin)?,
        )?;
    }
    let report = json!({
        "checkpoints": summaries,
        "membership_gaps": membership_gaps,
        "observed_service_keys": service_keys.into_iter().map(|((service, key), highest)| json!({
            "service_id":service, "key_fingerprint":key, "highest_signed_ms":highest
        })).collect::<Vec<_>>(),
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
        authors: json!({"members": current_authors, "prior_plans": prior_authors,
            "journal_gaps": journals.gaps(), "complete_history": false}),
        new_export_digests,
        confirmation_hashes,
        latest_exports: latest_exports.into_values().collect(),
    })
}
