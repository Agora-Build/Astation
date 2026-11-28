//! Write the exact private feed image under the same fence as the reviewed records.
use super::{candidate_snapshot::Candidate, invalid, reporting_history, source_hash, Prepared};
use crate::integration_feed::FeedBinding;
use crate::remote_api::recovery::delegated::Stored;
use atem_client::{canonical::MAX_SAFE_INTEGER, control::ControlPrincipal, membership::Membership};
use serde_json::{json, Value};
use sqlx::PgConnection;
use std::collections::BTreeMap;

fn floors(review: &Value) -> Result<BTreeMap<String, u64>, sqlx::Error> {
    let mut result = BTreeMap::<String, u64>::new();
    let mut observe = |principal: &str, time: &Value| {
        let ms = time
            .as_u64()
            .filter(|ms| *ms <= MAX_SAFE_INTEGER)
            .ok_or_else(invalid)?;
        if ControlPrincipal::parse(principal).is_none_or(|p| p.name() != principal) {
            return Err(invalid());
        }
        let high = result.entry(principal.to_owned()).or_default();
        *high = (*high).max(ms);
        Ok(())
    };
    for source in [
        &review["known_history"]["observed_signing_lower_bounds"],
        &review["recovery_signatures"]["observed_signing_lower_bounds"],
        &review["reserved_copy_times"],
    ] {
        for (principal, ms) in source.as_object().ok_or_else(invalid)? {
            observe(principal, ms)?;
        }
    }
    for key in review["service_clock_evidence"]["reservations"]
        .as_array()
        .ok_or_else(invalid)?
    {
        let id = key["service_id"].as_str().ok_or_else(invalid)?;
        observe(
            &ControlPrincipal::Service(id.into()).name(),
            &key["highest_ms"],
        )?;
    }
    Ok(result)
}

pub(super) async fn stage(
    db: &mut PgConnection,
    plan: &Prepared,
    log: &Membership,
    portal: &FeedBinding,
    review: &mut Value,
    candidate: Candidate,
) -> Result<(), sqlx::Error> {
    let records = match candidate {
        Candidate::Waiting(reason) => {
            review["candidate_snapshot"] = json!({"status":reason});
            return Ok(());
        }
        Candidate::Assembled(records) => records,
    };
    let signed = Value::Array(records.iter().map(|r| r.object().to_json()).collect());
    let records_hash = source_hash(&signed)?;
    review["candidate_snapshot"] =
        json!({"status":"assembled","record_count":records.len(),"records_hash":records_hash});

    let Some(events) =
        reporting_history::candidate_events(db, portal, &log.genesis_hash().to_hex(), &review["reporting_history"]).await?
    else {
        review["replacement_feed"] = json!({"status":"awaiting_reporting_history"});
        return Ok(());
    };
    let watermarks = floors(review)?;
    let cut = source_hash(&json!({
        "plan_id":plan.plan_id,"candidate_feed_id":plan.candidate_feed_id,"source_hash":plan.source_hash,
        "membership_head":log.head().to_json(),"reconstruction_hash":review["reconstruction_hash"],
        "clock":review["service_clock_evidence_hash"],"portal":review["portal_service_evidence_hash"],
        "reporting":review["reporting_history"],"floors":watermarks,"records_hash":records_hash
    }))?;
    let prior: Option<i64> = sqlx::query_scalar(
        "SELECT captured_ms FROM station_delegated_replacement_feeds WHERE plan_id=$1 AND cut_hash=$2",
    ).bind(&plan.plan_id).bind(&cut).fetch_optional(&mut *db).await?;
    let now = super::super::super::now().wall_ms;
    let captured = match prior {
        Some(time) => u64::try_from(time).map_err(|_| invalid())?,
        None => now,
    };
    if captured > now || captured > MAX_SAFE_INTEGER {
        review["replacement_feed"] = json!({"status":"waiting_for_clock"});
        return Ok(());
    }
    let mut revocations = BTreeMap::new();
    for row in review["portal_service_evidence"]["services"]
        .as_array()
        .ok_or_else(invalid)?
    {
        if let Some(time) = row.get("revoked_at_ms") {
            let id = row["service_id"].as_str().ok_or_else(invalid)?;
            let key = row["key_fingerprint"].as_str().ok_or_else(invalid)?;
            revocations.insert(
                (id.to_owned(), key.to_owned()),
                time.as_u64().ok_or_else(invalid)?,
            );
        }
    }
    let feed = Stored::recovered(
        &portal.station_origin,
        log,
        &plan.candidate_feed_id,
        &records,
        watermarks,
        &revocations,
        &events,
        captured,
    )
    .map_err(|_| invalid())?;
    let feed = serde_json::to_value(feed).map_err(|_| invalid())?;
    let hash = source_hash(&feed)?;
    // The normal root reader bounds the entire JSONB row, including unrelated
    // routes and backups. A feed that fits by itself may not fit in the root.
    let fits: bool = sqlx::query_scalar(
        "SELECT octet_length((state || jsonb_build_object('delegated',
            COALESCE(state->'delegated','{}'::jsonb) || jsonb_build_object($2::text,$3::jsonb)))::text) <= $4
         FROM remote_recovery_roots WHERE genesis_hash=$1",
    ).bind(log.genesis_hash().to_hex()).bind(&portal.station_origin).bind(&feed)
        .bind(super::MAX_STATE as i64).fetch_one(&mut *db).await?;
    if !fits {
        review["replacement_feed"] = json!({"status":"recovery_root_too_large"});
        return Ok(());
    }
    let written = sqlx::query(
        "INSERT INTO station_delegated_replacement_feeds AS f(plan_id,cut_hash,captured_ms,feed_hash,feed)
         VALUES($1,$2,$3,$4,$5) ON CONFLICT(plan_id) DO UPDATE SET cut_hash=EXCLUDED.cut_hash,
         captured_ms=EXCLUDED.captured_ms,feed_hash=EXCLUDED.feed_hash,feed=EXCLUDED.feed
         WHERE f.cut_hash<>EXCLUDED.cut_hash",
    ).bind(&plan.plan_id).bind(&cut).bind(captured as i64).bind(&hash).bind(&feed)
        .execute(&mut *db).await?;
    if written.rows_affected() == 0 {
        let matches: bool = sqlx::query_scalar(
            "SELECT feed_hash=$3 AND feed=$4 FROM station_delegated_replacement_feeds
            WHERE plan_id=$1 AND cut_hash=$2",
        )
        .bind(&plan.plan_id)
        .bind(&cut)
        .bind(&hash)
        .bind(&feed)
        .fetch_one(db)
        .await?;
        if !matches {
            return Err(invalid());
        }
    }
    review["replacement_feed"] =
        json!({"status":"staged","cut_hash":cut,"feed_hash":hash,"captured_ms":captured});
    Ok(())
}
