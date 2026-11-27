//! Durable preparation only. No prepared UUID, retained snapshot or operator
//! command establishes missing later history or authorizes reopening a fence.
use super::super::{Root, MAX_STATE};
use super::{Binding, Status};
use crate::service_signing_ceilings::Reservation;
use atem_client::{canonical::jcs, membership::Membership, Hash32};
use ring::digest::{digest, SHA256};
use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool};
use std::collections::BTreeMap;

#[path = "delegated_portal_services.rs"]
mod portal_services;
#[path = "delegated_reporting_history.rs"]
pub(crate) mod reporting_history;

#[path = "delegated_recovered_stops.rs"]
pub(crate) mod stops;
#[path = "delegated_snapshot_stops.rs"]
pub(crate) mod snapshot_stops;
#[path = "delegated_recovery_history.rs"]
mod history;
#[path = "delegated_native_recovery.rs"]
pub(crate) mod native;
#[path = "delegated_recovery_signatures.rs"]
pub(crate) mod signatures;

#[path = "delegated_signer_challenges.rs"]
pub(crate) mod signer_challenges;
#[path = "delegated_plan_outcome.rs"]
pub(crate) mod outcome;
#[path = "delegated_author_history.rs"]
mod author_history;
#[path = "delegated_author_roster.rs"]
pub(crate) mod author_roster;
#[path = "delegated_signer_reports.rs"]
pub(crate) mod signer_reports;

#[derive(sqlx::FromRow)]
pub(super) struct Prepared {
    abandoned: bool,
    plan_id: String,
    candidate_feed_id: String,
    source_hash: String,
    retained: Value,
}

impl Prepared {
    fn retained_records(&self) -> Result<&[Value], sqlx::Error> {
        match self.retained.get("feed").ok_or_else(invalid)? {
            Value::Null => Ok(&[]),
            feed => feed["records"].as_array().map(Vec::as_slice).ok_or_else(invalid),
        }
    }
}

fn retained_feed_review(
    feed: Option<&super::super::delegated::Stored>,
    origin: &str,
    log: &Membership,
) -> Result<Value, sqlx::Error> {
    match feed {
        Some(feed) => feed.recovery_review(origin, log).map_err(|_| invalid()),
        None => Ok(json!({
            "status":"missing_retained_feed", "retained_feed_id":null, "inspection":null,
            "records":[], "retained_signing_watermarks":{}
        })),
    }
}

pub(super) fn invalid() -> sqlx::Error {
    sqlx::Error::Protocol("delegated recovery preparation requires review".into())
}

fn canonical_uuid(value: &str) -> bool {
    uuid::Uuid::parse_str(value)
        .is_ok_and(|id| id.get_version_num() == 4 && id.to_string() == value)
}

