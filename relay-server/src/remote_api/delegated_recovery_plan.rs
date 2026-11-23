//! Durable preparation only. No prepared UUID, retained snapshot or operator
//! command establishes missing later history or authorizes reopening a fence.
use super::super::{Root, MAX_STATE};
use super::{Binding, Status};
use atem_client::{canonical::jcs, membership::Membership, Hash32};
use ring::digest::{digest, SHA256};
use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool};

#[path = "delegated_recovered_stops.rs"]
pub(crate) mod stops;
#[path = "delegated_recovery_history.rs"]
mod history;
#[path = "delegated_native_recovery.rs"]
pub(crate) mod native;
#[path = "delegated_recovery_signatures.rs"]
pub(crate) mod signatures;

#[path = "delegated_signer_challenges.rs"]
pub(crate) mod signer_challenges;
#[path = "delegated_signer_reports.rs"]
pub(crate) mod signer_reports;

#[derive(sqlx::FromRow)]
pub(super) struct Prepared {
    plan_id: String,
    candidate_feed_id: String,
    source_hash: String,
    retained: Value,
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
pub(crate) async fn prepare(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
) -> Result<Value, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let (prepared, log, mut report) = checkpoint(&mut tx, binding, genesis, true).await?;
    review_evidence(&mut tx, &prepared, &log, binding, &mut report).await?;
    tx.commit().await?;
    Ok(report)
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
    review_evidence(&mut tx, &prepared, &log, binding, &mut report).await?;
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
) -> Result<(), sqlx::Error> {
    review_source_evidence(connection, prepared, log, binding, report).await?;
    report["recovery_signatures"] = signatures::inspection(connection, prepared, log, binding, report).await?;
    report["reconstruction_hash"] = source_hash(&json!({
        "source_evidence_hash": report["evidence_hash"],
        "signature_evidence_hash": report["recovery_signatures"]["evidence_hash"],
    }))?.into();
    Ok(())
}

async fn review_source_evidence(
    connection: &mut PgConnection,
    prepared: &Prepared,
    log: &Membership,
    binding: &Binding,
    report: &mut Value,
) -> Result<(), sqlx::Error> {
    report["recovered_stops"] = stops::inspection(connection, prepared, log, binding).await?;
    let (history, signed) = history::inspection(connection, prepared, log, binding).await?;
    report["known_history"] = history;
    report["native_archives"] = native::inspection(connection, prepared, log, binding, &signed).await?;
    let mut sources = json!({
        "plan_id": prepared.plan_id,
        "source_hash": prepared.source_hash,
        "known_history": report["known_history"]["evidence_hash"],
        "recovered_stops": report["recovered_stops"]["evidence_hash"],
        "native_archives": report["native_archives"]["evidence_hash"],
    });
    let hashes = signer_reports::commitments(connection, &prepared.plan_id).await?;
    if !hashes.is_empty() { sources["signer_reports"] = json!(hashes); }
    report["evidence_hash"] = source_hash(&sources)?.into();
    Ok(())
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
    let feed = root.delegated.get(&binding.origin).ok_or_else(invalid)?;
    let review = feed
        .recovery_review(&binding.origin, &log)
        .map_err(|_| invalid())?;
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
        "SELECT plan_id,candidate_feed_id,source_hash, \
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
        if prepared.source_hash != source_hash
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
