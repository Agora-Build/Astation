//! Binding evidence identifies lost lists even when they never had a service key.
use super::{canonical_genesis, invalid_root};
use crate::integration_feed::{FeedBinding, PolicyStore};
use futures_util::TryStreamExt;
use sqlx::PgConnection;
use std::collections::BTreeSet;

pub(super) async fn list(
    db: &mut PgConnection,
    scope: &FeedBinding,
    after: Option<&str>,
    limit: usize,
) -> Result<BTreeSet<String>, sqlx::Error> {
    // An applied administrative release always references its retained request.
    let journal: Vec<String> = sqlx::query_scalar(
        r#"SELECT genesis COLLATE "C" FROM station_native_binding_transitions
           WHERE (issuer, portal_origin, station_origin) = ($1, $2, $3)
             AND ($4::text IS NULL OR genesis COLLATE "C" > $4)
           UNION
           SELECT genesis COLLATE "C" FROM station_binding_release_requests
           WHERE (issuer, portal_origin, station_origin) = ($1, $2, $3)
             AND ($4::text IS NULL OR genesis COLLATE "C" > $4)
           ORDER BY 1 LIMIT $5"#,
    )
    .bind(&scope.issuer)
    .bind(&scope.portal_origin)
    .bind(&scope.station_origin)
    .bind(after)
    .bind(limit as i64)
    .fetch_all(&mut *db)
    .await?;
    if journal.iter().any(|genesis| !canonical_genesis(genesis)) {
        return Err(invalid_root());
    }
    let mut roots: BTreeSet<String> = journal.into_iter().collect();

    // A previous report client can hold the only surviving authenticated cut.
    // Validate each cut against its own credential and keep at most one page.
    let mut checkpoints = sqlx::query_as::<_, (String, String)>(
        "SELECT binding, checkpoint FROM station_integration_policy
         WHERE binding::jsonb->>'issuer' = $1 AND binding::jsonb->>'portal_origin' = $2
           AND binding::jsonb->>'station_origin' = $3",
    )
    .bind(&scope.issuer)
    .bind(&scope.portal_origin)
    .bind(&scope.station_origin)
    .fetch(db);
    while let Some((key, saved)) = checkpoints.try_next().await? {
        let source: FeedBinding = serde_json::from_str(&key).map_err(|_| invalid_root())?;
        source.validate().map_err(|_| invalid_root())?;
        let policy = PolicyStore::decode_checkpoint(&source, Some(saved)).map_err(|_| invalid_root())?;
        if let Some(cut) = policy.portal_snapshot {
            let bindings = cut.bindings.into_iter().flatten().map(|row| row.genesis_hash);
            let releases = cut.pending_releases.into_iter().flatten().map(|row| row.genesis_hash);
            for genesis in bindings.chain(releases) {
                if after.is_none_or(|cursor| genesis.as_str() > cursor) {
                    roots.insert(genesis);
                    if roots.len() > limit {
                        roots.pop_last();
                    }
                }
            }
        }
    }
    Ok(roots)
}
