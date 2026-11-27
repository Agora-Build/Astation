//! Only the recovering Station mints a challenge, in the transaction that
//! checks the fenced plan, ownership, membership and current evidence.
use super::{checkpoint_for_owner, invalid, review_source_evidence, Binding};
use atem_client::{
    member_report::{RecoveryPlan, SignerReportChallenge},
    membership::{Head, MemberKind, MemberStatus, Membership},
};
use serde_json::{json, Value};
use sqlx::PgPool;

const MAX_ACTIVE: i64 = 128;
const LEASE_MS: u64 = 30_000;

pub(crate) enum MintError {
    ContextChanged,
    Limit,
    Storage(sqlx::Error),
}

impl From<sqlx::Error> for MintError {
    fn from(error: sqlx::Error) -> Self {
        Self::Storage(error)
    }
}

pub(crate) struct Request {
    signer: String,
    slot: String,
    expected: Head,
    recovery: RecoveryPlan,
}

impl Request {
    pub(crate) fn parse(value: &Value) -> Option<Self> {
        if value.as_object()?.len() != 4 {
            return None;
        }
        let signer = value.get("signer")?.as_str()?;
        let slot = value.get("slot")?.as_str()?;
        let opaque = |s: &str| {
            (1..=128).contains(&s.len())
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
        };
        if !opaque(signer.strip_prefix("member:")?) || !opaque(slot) {
            return None;
        }
        Some(Self {
            signer: signer.into(),
            slot: slot.into(),
            expected: Head::from_json(value.get("expected")?)?,
            recovery: RecoveryPlan::from_json(value.get("recovery")?).ok()?,
        })
    }
}

fn eligible(log: &Membership, signer: &str) -> bool {
    let Some(id) = signer.strip_prefix("member:") else {
        return false;
    };
    if !log.member(id).is_some_and(|m| {
        m.status == MemberStatus::Active && matches!(m.member.kind, MemberKind::Native { .. })
    }) {
        return false;
    }
    super::author_history::first_manage(log).contains_key(id)
}

pub(crate) async fn mint(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    owner: &str,
    request: Request,
) -> Result<Value, MintError> {
    let mut tx = pool.begin().await?;
    let (prepared, log, mut evidence) =
        checkpoint_for_owner(&mut tx, binding, genesis, false, Some(owner)).await?;
    if request.expected != log.head() || !eligible(&log, &request.signer) {
        return Err(MintError::ContextChanged);
    }
    let source = review_source_evidence(&mut tx, &prepared, &log, binding, &mut evidence, false).await?;
    let recovery = RecoveryPlan::from_json(&json!({
        "generation": binding.generation.to_string(), "plan_id": prepared.plan_id,
        "candidate_feed_id": prepared.candidate_feed_id, "source_hash": prepared.source_hash,
        "evidence_hash": evidence["evidence_hash"],
    }))
    .map_err(|_| invalid())?;
    if request.recovery != recovery || !super::covers_retained_membership(&evidence) {
        return Err(MintError::ContextChanged);
    }
    let now: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint")
            .fetch_one(&mut *tx)
            .await?;
    let issued_at = u64::try_from(now).map_err(|_| invalid())?;
    sqlx::query(
        "DELETE FROM station_delegated_signer_challenges WHERE plan_id=$1 AND expires_at<=$2",
    )
    .bind(&prepared.plan_id)
    .bind(now)
    .execute(&mut *tx)
    .await?;
    let old: Option<(Value, Value)> = sqlx::query_as(
        "SELECT membership_head,challenge FROM station_delegated_signer_challenges \
         WHERE plan_id=$1 AND signer=$2 AND slot=$3",
    )
    .bind(&prepared.plan_id)
    .bind(&request.signer)
    .bind(&request.slot)
    .fetch_optional(&mut *tx)
    .await?;
    if let Some((head, value)) = &old {
        let previous =
            SignerReportChallenge::parse(value.to_string().as_bytes()).map_err(|_| invalid())?;
        if previous.signer() != request.signer
            || previous.slot() != request.slot
            || previous.origin() != binding.origin
            || previous.issued_at() > issued_at
        {
            return Err(invalid().into());
        }
        if head == &log.head().to_json()
            && previous.recovery() == &recovery
            && issued_at < previous.expires_at()
        {
            tx.commit().await?;
            return Ok(value.clone());
        }
    } else {
        let count: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM station_delegated_signer_challenges WHERE plan_id=$1",
        )
        .bind(&prepared.plan_id)
        .fetch_one(&mut *tx)
        .await?;
        if count >= MAX_ACTIVE {
            return Err(MintError::Limit);
        }
    }
    let connection: i64 = sqlx::query_scalar(
        "UPDATE station_delegated_recovery_plans SET signer_connection=signer_connection+1 \
         WHERE plan_id=$1 AND signer_connection<9007199254740991 RETURNING signer_connection",
    )
    .bind(&prepared.plan_id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(invalid)?;
    let expires_at = issued_at.checked_add(LEASE_MS).ok_or_else(invalid)?;
    let challenge = SignerReportChallenge::new(
        &request.signer,
        &request.slot,
        &binding.origin,
        connection as u64,
        issued_at,
        expires_at,
        recovery,
    )
    .map_err(|_| invalid())?
    .to_json();
    sqlx::query(
        "INSERT INTO station_delegated_signer_challenges(plan_id,signer,slot,membership_head,challenge,expires_at,external_source_hash) \
         VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(plan_id,signer,slot) DO UPDATE SET \
         membership_head=EXCLUDED.membership_head,challenge=EXCLUDED.challenge,expires_at=EXCLUDED.expires_at,external_source_hash=EXCLUDED.external_source_hash"
    )
        .bind(&prepared.plan_id).bind(&request.signer).bind(&request.slot).bind(log.head().to_json())
        .bind(&challenge).bind(i64::try_from(expires_at).map_err(|_| invalid())?)
        .bind(&source.external_source_hash).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(challenge)
}
