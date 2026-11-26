//! Assemble the signed revokes and interrupts for a replacement snapshot.
use super::{checkpoint, invalid, review_evidence, source_hash, Binding, Prepared};
use atem_client::{
    control::{
        check_snapshot_consistency, verify_control, ControlAction, ControlCheck, ControlRecord,
        RefusalReason, SnapshotConsistency, SnapshotInput,
    },
    membership::Membership,
};
use serde_json::{json, Value};
use sqlx::PgPool;
use std::collections::BTreeMap;

pub(super) struct StopSources {
    pub signed: BTreeMap<String, Value>,
    pub copies: BTreeMap<String, ControlRecord>,
}

impl StopSources {
    fn assemble(
        mut self,
        log: &Membership,
        origin: &str,
        plan: &Prepared,
    ) -> Result<Value, sqlx::Error> {
        let mut originals = Vec::new();
        let mut snapshot = Vec::new();
        for (id, value) in self.signed {
            let original =
                ControlRecord::parse(&serde_json::to_vec(&value).map_err(|_| invalid())?)
                    .map_err(|_| invalid())?;
            if !matches!(
                original.action(),
                ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. }
            ) {
                continue;
            }
            // Every source stop needs its own original or reviewed equivalent, even
            // when a different stop for this principal already has the same effect.
            let selected = match verify_control(&original, log) {
                ControlCheck::Valid(_) => original.clone(),
                ControlCheck::Refused(RefusalReason::RemovedManager) => {
                    self.copies.remove(&id).ok_or_else(invalid)?
                }
                _ => return Err(invalid()),
            };
            originals.push(original);
            snapshot.push(selected);
        }
        let input = SnapshotInput {
            list: log,
            origin,
            candidate_feed_id: &plan.candidate_feed_id,
            retained: &originals,
            snapshot: &snapshot,
            // This component carries only stops. Fresh service signatures and
            // coverage belong to the subsequent complete-snapshot check.
            marks: &Default::default(),
            covered: &Default::default(),
        };
        if check_snapshot_consistency(&input).map_err(|_| invalid())?
            != SnapshotConsistency::Consistent
        {
            return Err(invalid());
        }
        Ok(Value::Array(
            snapshot.iter().map(|r| r.object().to_json()).collect(),
        ))
    }
}

pub(crate) async fn stage(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    expected: &str,
) -> Result<Value, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let (plan, log, mut review) = checkpoint(&mut tx, binding, genesis, false).await?;
    let sources = review_evidence(&mut tx, &plan, &log, binding, &mut review, false).await?;
    if review["reconstruction_hash"] != expected {
        return Err(invalid());
    }
    let records = sources.assemble(&log, &binding.origin, &plan)?;
    let records_hash = source_hash(&records)?;
    // The fence and root are locked. Only a changed review replaces a row.
    // An exact retry after a lost response verifies the committed component below.
    let changed = sqlx::query(
        "INSERT INTO station_delegated_snapshot_stops AS s (plan_id,reconstruction_hash,records)
         VALUES ($1,$2,$3) ON CONFLICT (plan_id) DO UPDATE
         SET reconstruction_hash=EXCLUDED.reconstruction_hash,records=EXCLUDED.records
         WHERE s.reconstruction_hash<>EXCLUDED.reconstruction_hash",
    )
    .bind(&plan.plan_id)
    .bind(expected)
    .bind(&records)
    .execute(&mut *tx)
    .await?;
    if changed.rows_affected() == 0 {
        let matches: bool = sqlx::query_scalar(
            "SELECT records=$3 FROM station_delegated_snapshot_stops
             WHERE plan_id=$1 AND reconstruction_hash=$2",
        )
        .bind(&plan.plan_id)
        .bind(expected)
        .bind(&records)
        .fetch_one(&mut *tx)
        .await?;
        if !matches {
            return Err(invalid());
        }
    }
    tx.commit().await?;
    Ok(json!({
        "plan_id":plan.plan_id,"candidate_feed_id":plan.candidate_feed_id,
        "reconstruction_hash":expected,"records_hash":records_hash,"stop_count":records.as_array().ok_or_else(invalid)?.len(),
        "snapshot_complete":false,"recovery_ready":false,
    }))
}
