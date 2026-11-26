use super::{invalid, source_hash, Binding, MAX_STATE};
use crate::integration_feed::FeedBinding;
use serde_json::{json, Value};
use sqlx::PgConnection;

/// Preparation holds the deployment fence through commit. The live reporter
/// takes the same fence before changing either the journal or consumed resume IDs.
pub(super) async fn retain(
    connection: &mut PgConnection,
    fence: &Binding,
    portal: &FeedBinding,
) -> Result<Value, sqlx::Error> {
    let binding = portal.report_control_binding();
    let row: Option<Option<Value>> = sqlx::query_scalar(
        "SELECT CASE WHEN octet_length(journal::text) <= $2 THEN journal END FROM (
           SELECT jsonb_build_object('events', events, 'in_flight', in_flight, 'resume_ids',
             (SELECT COALESCE(jsonb_agg(resume_id ORDER BY resume_id), '[]'::jsonb)
              FROM station_delegated_report_resumptions WHERE binding=$1)) AS journal
           FROM station_delegated_reporting WHERE binding=$1
         ) observed",
    )
    .bind(&binding)
    .bind(MAX_STATE as i64)
    .fetch_optional(&mut *connection)
    .await?;
    let current = match row {
        Some(Some(journal)) => {
            let hash = source_hash(&journal)?;
            let inserted = sqlx::query(
                "INSERT INTO station_delegated_reporting_history
                 (origin,binding,first_generation,evidence_hash,journal) VALUES ($1,$2,$3,$4,$5)
                 ON CONFLICT (origin,binding,evidence_hash) DO NOTHING",
            )
            .bind(&fence.origin)
            .bind(&binding)
            .bind(fence.generation)
            .bind(&hash)
            .bind(&journal)
            .execute(&mut *connection)
            .await?;
            if inserted.rows_affected() == 0 {
                let matches: bool = sqlx::query_scalar(
                    "SELECT journal=$4 AND first_generation <= $5 FROM station_delegated_reporting_history
                     WHERE origin=$1 AND binding=$2 AND evidence_hash=$3",
                )
                .bind(&fence.origin)
                .bind(&binding)
                .bind(&hash)
                .bind(&journal)
                .bind(fence.generation)
                .fetch_one(&mut *connection)
                .await?;
                if !matches {
                    return Err(invalid());
                }
            }
            Some(hash)
        }
        Some(None) => return Err(invalid()),
        None => None,
    };
    // The operator gets commitments and delivery state. Claim and resume IDs
    // stay in Station storage with the original events for reconciliation.
    let observations: (i64, bool, bool) = sqlx::query_as(
        "SELECT count(*),
                COALESCE(bool_or((journal->'events'->-1) ? 'Stop'),false),
                COALESCE(bool_or(journal->'in_flight' <> 'null'::jsonb),false)
         FROM station_delegated_reporting_history WHERE origin=$1 AND binding=$2",
    )
    .bind(&fence.origin)
    .bind(&binding)
    .fetch_one(connection)
    .await?;
    Ok(json!({"current_evidence_hash":current, "distinct_journals":observations.0,
        "observed_stopped_client":observations.1, "observed_uncertain_delivery":observations.2}))
}
