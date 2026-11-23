//! Account-private terminal evidence. Only the local operator, under the same
//! deployment fence as preparation, can permanently abandon this candidate.
use super::{invalid, Binding, Status};
use serde_json::{json, Value};
use sqlx::PgPool;

#[derive(sqlx::FromRow)]
struct Outcome {
    generation: i64,
    plan_id: String,
    candidate_feed_id: String,
    source_hash: String,
    account_id: String,
    abandoned: bool,
}

impl Outcome {
    fn receipt(&self, origin: &str, genesis: &str) -> Value {
        json!({"account_id":self.account_id,"genesis_hash":genesis,"origin":origin,
            "generation":self.generation.to_string(),"plan_id":self.plan_id,"candidate_feed_id":self.candidate_feed_id,
            "source_hash":self.source_hash,"outcome":if self.abandoned {"abandoned"} else {"pending"}})
    }
}

pub(crate) async fn for_owner(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    plan: &str,
    owner: &str,
) -> Result<Value, sqlx::Error> {
    let row: Outcome = sqlx::query_as(
        "SELECT p.generation,p.plan_id,p.candidate_feed_id,p.source_hash,p.retained->>'account_id' AS account_id,p.abandoned
         FROM station_delegated_recovery_plans p JOIN remote_recovery_roots r USING(genesis_hash)
         JOIN station_delegated_recovery f ON f.origin=p.origin
         WHERE p.genesis_hash=$1 AND p.plan_id=$2 AND p.origin=$3 AND f.generation=$4 AND p.generation <= f.generation
           AND r.account_subject=$5 AND p.retained->>'account_subject'=$5")
        .bind(genesis).bind(plan).bind(&binding.origin).bind(binding.generation).bind(owner).fetch_one(pool).await?;
    Ok(row.receipt(&binding.origin, genesis))
}

pub(crate) async fn abandon(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    plan: &str,
) -> Result<Value, sqlx::Error> {
    let mut tx = pool.begin().await?;
    sqlx::query("SET LOCAL statement_timeout='5s'")
        .execute(&mut *tx)
        .await?;
    let fence: Status = sqlx::query_as(
        "SELECT generation,ready,reason FROM station_delegated_recovery WHERE origin=$1 FOR UPDATE",
    )
    .bind(&binding.origin)
    .fetch_one(&mut *tx)
    .await?;
    if fence.ready || fence.generation != binding.generation {
        return Err(invalid());
    }
    let owner: Option<String> = sqlx::query_scalar(
        "SELECT account_subject FROM remote_recovery_roots WHERE genesis_hash=$1 FOR UPDATE",
    )
    .bind(genesis)
    .fetch_one(&mut *tx)
    .await?;
    let owner = owner.filter(|v| !v.is_empty()).ok_or_else(invalid)?;
    let row: Outcome = sqlx::query_as(
        "UPDATE station_delegated_recovery_plans SET abandoned=true
         WHERE origin=$1 AND generation=$2 AND genesis_hash=$3 AND plan_id=$4 AND retained->>'account_subject'=$5
         RETURNING generation,plan_id,candidate_feed_id,source_hash,retained->>'account_id' AS account_id,abandoned"
    ).bind(&binding.origin).bind(binding.generation).bind(genesis).bind(plan).bind(owner).fetch_one(&mut *tx).await?;
    tx.commit().await?;
    Ok(row.receipt(&binding.origin, genesis))
}
