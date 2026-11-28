use super::{invalid, Prepared};
use atem_client::{channel::HeadRelation, membership::Membership, Hash32};
use serde_json::Value;
use sqlx::PgConnection;
use std::collections::BTreeMap;

fn verified(account: &str, genesis: &Hash32, stored: &Value) -> Result<Membership, sqlx::Error> {
    let log = Membership::from_stored(account, genesis, stored).map_err(|_| invalid())?;
    if log.frozen().is_some() {
        return Err(invalid());
    }
    Ok(log)
}

fn extends(previous: &Membership, next: &Membership) -> bool {
    let last_decision = previous
        .records()
        .iter()
        .filter_map(|r| r.decision.as_ref())
        .map(|d| d.order)
        .max()
        .unwrap_or(0);
    HeadRelation::of(next, previous.head()) == HeadRelation::HostBehind
        && next.evidence().count >= previous.evidence().count
        && previous.records().iter().all(|old| {
            next.records()
                .iter()
                .find(|new| new.seq == old.seq)
                .is_some_and(|new| {
                    old.entry_hash == new.entry_hash
                        && old.clock.first_seen_wall == new.clock.first_seen_wall
                        && (old.clock.boot_id != new.clock.boot_id
                            || old.clock.mono_anchor_ms == new.clock.mono_anchor_ms)
                        && new.clock.mono_waited_ms >= old.clock.mono_waited_ms
                        && match &old.decision {
                            Some(decision) => new.decision.as_ref() == Some(decision),
                            None => new.decision.as_ref().is_none_or(|d| {
                                d.at_seq >= previous.head().seq && d.order > last_decision
                            }),
                        }
                })
        })
}

/// Called with the deployment and root locked. A retry on any replica must
/// extend the last committed observation, including after the root is restored.
pub(super) async fn observe(
    db: &mut PgConnection,
    plan: &Prepared,
    log: &Membership,
    stored: &Value,
    prepare: bool,
) -> Result<(), sqlx::Error> {
    let latest: Option<Value> = sqlx::query_scalar(
        "SELECT CASE WHEN octet_length(membership::text) <= $2 THEN membership END FROM station_delegated_recovery_memberships
         WHERE plan_id=$1 ORDER BY seq DESC LIMIT 1",
    ).bind(&plan.plan_id).bind(super::MAX_STATE as i64).fetch_optional(&mut *db).await?;
    let previous = latest.as_ref().unwrap_or(&plan.retained["membership"]);
    if previous == stored {
        return Ok(());
    }
    if !prepare {
        // Only operator preparation may persist a new review cut.
        return Err(invalid());
    }
    let old = verified(log.account_id(), &log.genesis_hash(), previous)?;
    if !extends(&old, log) {
        return Err(invalid());
    }
    sqlx::query("INSERT INTO station_delegated_recovery_memberships(plan_id,seq,membership) VALUES ($1,$2,$3)")
        .bind(&plan.plan_id).bind(log.head().seq as i64).bind(stored).execute(db).await?;
    Ok(())
}

pub(super) async fn history(
    db: &mut PgConnection,
    plan: &Prepared,
    initial: Membership,
) -> Result<BTreeMap<u64, Membership>, sqlx::Error> {
    let mut heads = BTreeMap::from([(initial.head().seq, initial)]);
    let rows: Vec<(i64, Value)> = sqlx::query_as(
        "SELECT seq,membership FROM station_delegated_recovery_memberships WHERE plan_id=$1 ORDER BY seq",
    ).bind(&plan.plan_id).fetch_all(db).await?;
    for (seq, stored) in rows {
        let previous = heads.last_key_value().ok_or_else(invalid)?.1;
        let next = verified(previous.account_id(), &previous.genesis_hash(), &stored)?;
        if seq != next.head().seq as i64 || !extends(previous, &next) {
            return Err(invalid());
        }
        heads.insert(next.head().seq, next);
    }
    Ok(heads)
}
