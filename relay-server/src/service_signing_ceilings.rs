//! Service-key reservations commit independently of the Station recovery database.
use sqlx::{
    postgres::{PgConnectOptions, PgPoolOptions},
    PgPool,
};
use std::time::Duration;

pub(crate) struct SigningCeilings(PgPool);

#[derive(Debug, serde::Serialize, sqlx::FromRow)]
pub(crate) struct Reservation {
    pub service_id: String,
    pub key_hash: String,
    pub highest_ms: i64,
}

impl SigningCeilings {
    pub(crate) async fn from_env(primary: &PgPool) -> Result<Option<Self>, ()> {
        match std::env::var("STATION_SIGNING_CEILING_DATABASE_URL") {
            Ok(url) => Self::connect(primary, url.parse().map_err(|_| ())?)
                .await
                .map(Some),
            Err(std::env::VarError::NotPresent) => Ok(None),
            Err(_) => Err(()),
        }
    }

    pub(crate) async fn connect(primary: &PgPool, options: PgConnectOptions) -> Result<Self, ()> {
        const CLUSTER: &str = "SELECT system_identifier::text FROM pg_catalog.pg_control_system()";
        let primary_id: String = sqlx::query_scalar(CLUSTER)
            .fetch_one(primary)
            .await
            .map_err(|_| ())?;
        let pool = PgPoolOptions::new()
            .max_connections(2)
            .acquire_timeout(Duration::from_secs(3))
            .after_connect(move |connection, _| {
                let primary_id = primary_id.clone();
                Box::pin(async move {
                    sqlx::query("SET statement_timeout TO '3s'")
                        .execute(&mut *connection)
                        .await?;
                    sqlx::query("SET synchronous_commit TO on")
                        .execute(&mut *connection)
                        .await?;
                    let id: String = sqlx::query_scalar(CLUSTER)
                        .fetch_one(&mut *connection)
                        .await?;
                    let durable: bool = sqlx::query_scalar(
                        "SELECT current_setting('fsync')::boolean AND current_setting('full_page_writes')::boolean
                                AND NOT pg_is_in_recovery() AND EXISTS (SELECT 1 FROM pg_catalog.pg_class
                                WHERE oid=to_regclass('station_service_signing_ceilings') AND relpersistence='p')",
                    )
                    .fetch_one(&mut *connection)
                    .await?;
                    if id == primary_id || !durable {
                        return Err(sqlx::Error::Protocol(
                            "expected a separate writable durable signing cluster".into(),
                        ));
                    }
                    Ok(())
                })
            })
            .connect_lazy_with(options);
        Ok(Self(pool))
    }

    pub(crate) async fn check_access(&self) -> Result<(), ()> {
        let writable: bool = sqlx::query_scalar("SELECT has_table_privilege('station_service_signing_ceilings', 'SELECT')
            AND has_column_privilege('station_service_signing_ceilings', 'highest_ms', 'UPDATE')
            AND (SELECT bool_and(has_column_privilege('station_service_signing_ceilings', c, 'INSERT'))
                 FROM unnest(ARRAY['account_id','genesis_hash','service_id','key_hash']) AS c)")
            .fetch_one(&self.0).await.map_err(|_| ())?;
        writable.then_some(()).ok_or(())
    }

    pub(crate) async fn has_reservations(&self) -> Result<bool, sqlx::Error> {
        // Key provisioning can register an unused key before delegated work starts.
        sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM station_service_signing_ceilings WHERE highest_ms > 0)")
            .fetch_one(&self.0)
            .await
    }

    #[cfg(test)]
    pub(crate) async fn fixture(pool: PgPool) -> Self {
        sqlx::raw_sql(include_str!("../signing-store/schema.sql"))
            .execute(&pool)
            .await
            .unwrap();
        Self(pool)
    }