fn source_hash(value: &Value) -> Result<String, sqlx::Error> {
    let bytes = jcs(value).map_err(|_| invalid())?;
    if bytes.len() > MAX_STATE {
        return Err(invalid());
    }
    Ok(digest(&SHA256, bytes.as_bytes())
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

/// Preserve the exact retained source and reserve one replacement identity.
/// All replicas serialize through the closed deployment fence and root lock.
#[cfg(test)]
pub(crate) async fn prepare(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
) -> Result<Value, sqlx::Error> {
    prepare_with_sources(pool, binding, genesis, None, None, None).await
}

pub(crate) async fn prepare_with_sources(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    ceilings: Option<&crate::service_signing_ceilings::SigningCeilings>,
    portal: Option<&crate::integration_feed::FeedBinding>,
    vault: Option<&crate::service_keys::ServiceKeyVault>,
) -> Result<Value, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let (prepared, log, mut report) = checkpoint(&mut tx, binding, genesis, true).await?;
    let stops = review_evidence(&mut tx, &prepared, &log, binding, &mut report, true).await?;
    let reservations = match ceilings {
        Some(store) => Some(store.reservations(log.account_id(), genesis).await.map_err(|_| invalid())?),
        None => None,
    };
    let observed = observe_reservations(
        &mut tx, &binding.origin, log.account_id(), genesis, reservations.as_deref(),
    ).await?;
    let clock_evidence = match reservations.as_deref() {
        Some(rows) => Some(crate::service_signing_ceilings::SigningCeilings::recovery_evidence(
            rows, &observed, &report,
        ).map_err(|_| invalid())?),
        None if !observed.is_empty() => Some(json!({
            "status":"signing_store_unconfigured","plan_id":prepared.plan_id,
            "reconstruction_hash":report["reconstruction_hash"],"observed_reservations":observed
        })),
        None => None,
    };
    if let Some(evidence) = clock_evidence {
        report["service_clock_evidence_hash"] = source_hash(&evidence)?.into();
        report["service_clock_evidence"] = evidence;
    }
    if let Some(portal) = portal {
        let subject = prepared.retained["account_subject"].as_str().ok_or_else(invalid)?;
        let revokes = snapshot_stops::staged_service_revokes(
            &mut tx, stops, &prepared, &log, &binding.origin,
            report["reconstruction_hash"].as_str().ok_or_else(invalid)?,
        ).await?;
        let source = portal_services::observe(&mut tx, binding, portal, vault, subject, &log,
            reservations.as_deref(), &observed, &report, &revokes).await?;
        report["portal_service_evidence_hash"] = source_hash(&json!({
            "plan_id": prepared.plan_id, "reconstruction_hash": report["reconstruction_hash"],
            "source": source,
        }))?.into();
        report["portal_service_evidence"] = source;
        report["reporting_history"] = reporting_history::retain(&mut tx, binding, portal).await?;
    }
    tx.commit().await?;
    Ok(report)
}

async fn observe_reservations(
    connection: &mut PgConnection,
    origin: &str,
    account: &str,
    genesis: &str,
    current: Option<&[Reservation]>,
) -> Result<Vec<Reservation>, sqlx::Error> {
    if let Some(rows) = current.filter(|rows| !rows.is_empty()) {
        sqlx::query(
            "INSERT INTO station_delegated_observed_reservations AS seen
             (origin,account_id,genesis_hash,service_id,key_hash,highest_ms)
             SELECT $1,$2,$3,service_id,key_hash,highest_ms FROM jsonb_to_recordset($4)
                AS r(service_id text,key_hash text,highest_ms bigint)
             ON CONFLICT (origin,account_id,genesis_hash,service_id,key_hash) DO UPDATE
             SET highest_ms=EXCLUDED.highest_ms WHERE seen.highest_ms < EXCLUDED.highest_ms",
        )
        .bind(origin).bind(account).bind(genesis).bind(json!(rows))
        .execute(&mut *connection).await?;
    }
    let observed: Vec<Reservation> = sqlx::query_as(
        "SELECT service_id,key_hash,highest_ms FROM station_delegated_observed_reservations
         WHERE origin=$1 AND account_id=$2 AND genesis_hash=$3 ORDER BY service_id,key_hash LIMIT 4097",
    )
    .bind(origin).bind(account).bind(genesis)
    .fetch_all(&mut *connection).await?;
    if observed.len() > 4096 {
        return Err(invalid());
    }
    Ok(observed)
}

/// Account-private acquisition of an existing review. It never prepares a plan,
/// reserves a clock, advances a ledger or makes retained history authoritative.
pub(crate) async fn review_for_owner(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    owner: &str,
) -> Result<Value, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let (prepared, log, mut report) =
        checkpoint_for_owner(&mut tx, binding, genesis, false, Some(owner)).await?;
    review_evidence(&mut tx, &prepared, &log, binding, &mut report, false).await?;
    let summary = json!({
        "version": 1,
        "account_id": log.account_id(),
        "genesis_hash": genesis,
        "origin": binding.origin,
        // Deployment generations are i64; preserve values beyond JSON's safe integers.
        "generation": binding.generation.to_string(),
        "plan_id": prepared.plan_id,
        "candidate_feed_id": prepared.candidate_feed_id,
        "source_hash": prepared.source_hash,
        "evidence_hash": report["evidence_hash"],
        "reconstruction_hash": report["reconstruction_hash"],
        "membership_head": log.head().to_json(),
        "retained_history_only": true,
        "complete_history": false,
        "signing_clock_complete": false,
        "snapshot_complete": false,
        "recovery_ready": false,
    });
    if serde_json::to_vec(&summary).map_err(|_| invalid())?.len() > 8192 {
        return Err(invalid());
    }
    tx.commit().await?;
    Ok(summary)
}

