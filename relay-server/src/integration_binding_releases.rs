//! Apply a Portal release to the binding the Station last recorded.
use super::{FeedBinding, PolicyStore};
use crate::integration_checkpoint::PortalCheckpoint;
use crate::remote_api::recovery::delegated_recovery::Binding as RecoveryFence;

impl PolicyStore {
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