    // Only the transaction that generated a new key can register it. Loading
    // a restored or legacy key must never initialize missing history to zero.
    pub(crate) async fn register_new_key(
        &self,
        account: &str,
        genesis: &str,
        service: &str,
        key: &str,
    ) -> Result<(), ()> {
        sqlx::query("INSERT INTO station_service_signing_ceilings(account_id,genesis_hash,service_id,key_hash) VALUES($1,$2,$3,$4)")
            .bind(account).bind(genesis).bind(service).bind(key).execute(&self.0).await.map_err(|_| ())?;
        Ok(())
    }

    pub(crate) async fn reserve(
        &self,
        account: &str,
        genesis: &str,
        service: &str,
        key: &str,
        previously_signed: u64,
        range: std::ops::RangeInclusive<u64>,
    ) -> Result<(), ()> {
        let (first, last) = range.into_inner();
        if first <= previously_signed
            || first > last
            || last > atem_client::canonical::MAX_SAFE_INTEGER
        {
            return Err(());
        }
        // An uncertain commit burns the range. Only a successful reply permits signing.
        let result = sqlx::query("UPDATE station_service_signing_ceilings SET highest_ms=$6
            WHERE account_id=$1 AND genesis_hash=$2 AND service_id=$3 AND key_hash=$4 AND highest_ms<$5 AND highest_ms >= $7")
            .bind(account).bind(genesis).bind(service).bind(key).bind(first as i64).bind(last as i64).bind(previously_signed as i64)
            .execute(&self.0).await.map_err(|_| ())?;
        if result.rows_affected() != 1 {
            return Err(());
        }
        Ok(())
    }

    pub(crate) fn recovery_evidence(
        reservations: &[Reservation],
        observed_reservations: &[Reservation],
        plan: &serde_json::Value,
    ) -> Result<serde_json::Value, ()> {
        use std::collections::{BTreeMap, BTreeSet};
        let ceilings: BTreeMap<_, _> = reservations
            .iter()
            .map(|row| {
                (
                    (row.service_id.as_str(), row.key_hash.as_str()),
                    row.highest_ms,
                )
            })
            .collect();
        let shortfalls: Vec<_> = observed_reservations.iter().filter(|row| {
            ceilings.get(&(row.service_id.as_str(), row.key_hash.as_str()))
                .is_none_or(|current| *current < row.highest_ms)
        }).collect();
        let mut missing = BTreeSet::new();
        let mut uncovered = BTreeMap::<&str, u64>::new();
        for observed in plan["known_history"]["observed_service_keys"]
            .as_array()
            .ok_or(())?
        {
            let service = observed["service_id"].as_str().ok_or(())?;
            let key = observed["key_fingerprint"].as_str().ok_or(())?;
            let ceiling = ceilings.get(&(service, key));
            if ceiling.is_none() {
                missing.insert((service, key));
            }
            let signature = observed.get("highest_signed_ms").ok_or(())?;
            if !signature.is_null() {
                let time = signature.as_u64().ok_or(())?;
                if ceiling.is_none_or(|value| *value <= 0 || (*value as u64) < time) {
                    let floor = uncovered.entry(service).or_default();
                    *floor = (*floor).max(time);
                }
            }
        }
        // Preserve even registrations absent from restored membership. The
        // publisher must reread these observations under the recovery fence.
        Ok(
            serde_json::json!({"plan_id": plan["plan_id"], "source_hash": plan["source_hash"],
            "reconstruction_hash": plan["reconstruction_hash"], "reservations": reservations,
            "reservation_shortfalls": shortfalls,
            "unregistered_membership_keys": missing, "uncovered_service_signatures": uncovered}),
        )
    }

    pub(crate) async fn reservations(
        &self,
        account: &str,
        genesis: &str,
    ) -> Result<Vec<Reservation>, ()> {
        // A truncated inventory would conceal principals missing from a restored root.
        let rows = sqlx::query_as(
            "SELECT service_id,key_hash,highest_ms FROM station_service_signing_ceilings
            WHERE account_id=$1 AND genesis_hash=$2 ORDER BY service_id,key_hash LIMIT 4097",
        )
        .bind(account)
        .bind(genesis)
        .fetch_all(&self.0)
        .await
        .map_err(|_| ())?;
        if rows.len() > 4096 {
            return Err(());
        }
        Ok(rows)
    }
}