async fn review_evidence(
    connection: &mut PgConnection,
    prepared: &Prepared,
    log: &Membership,
    binding: &Binding,
    report: &mut Value,
    operator_review: bool,
) -> Result<snapshot_stops::StopSources, sqlx::Error> {
    let mut signed = review_source_evidence(connection, prepared, log, binding, report, operator_review).await?;
    let (summary, copies) = signatures::inspection(connection, prepared, log, binding, report, &mut signed).await?;
    report["recovery_signatures"] = summary;
    let mut reconstruction = json!({
        "source_evidence_hash": report["evidence_hash"],
        "signature_evidence_hash": report["recovery_signatures"]["evidence_hash"],
    });
    if let Some(confirmations) = report.get("author_confirmation_hash") {
        reconstruction["author_confirmation_hash"] = confirmations.clone();
    }
    // Invalidate components staged before retained copies were counted as stops.
    if report["recovery_signatures"]["records"].as_array().is_some_and(|rows| !rows.is_empty()) {
        reconstruction["includes_signed_copies"] = true.into();
    }
    report["reconstruction_hash"] = source_hash(&reconstruction)?.into();
    Ok(snapshot_stops::StopSources { signed, copies })
}

async fn review_source_evidence(
    connection: &mut PgConnection,
    prepared: &Prepared,
    log: &Membership,
    binding: &Binding,
    report: &mut Value,
    operator_review: bool,
) -> Result<BTreeMap<String, Value>, sqlx::Error> {
    report["recovered_stops"] = stops::inspection(connection, prepared, log, binding).await?;
    let history = history::inspection(connection, prepared, log, binding, operator_review).await?;
    report["known_history"] = history.review;
    if operator_review {
        report["known_authors"] = history.authors;
    }
    report["native_archives"] = native::inspection(connection, prepared, log, binding, &history.signed).await?;
    let mut sources = json!({
        "plan_id": prepared.plan_id,
        "source_hash": prepared.source_hash,
        "known_history": report["known_history"]["evidence_hash"],
        "recovered_stops": report["recovered_stops"]["evidence_hash"],
        "native_archives": report["native_archives"]["evidence_hash"],
    });
    if !history.confirmation_hashes.is_empty() {
        report["author_confirmation_hash"] = source_hash(&json!(history.confirmation_hashes))?.into();
    }
    let hashes = history.current_report_hashes;
    if !hashes.is_empty() { sources["signer_reports"] = json!(hashes); }
    report["evidence_hash"] = source_hash(&sources)?.into();
    Ok(history.signed)
}

/// The fence and source stay locked until the caller commits all new evidence.
async fn checkpoint(
    connection: &mut PgConnection,
    binding: &Binding,
    genesis: &str,
    create: bool,
) -> Result<(Prepared, Membership, Value), sqlx::Error> {
    checkpoint_for_owner(connection, binding, genesis, create, None).await
}

