//! Retained author evidence under the closed plan. A receipt never releases the author's hold.
use super::{checkpoint_for_owner, invalid, review_source_evidence, source_hash, Binding};
use atem_client::member_report::{verify_signer_report, SignerReportChallenge};
use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool};

pub(crate) enum SubmitError {
    Changed,
    Invalid,
    Limit,
    Storage(sqlx::Error),
}

impl From<sqlx::Error> for SubmitError {
    fn from(error: sqlx::Error) -> Self {
        Self::Storage(error)
    }
}

const MAX_REPORTS: usize = 256;

// Only accepted evidence changes the review. Preserve the commitment for plans
// prepared by earlier versions until their first report actually arrives.
pub(super) async fn commitments(
    db: &mut PgConnection,
    plan_id: &str,
) -> Result<Vec<String>, sqlx::Error> {
    let hashes: Vec<String> = sqlx::query_scalar(
        "SELECT submission_hash FROM station_delegated_signer_reports WHERE plan_id=$1 ORDER BY connection LIMIT 257"
    ).bind(plan_id).fetch_all(db).await?;
    if hashes.len() > MAX_REPORTS {
        return Err(invalid());
    }
    Ok(hashes)
}

pub(crate) async fn submit(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    owner: &str,
    input: &Value,
) -> Result<Value, SubmitError> {
    let object = input
        .as_object()
        .filter(|v| v.len() == 2)
        .ok_or(SubmitError::Invalid)?;
    let report = object.get("report").ok_or(SubmitError::Invalid)?;
    let records = object
        .get("records")
        .and_then(Value::as_array)
        .ok_or(SubmitError::Invalid)?;
    let body = &report["body"];
    let signer = body["signer"].as_str().ok_or(SubmitError::Invalid)?;
    let slot = body["slot"].as_str().ok_or(SubmitError::Invalid)?;
    let connection = body["challenge"]["connection"]
        .as_i64()
        .filter(|i| (1..=9_007_199_254_740_991).contains(i))
        .ok_or(SubmitError::Invalid)?;
    let mut tx = pool.begin().await?;
    let (plan, log, mut evidence) =
        checkpoint_for_owner(&mut tx, binding, genesis, false, Some(owner)).await?;
    if body["recovery"]["plan_id"] != plan.plan_id {
        return Err(SubmitError::Changed);
    }
    let hash = source_hash(input)?;
    let receipt = json!({"plan_id": plan.plan_id, "submission_hash": hash, "retained_only": true});
    let prior: Option<Value> = sqlx::query_scalar(
        "SELECT submission FROM station_delegated_signer_reports WHERE plan_id=$1 AND connection=$2"
    ).bind(&plan.plan_id).bind(connection).fetch_optional(&mut *tx).await?;
    if let Some(prior) = prior {
        if prior != *input {
            return Err(SubmitError::Changed);
        }
        tx.commit().await?;
        return Ok(receipt);
    }
    let (head, challenge_json, expires): (Value, Value, i64) = sqlx::query_as(
        "SELECT membership_head,challenge,expires_at FROM station_delegated_signer_challenges
         WHERE plan_id=$1 AND signer=$2 AND slot=$3",
    )
    .bind(&plan.plan_id)
    .bind(signer)
    .bind(slot)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(SubmitError::Changed)?;
    let challenge = SignerReportChallenge::parse(challenge_json.to_string().as_bytes())
        .map_err(|_| invalid())?;
    review_source_evidence(&mut tx, &plan, &log, binding, &mut evidence).await?;
    let recovery = challenge.recovery();
    if challenge.connection() != connection as u64
        || challenge.origin() != binding.origin
        || recovery.plan_id() != plan.plan_id
        || recovery.candidate_feed_id() != plan.candidate_feed_id
        || recovery.generation() != binding.generation as u64
        || recovery.source_hash().to_hex() != plan.source_hash
        || evidence["evidence_hash"] != recovery.evidence_hash().to_hex()
        || head != log.head().to_json()
    {
        return Err(SubmitError::Changed);
    }
    let count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM station_delegated_signer_reports WHERE plan_id=$1",
    )
    .bind(&plan.plan_id)
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_REPORTS as i64 {
        return Err(SubmitError::Limit);
    }
    let now: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint")
            .fetch_one(&mut *tx)
            .await?;
    let wall = u64::try_from(now).map_err(|_| invalid())?;
    if wall < challenge.issued_at() || now >= expires || wall >= challenge.expires_at() {
        return Err(SubmitError::Changed);
    }
    let exported: Vec<_> = records.iter().map(Value::to_string).collect();
    let verified = verify_signer_report(
        &log,
        report.to_string().as_bytes(),
        &challenge,
        &exported,
        wall,
    )
    .map_err(|_| SubmitError::Invalid)?;
    if !verified.at_head {
        return Err(SubmitError::Changed);
    }
    sqlx::query("INSERT INTO station_delegated_signer_reports(plan_id,connection,challenge,submission,submission_hash,accepted_at)
        VALUES ($1,$2,$3,$4,$5,$6)")
        .bind(&plan.plan_id).bind(connection).bind(&challenge_json).bind(input).bind(&hash).bind(now)
        .execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(receipt)
}
