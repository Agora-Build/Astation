use super::{invalid, source_hash, Binding, MAX_STATE};
use crate::integration_feed::FeedBinding;
use crate::remote_api::recovery::delegated::ReportControlEvent;
use futures_util::TryStreamExt;
use serde_json::{json, Value};
use sqlx::PgConnection;
use std::collections::HashSet;

fn operator_resume_count(events: &[ReportControlEvent]) -> Result<usize, sqlx::Error> {
    // The first Resume installs the initial client. Every later Resume is
    // committed together with one distinct operator ID.
    let Some((ReportControlEvent::Resume(_), later)) = events.split_first() else {
        return Err(invalid());
    };
    Ok(later.iter().filter(|event| matches!(event, ReportControlEvent::Resume(_))).count())
}

/// Restore an operator-selected stopped or outstanding journal while all
/// reporters are fenced. An enabled observation cannot authorize a resume.
pub(crate) async fn restore_stop(
    pool: &sqlx::PgPool,
    fence: &Binding,
    portal: &FeedBinding,
    expected: &str,
) -> Result<Value, sqlx::Error> {
    if portal.station_origin != fence.origin || !super::super::canonical_genesis(expected) {
        return Err(invalid());
    }
    let mut tx = pool.begin().await?;
    sqlx::query("SET LOCAL statement_timeout='5s'").execute(&mut *tx).await?;
    fence.lock_mode(&mut tx, false).await?;
    let key = portal.report_control_binding();
    let archive: Option<Value> = sqlx::query_scalar(
        "SELECT CASE WHEN octet_length(journal::text) <= $4 THEN journal END
         FROM station_delegated_reporting_history WHERE origin=$1 AND binding=$2 AND evidence_hash=$3
         AND first_generation <= $5",
    )
    .bind(&fence.origin).bind(&key).bind(expected).bind(MAX_STATE as i64).bind(fence.generation)
    .fetch_one(&mut *tx).await?;
    let archive = archive.ok_or_else(invalid)?;
    if source_hash(&archive)? != expected {
        return Err(invalid());
    }
    let proposed: Vec<ReportControlEvent> =
        serde_json::from_value(archive["events"].clone()).map_err(|_| invalid())?;
    let claim: Option<String> = serde_json::from_value(archive["in_flight"].clone()).map_err(|_| invalid())?;
    let stopped = matches!(proposed.last(), Some(ReportControlEvent::Stop(_)));
    if proposed.is_empty() || (!stopped && claim.is_none()) {
        return Err(invalid());
    }

    sqlx::query("INSERT INTO station_delegated_reporting(binding,events,in_flight)
                 VALUES ($1,$2,$3) ON CONFLICT DO NOTHING")
        .bind(&key).bind(&archive["events"]).bind(&claim).execute(&mut *tx).await?;
    let (live, pending): (Value, Option<String>) = sqlx::query_as(
        "SELECT events,in_flight FROM station_delegated_reporting WHERE binding=$1 FOR UPDATE",
    ).bind(&key).fetch_one(&mut *tx).await?;
    let live: Vec<ReportControlEvent> = serde_json::from_value(live).map_err(|_| invalid())?;
    if !proposed.starts_with(&live) || pending.is_some() && pending != claim
        || reconcile_report_restart(&mut tx, portal, &proposed, claim.as_deref()).await? {
        return Err(invalid());
    }
    if live != proposed || pending != claim {
        sqlx::query("UPDATE station_delegated_reporting SET events=$2,in_flight=$3 WHERE binding=$1")
            .bind(&key).bind(&archive["events"]).bind(&claim).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    Ok(json!({"generation":fence.generation.to_string(),"source_evidence_hash":expected,
        "retained_events":proposed.len(),"stopped":stopped,"outstanding_delivery":claim.is_some(),
        "recovery_ready":false}))
}

/// Validate event history and restore consumed resume IDs under the journal
/// and deployment locks. A lost delivery claim requires a fresh explicit resume.
pub(crate) async fn reconcile_report_restart(
    connection: &mut PgConnection,
    portal: &FeedBinding,
    events: &[ReportControlEvent],
    in_flight: Option<&str>,
) -> Result<bool, sqlx::Error> {
    let key = portal.report_control_binding();
    let (needs_resume, has_history, archived_ids) =
        compare_journals(connection, portal, events, in_flight).await?;
    if has_history {
        sqlx::query(
            "INSERT INTO station_delegated_report_resumptions(binding,resume_id)
             SELECT $1, id::uuid FROM unnest($2::text[]) AS prior(id) ON CONFLICT DO NOTHING",
        )
        .bind(&key).bind(archived_ids.iter().map(ToString::to_string).collect::<Vec<_>>())
        .execute(&mut *connection).await?;
        let consumed: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM station_delegated_report_resumptions WHERE binding=$1",
        ).bind(&key).fetch_one(connection).await?;
        if consumed != operator_resume_count(events)? as i64 {
            return Err(invalid());
        }
    }
    Ok(needs_resume)
}

async fn compare_journals(
    connection: &mut PgConnection,
    portal: &FeedBinding,
    events: &[ReportControlEvent],
    in_flight: Option<&str>,
) -> Result<(bool, bool, HashSet<uuid::Uuid>), sqlx::Error> {
    let key = portal.report_control_binding();
    let mut rows = sqlx::query_as::<_, (String, Option<Value>)>(
        "SELECT h.evidence_hash, CASE WHEN octet_length(h.journal::text) <= $3 THEN h.journal END
         FROM station_delegated_reporting_history h WHERE h.origin=$1 AND h.binding=$2
         ORDER BY jsonb_array_length(h.journal->'events')",
    )
    .bind(&portal.station_origin)
    .bind(&key)
    .bind(MAX_STATE as i64)
    .fetch(&mut *connection);
    let mut needs_resume = false;
    let mut has_history = false;
    let mut archived_ids = HashSet::new();
    while let Some((hash, journal)) = rows.try_next().await? {
        let journal = journal.ok_or_else(invalid)?;
        if source_hash(&journal)? != hash {
            return Err(invalid());
        }
        let prior: Vec<ReportControlEvent> =
            serde_json::from_value(journal["events"].clone()).map_err(|_| invalid())?;
        let later = events.strip_prefix(prior.as_slice()).ok_or_else(invalid)?;
        for value in journal["resume_ids"].as_array().ok_or_else(invalid)? {
            archived_ids.insert(uuid::Uuid::parse_str(value.as_str().ok_or_else(invalid)?)
                .map_err(|_| invalid())?);
        }
        if archived_ids.len() > operator_resume_count(&prior)? {
            return Err(invalid());
        }
        if !journal["in_flight"].is_null() {
            let claim = journal["in_flight"].as_str().ok_or_else(invalid)?;
            needs_resume |= in_flight != Some(claim)
                && !later.iter().any(|event| matches!(event, ReportControlEvent::Resume(_)));
        }
        has_history = true;
    }
    Ok((needs_resume, has_history, archived_ids))
}

/// Read the reporting state captured under the closed fence. A lost stop or
/// delivery claim remains visible to the operator without preparing an open ledger.
pub(super) async fn candidate_events(
    db: &mut PgConnection, portal: &FeedBinding, genesis: &str, history: &Value,
) -> Result<Option<Vec<ReportControlEvent>>, sqlx::Error> {
    let events = match history["current_evidence_hash"].as_str() {
        None if history["distinct_journals"] == 0 => Vec::new(),
        None => return Ok(None),
        Some(hash) => match current_events(db, portal, hash).await? {
            Some(events) => events,
            None => return Ok(None),
        },
    };
    // An account's retained ledger may be the only surviving evidence of a
    // reporter stop or a journal prefix lost by the global reporting table.
    let states: Vec<(i64, Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT DISTINCT COALESCE((retained->'feed'->>'report_control_seq')::bigint,0),
            retained->'feed'->>'report_control_hash',retained->'feed'->'ledger'->>'stopped'
         FROM station_delegated_recovery_plans WHERE origin=$1 AND genesis_hash=$2",
    ).bind(&portal.station_origin).bind(genesis).fetch_all(db).await?;
    for (seq, hash, stopped) in states {
        let seq = usize::try_from(seq).map_err(|_| invalid())?;
        let Some(prefix) = events.get(..seq) else { return Ok(None) };
        if hash.is_some_and(|hash| hash != crate::remote_api::recovery::delegated::report_events_hash(prefix)) {
            return Ok(None);
        }
        if let Some(client) = stopped {
            let stop = ReportControlEvent::Stop(client);
            if prefix.last() != Some(&stop) && !events[seq..].contains(&stop) {
                return Ok(None);
            }
        }
    }
    Ok(Some(events))
}

async fn current_events(
    db: &mut PgConnection, portal: &FeedBinding, hash: &str,
) -> Result<Option<Vec<ReportControlEvent>>, sqlx::Error> {
    let journal: Value = sqlx::query_scalar(
        "SELECT journal FROM station_delegated_reporting_history WHERE origin=$1 AND binding=$2 AND evidence_hash=$3",
    ).bind(&portal.station_origin).bind(portal.report_control_binding()).bind(hash)
        .fetch_one(&mut *db).await?;
    if source_hash(&journal)? != hash { return Err(invalid()); }
    let events: Vec<ReportControlEvent> = serde_json::from_value(journal["events"].clone()).map_err(|_| invalid())?;
    let claim: Option<String> = serde_json::from_value(journal["in_flight"].clone()).map_err(|_| invalid())?;
    match compare_journals(db, portal, &events, claim.as_deref()).await {
        Ok((needs_resume, _, archived_ids)) => {
            let stopped = matches!(events.last(), Some(ReportControlEvent::Stop(_)));
            if (needs_resume && !stopped) || archived_ids.len() != operator_resume_count(&events)? {
                return Ok(None);
            }
            Ok(Some(events))
        }
        // The ordinary recovery review must stay available to reconcile a restored prefix.
        Err(sqlx::Error::Protocol(_)) => Ok(None),
        Err(error) => Err(error),
    }
}

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
    .fetch_one(&mut *connection)
    .await?;
    let candidate: Option<String> = sqlx::query_scalar(
        "SELECT evidence_hash FROM station_delegated_reporting_history WHERE origin=$1 AND binding=$2
         AND ((journal->'events'->-1) ? 'Stop' OR journal->'in_flight' <> 'null'::jsonb)
         ORDER BY jsonb_array_length(journal->'events') DESC, first_generation DESC, evidence_hash LIMIT 1",
    ).bind(&fence.origin).bind(&binding).fetch_optional(connection).await?;
    Ok(json!({"current_evidence_hash":current, "distinct_journals":observations.0,
        "retained_stop_or_claim_hash":candidate,
        "observed_stopped_client":observations.1, "observed_uncertain_delivery":observations.2}))
}
