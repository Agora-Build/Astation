//! Apply a Portal release to the binding the Station last recorded.
use super::{FeedBinding, PolicyCheckpoint, PolicyStore};
use crate::integration_checkpoint::PortalCheckpoint;
use crate::remote_api::recovery::delegated_recovery::Binding as RecoveryFence;

impl PolicyCheckpoint {
    /// A stale Portal mirror cannot undo a transition already committed by this Station.
    pub(crate) async fn effective_binding(
        &self,
        db: &mut sqlx::PgConnection,
        account: &str,
        genesis: &str,
    ) -> Result<Option<crate::integration_checkpoint::Binding>, sqlx::Error> {
        use crate::integration_checkpoint::Binding;
        let invalid = || sqlx::Error::Protocol("missing or inconsistent Station binding".into());
        let rows = self
            .portal_snapshot
            .as_ref()
            .and_then(|s| s.bindings.as_ref())
            .ok_or_else(invalid)?;
        let mut current = rows
            .iter()
            .find(|r| r.account_id == account && r.genesis_hash == genesis)
            .cloned();
        let local: Vec<(serde_json::Value,)> = sqlx::query_as(
            "(SELECT report - 'state' - 'reportId' FROM station_native_binding_transitions
              WHERE (issuer,portal_origin,station_origin,account_id,genesis)=($1,$2,$3,$4,$5)
              ORDER BY version DESC LIMIT 1)
             UNION ALL
             (SELECT report - 'state' - 'reportId' FROM station_applied_binding_releases
              WHERE (issuer,portal_origin,station_origin,account_id,genesis)=($1,$2,$3,$4,$5)
              ORDER BY version DESC LIMIT 1)",
        )
        .bind(&self.binding.issuer)
        .bind(&self.binding.portal_origin)
        .bind(&self.binding.station_origin)
        .bind(account)
        .bind(genesis)
        .fetch_all(db)
        .await?;
        for (value,) in local {
            let row: Binding = serde_json::from_value(value).map_err(|_| invalid())?;
            if let Some(seen) = &current {
                if row.version == seen.version && &row != seen {
                    return Err(invalid());
                }
                if row.version <= seen.version {
                    continue;
                }
            }
            current = Some(row);
        }
        Ok(current)
    }
}

impl PolicyStore {
    /// The Portal settles a release atomically with a higher binding version.
    /// Its checkpoint proves the outbound report is redundant after a lost
    /// response. This evidence says nothing about a replica's local sockets.
    pub(super) async fn confirm_binding_releases(
        tx: &mut sqlx::PgConnection,
        snapshot: &PortalCheckpoint,
    ) -> Result<(), ()> {
        let (Some(bindings), Some(pending)) = (&snapshot.bindings, &snapshot.pending_releases) else {
            return Ok(());
        };
        sqlx::query(
            r#"UPDATE station_applied_binding_releases a SET portal_version=b.version
               FROM jsonb_to_recordset($4::jsonb) AS b(
                   "accountId" text,"genesisHash" text,"bindingId" text,account text,
                   "bindingState" text,version bigint)
               WHERE (a.issuer,a.portal_origin,a.station_origin)=($1,$2,$3)
                 AND a.portal_version IS NULL AND (a.account_id,a.genesis)=(b."accountId",b."genesisHash")
                 AND (b.version > a.version OR (b.version=a.version AND b."bindingState"='released'
                   AND b."bindingId"=a.report->>'bindingId' AND b.account=a.report->>'account'))
                 AND NOT (a.release_id=ANY($5))"#,
        )
        .bind(&snapshot.binding.issuer)
        .bind(&snapshot.binding.portal_origin)
        .bind(&snapshot.binding.station_origin)
        .bind(sqlx::types::Json(bindings))
        .bind(pending.iter().map(|r| r.release_id.as_str()).collect::<Vec<_>>())
        .execute(tx)
        .await
        .map_err(|_| ())?;
        Ok(())
    }

    pub(crate) async fn apply_binding_releases(
        &self,
        station: &FeedBinding,
        fence: &RecoveryFence,
    ) -> Result<u64, ()> {
        if !PortalCheckpoint::built_in(station) || fence.origin != station.station_origin {
            return Err(());
        }
        let mut tx = self.0.begin().await.map_err(|_| ())?;
        fence.lock(&mut tx).await.map_err(|_| ())?;
        // Feed commits lock their credential row before the cross-credential
        // binding lock. Keep a concurrent denial ordered with application too.
        let current: Option<bool> = sqlx::query_scalar(
            "SELECT checkpoint::jsonb->'denied' = 'false'::jsonb AND
                    jsonb_typeof(checkpoint::jsonb->'portal_snapshot'->'pending_releases') = 'array'
             FROM station_integration_policy WHERE binding=$1 FOR SHARE",
        )
        .bind(station.storage_key()?)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|_| ())?
        .flatten();
        if current != Some(true) {
            return Ok(0);
        }
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 29))")
            .bind(station.report_control_binding())
            .execute(&mut *tx)
            .await
            .map_err(|_| ())?;
        let applied = sqlx::query(include_str!("integration_apply_binding_releases.sql"))
            .bind(&station.issuer)
            .bind(&station.portal_origin)
            .bind(&station.station_origin)
            .bind(station.storage_key()?)
            .execute(&mut *tx)
            .await
            .map_err(|_| ())?;
        tx.commit().await.map_err(|_| ())?;
        Ok(applied.rows_affected())
    }
}
