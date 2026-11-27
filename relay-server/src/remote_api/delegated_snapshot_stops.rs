//! Assemble the signed revokes and interrupts for a replacement snapshot.
use super::{checkpoint, invalid, review_evidence, source_hash, Binding, Prepared};
use atem_client::{
    control::{
        check_snapshot_consistency, verify_control, ControlAction, ControlCheck, ControlPrincipal, ControlRecord,
        RefusalReason, SnapshotConsistency, SnapshotInput,
    },
    membership::Membership,
};
use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool};
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
    ) -> Result<Vec<ControlRecord>, sqlx::Error> {
        let mut originals = Vec::new();
        let mut selected_records = BTreeMap::new();
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
            // The same signed copy can be both a replacement and a retained
            // original in its own right. Publish its bytes once.
            selected_records.insert(selected.record_id().to_owned(), selected);
        }
        let snapshot: Vec<_> = selected_records.into_values().collect();
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
        Ok(snapshot)
    }
}

fn records_json(records: &[ControlRecord]) -> Value {
    Value::Array(records.iter().map(|r| r.object().to_json()).collect())
}

/// Read only the stop component already committed for this reconstruction.
/// Reassembly also checks omitted or substituted records after a restore.
pub(super) async fn staged_service_revokes(
    connection: &mut PgConnection,
    sources: StopSources,
    plan: &Prepared,
    log: &Membership,
    origin: &str,
    reconstruction: &str,
) -> Result<BTreeMap<(String, String), String>, sqlx::Error> {
    let staged: Option<Value> = sqlx::query_scalar(
        "SELECT records FROM station_delegated_snapshot_stops
         WHERE plan_id=$1 AND reconstruction_hash=$2",
    )
    .bind(&plan.plan_id)
    .bind(reconstruction)
    .fetch_optional(connection)
    .await?;
    let mut revokes = BTreeMap::new();
    if let Some(staged) = staged {
        let records = sources.assemble(log, origin, plan)?;
        if records_json(&records) != staged {
            return Err(invalid());
        }
        for record in records {
            if let (ControlPrincipal::Service(id), ControlAction::Revoke { .. }) =
                (record.principal(), record.action())
            {
                let fingerprint = record.principal_key().ok_or_else(invalid)?.to_hex();
                revokes.entry((id.clone(), fingerprint)).or_insert_with(|| record.record_id().to_owned());
            }
        }
    }
    Ok(revokes)
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
    let records = records_json(&sources.assemble(&log, &binding.origin, &plan)?);
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