async fn checkpoint_for_owner(
    connection: &mut PgConnection,
    binding: &Binding,
    genesis: &str,
    create: bool,
    owner: Option<&str>,
) -> Result<(Prepared, Membership, Value), sqlx::Error> {
    if !super::canonical_genesis(genesis) {
        return Err(invalid());
    }
    sqlx::query("SET LOCAL statement_timeout = '5s'")
        .execute(&mut *connection)
        .await?;
    let status: Option<Status> = sqlx::query_as(
        "SELECT generation,ready,reason FROM station_delegated_recovery WHERE origin=$1 FOR UPDATE",
    )
    .bind(&binding.origin)
    .fetch_optional(&mut *connection)
    .await?;
    if !status.is_some_and(|status| status.generation == binding.generation && !status.ready) {
        return Err(invalid());
    }
    let (subject, value): (Option<String>, Option<Value>) = sqlx::query_as(
        "SELECT account_subject,CASE WHEN octet_length(state::text) <= $2 THEN state END \
         FROM remote_recovery_roots WHERE genesis_hash=$1 FOR UPDATE",
    )
    .bind(genesis)
    .bind(MAX_STATE as i64)
    .fetch_optional(&mut *connection)
    .await?
    .ok_or(sqlx::Error::RowNotFound)?;
    if owner.is_some_and(|owner| subject.as_deref() != Some(owner)) {
        return Err(sqlx::Error::RowNotFound);
    }
    let subject = subject
        .filter(|subject| !subject.is_empty())
        .ok_or_else(invalid)?;
    let root: Root = serde_json::from_value(value.ok_or_else(invalid)?).map_err(|_| invalid())?;
    let hash = Hash32::from_hex(genesis).map_err(|_| invalid())?;
    let log =
        Membership::from_stored(&root.account, &hash, &root.membership).map_err(|_| invalid())?;
    if log.frozen().is_some() {
        return Err(invalid());
    }
    let feed = root.delegated.get(&binding.origin);
    let review = retained_feed_review(feed, &binding.origin, &log)?;
    // Exclude mutable routes, pushes and backup blobs. They neither establish
    // control history nor invalidate a prepared source on an ordinary reconnect.
    let retained = json!({
        "account_subject": subject,
        "account_id": root.account,
        "membership": root.membership,
        "feed": feed,
    });
    let source_hash = source_hash(&retained)?;
    // JSONB's text representation can be larger than canonical JSON. Check
    // the actual persisted size so a successful first call is readable again.
    let fits: bool = sqlx::query_scalar("SELECT octet_length($1::jsonb::text) <= $2")
        .bind(&retained)
        .bind(MAX_STATE as i64)
        .fetch_one(&mut *connection)
        .await?;
    if !fits {
        return Err(invalid());
    }
    let prepared: Option<Prepared> = sqlx::query_as(
        "SELECT abandoned,plan_id,candidate_feed_id,source_hash, \
         CASE WHEN octet_length(retained::text) <= $4 THEN retained END AS retained \
         FROM station_delegated_recovery_plans \
         WHERE origin=$1 AND generation=$2 AND genesis_hash=$3",
    )
    .bind(&binding.origin)
    .bind(binding.generation)
    .bind(genesis)
    .bind(MAX_STATE as i64)
    .fetch_optional(&mut *connection)
    .await?;
    let prepared = if let Some(prepared) = prepared {
        if prepared.abandoned || prepared.source_hash != source_hash
            || prepared.retained != retained
            || !canonical_uuid(&prepared.plan_id)
            || !canonical_uuid(&prepared.candidate_feed_id)
            || prepared.candidate_feed_id == review["retained_feed_id"]
        {
            // Never replace an earlier plan or silently drop its obligations.
            return Err(invalid());
        }
        prepared
    } else {
        if !create {
            return Err(invalid());
        }
        let prepared = Prepared {
            abandoned: false,
            plan_id: uuid::Uuid::new_v4().to_string(),
            candidate_feed_id: uuid::Uuid::new_v4().to_string(),
            source_hash,
            retained,
        };
        if prepared.candidate_feed_id == review["retained_feed_id"] {
            return Err(invalid());
        }
        sqlx::query(
            "INSERT INTO station_delegated_recovery_plans \
             (origin,generation,genesis_hash,plan_id,candidate_feed_id,source_hash,retained) \
             VALUES ($1,$2,$3,$4,$5,$6,$7)",
        )
        .bind(&binding.origin)
        .bind(binding.generation)
        .bind(genesis)
        .bind(&prepared.plan_id)
        .bind(&prepared.candidate_feed_id)
        .bind(&prepared.source_hash)
        .bind(&prepared.retained)
        .execute(&mut *connection)
        .await?;
        prepared
    };
    let report = json!({
        "version": 1,
        "origin": binding.origin,
        "generation": binding.generation,
        "genesis_hash": genesis,
        "plan_id": prepared.plan_id,
        "candidate_feed_id": prepared.candidate_feed_id,
        "source_hash": prepared.source_hash,
        "membership_head": log.head().to_json(),
        "retained_history_only": true,
        "snapshot_complete": false,
        "recovery_ready": false,
        "review": review,
        "unresolved": ["later_control_history", "signing_clock_anchors", "complete_snapshot", "fresh_manager_confirmations"],
    });
    Ok((prepared, log, report))
}
