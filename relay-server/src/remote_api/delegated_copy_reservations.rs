use super::{
    canonical_uuid, checkpoint_for_owner, covers_retained_membership, invalid, review_evidence,
    source_hash, Binding,
};
use atem_client::{
    control::ControlRecord,
    member_report::RecoveryPlan,
    membership::{Head, MemberStatus},
    Hash32,
};
use serde_json::{json, Value};
use sqlx::PgPool;

const MAX_TIME: u64 = (1 << 53) - 1;

pub(crate) struct Request {
    recovery: RecoveryPlan,
    expected: Head,
    manager: String,
    original_id: String,
    original_hash: Hash32,
    issued_at: Option<u64>,
    after_issued_at: Option<u64>,
}

impl Request {
    pub(crate) fn parse(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        let timestamp = |field| match object.get(field) {
            Some(Value::Number(n)) => n.as_u64().filter(|t| (1..=MAX_TIME).contains(t)).map(Some),
            None => Some(None),
            _ => None,
        };
        let issued_at = timestamp("issued_at")?;
        let after_issued_at = timestamp("after_issued_at")?;
        let original_id = object.get("original_record_id")?.as_str()?;
        let manager = object.get("manager")?.as_str()?;
        if (issued_at.is_some() && after_issued_at.is_some())
            || object.len() != 5 + usize::from(issued_at.is_some() || after_issued_at.is_some())
            || !canonical_uuid(original_id)
            || !(1..=128).contains(&manager.len())
            || !manager
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"._:-".contains(&c))
        {
            return None;
        }
        Some(Self {
            recovery: RecoveryPlan::from_json(object.get("recovery")?).ok()?,
            expected: Head::from_json(object.get("expected")?)?,
            original_id: original_id.to_owned(),
            original_hash: Hash32::from_hex(object.get("original_hash")?.as_str()?).ok()?,
            manager: manager.to_owned(),
            issued_at,
            after_issued_at,
        })
    }
}

pub(crate) enum Error {
    Changed,
    Clock,
    Limit,
    Storage(sqlx::Error),
}

impl From<sqlx::Error> for Error {
    fn from(value: sqlx::Error) -> Self {
        Self::Storage(value)
    }
}

pub(crate) async fn reserve(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    owner: &str,
    request: Request,
) -> Result<Value, Error> {
    let mut tx = pool.begin().await?;
    let (plan, log, mut report) =
        checkpoint_for_owner(&mut tx, binding, genesis, false, Some(owner)).await?;
    if plan.plan_id != request.recovery.plan_id()
        || request.expected != log.head()
        || !log
            .member(&request.manager)
            .is_some_and(|m| m.status == MemberStatus::Active && m.member.is_manager())
    {
        return Err(Error::Changed);
    }
    let sources = review_evidence(&mut tx, &plan, &log, binding, &mut report, false).await?;
    let recovery = json!({"generation":binding.generation.to_string(), "plan_id":plan.plan_id,
        "candidate_feed_id":plan.candidate_feed_id, "source_hash":plan.source_hash, "evidence_hash":report["evidence_hash"]});
    let obligations = report["recovery_signatures"]["known_native_obligations"]
        .as_array()
        .ok_or_else(invalid)?;
    if recovery != request.recovery.to_json()
        || !covers_retained_membership(&report)
        || !obligations.iter().any(|row| {
            row["original"]["record_id"] == request.original_id
                && row["requirement"] == "fresh_manager_signature"
        })
    {
        return Err(Error::Changed);
    }
    let original = sources
        .signed
        .get(&request.original_id)
        .ok_or_else(invalid)?;
    let original_hash = source_hash(original)?;
    if original_hash != request.original_hash.to_hex() {
        return Err(Error::Changed);
    }
    let source = ControlRecord::parse(&serde_json::to_vec(original).map_err(|_| invalid())?)
        .map_err(|_| invalid())?;
    let principal = source.principal().name();
    // A lost reply can leave an older Station reservation unseen by the
    // manager until after another draft for this principal reached its journal.
    let mut floor = source.issued_at().max(request.after_issued_at.unwrap_or(0));
    for key in ["known_history", "recovery_signatures"] {
        let marks = report[key]["observed_signing_lower_bounds"]
            .as_object()
            .ok_or_else(invalid)?;
        if let Some(mark) = marks.get(&principal) {
            floor = floor.max(mark.as_u64().ok_or_else(invalid)?);
        }
    }
    let mut receipt = json!({"recovery":recovery, "expected":log.head().to_json(), "manager":request.manager,
        "original_record_id":request.original_id, "original_hash":original_hash,
        "origin":binding.origin, "account_id":log.account_id(), "genesis_hash":genesis});
    let review_hash = source_hash(&receipt)?;
    let old: Option<(String, i64)> = sqlx::query_as(
        "SELECT review_hash,issued_at FROM station_delegated_copy_reservations
        WHERE plan_id=$1 AND original_id=$2 AND manager=$3",
    )
    .bind(&plan.plan_id)
    .bind(&request.original_id)
    .bind(&request.manager)
    .fetch_optional(&mut *tx)
    .await?;
    let now: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint")
            .fetch_one(&mut *tx)
            .await?;
    let now = u64::try_from(now)
        .ok()
        .filter(|t| (1..=MAX_TIME).contains(t))
        .ok_or_else(invalid)?;
    let current = old.as_ref().and_then(|(hash, t)| {
        u64::try_from(*t)
            .ok()
            .filter(|stamp| hash == &review_hash && *stamp > floor)
    });
    let stamp = if let Some(stamp) = current {
        if request.issued_at.is_some_and(|expected| expected != stamp) {
            return Err(Error::Changed);
        }
        if stamp > now {
            return Err(Error::Clock);
        }
        stamp
    } else {
        // Rechecking a protected draft must never mint a replacement for it.
        if request.issued_at.is_some() {
            return Err(Error::Changed);
        }
        if old.is_none() {
            let count: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM station_delegated_copy_reservations WHERE plan_id=$1",
            )
            .bind(&plan.plan_id)
            .fetch_one(&mut *tx)
            .await?;
            if count >= 4096 {
                return Err(Error::Limit);
            }
        }
        let last: Option<i64> = sqlx::query_scalar("SELECT max(r.issued_at) FROM station_delegated_copy_reservations r
            JOIN station_delegated_recovery_plans p USING(plan_id) WHERE p.origin=$1 AND p.genesis_hash=$2 AND r.principal=$3")
            .bind(&binding.origin).bind(genesis).bind(&principal).fetch_one(&mut *tx).await?;
        if now <= floor || last.is_some_and(|t| t >= now as i64) {
            return Err(Error::Clock);
        }
        sqlx::query("INSERT INTO station_delegated_copy_reservations(plan_id, original_id, manager, principal, review_hash, issued_at)
            VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT(plan_id,original_id,manager) DO UPDATE SET
            review_hash=EXCLUDED.review_hash, issued_at=EXCLUDED.issued_at")
            .bind(&plan.plan_id).bind(&request.original_id).bind(&request.manager).bind(&principal)
            .bind(review_hash).bind(now as i64).execute(&mut *tx).await?;
        now
    };
    receipt["issued_at"] = stamp.into();
    tx.commit().await?;
    Ok(receipt)
}
