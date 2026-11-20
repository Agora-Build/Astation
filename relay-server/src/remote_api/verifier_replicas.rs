//! Authenticated deployment reports, not the relay's fail-open presence cache.
use super::{delegated_recovery::Binding, Root, MAX_STATE};
use atem_client::{
    canonical::StrictValue, membership::VerifierInventory, station_route::normalize_relay,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool};
use std::{collections::BTreeSet, sync::Arc, time::Duration};
use tokio::{sync::Mutex, time::Instant};
use uuid::Uuid;

const MAX_REPLICAS: usize = 64;
const LEASE_MS: i64 = 30_000;
const MAX_INTEGER: i64 = 9_007_199_254_740_991;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Configuration {
    pub generation: i64,
    pub replica: String,
    pub replicas: Vec<String>,
}

impl Configuration {
    pub fn parse(json: &str) -> Result<Self, &'static str> {
        let value = StrictValue::parse(json.as_bytes(), 16_384)
            .map_err(|_| "invalid verifier configuration")?;
        let config: Self = serde_json::from_value(value.value().clone())
            .map_err(|_| "invalid verifier configuration")?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), &'static str> {
        let ids: BTreeSet<_> = self.replicas.iter().collect();
        if !(1..=MAX_INTEGER).contains(&self.generation)
            || self.replicas.is_empty()
            || self.replicas.len() > MAX_REPLICAS
            || ids.len() != self.replicas.len()
            || !self.replicas.windows(2).all(|pair| pair[0] < pair[1])
            || !self.replicas.iter().all(|id| valid_id(id))
            || !ids.contains(&self.replica)
        {
            return Err("invalid verifier configuration");
        }
        Ok(())
    }
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
}

fn unavailable() -> sqlx::Error {
    sqlx::Error::Protocol("Station verifier inventory is unavailable or changed".into())
}

#[derive(Clone)]
pub(crate) struct ReplicaRegistry {
    pool: PgPool,
    origin: String,
    configuration: Configuration,
    recovery: Binding,
    connection: String,
    connection_generation: i64,
    valid_before: Arc<Mutex<Instant>>,
}

#[derive(sqlx::FromRow)]
struct SavedReport {
    replica_id: String,
    roster_generation: i64,
    recovery_generation: i64,
    connection: String,
    connection_generation: i64,
    inventory: Option<Value>,
    highest_inventory: Value,
    ms_left: i64,
}

impl ReplicaRegistry {
    /// Keep both rows locked through the caller's actual verifier/write boundary.
    /// An expired process cannot serve while a replacement occupies its slot.
    pub async fn lock_live(&self, connection: &mut PgConnection) -> Result<(), sqlx::Error> {
        if Instant::now() >= *self.valid_before.lock().await {
            return Err(unavailable());
        }
        let roster: Option<i64> = sqlx::query_scalar(
            "SELECT generation FROM station_verifier_rosters WHERE origin=$1 AND generation=$2 AND replicas=$3 FOR SHARE")
            .bind(&self.origin).bind(self.configuration.generation).bind(json!(self.configuration.replicas))
            .fetch_optional(&mut *connection).await?;
        if roster.is_none() {
            return Err(unavailable());
        }
        let live: Option<i32> = sqlx::query_scalar(
            "SELECT 1 FROM station_verifier_replicas WHERE origin=$1 AND replica_id=$2 AND connection=$3 AND connection_generation=$4 AND roster_generation=$5 AND recovery_generation=$6 AND expires_at>clock_timestamp() AND expires_at<=clock_timestamp()+interval '30 seconds' AND inventory=$7 FOR SHARE")
            .bind(&self.origin).bind(&self.configuration.replica).bind(&self.connection).bind(self.connection_generation)
            .bind(self.configuration.generation).bind(self.recovery.generation).bind(VerifierInventory::ours().to_json())
            .fetch_optional(connection).await?;
        if live.is_none() || Instant::now() >= *self.valid_before.lock().await {
            return Err(unavailable());
        }
        Ok(())
    }

    /// Deployment configuration is explicit. A count or a list of live sockets
    /// cannot establish which unavailable replicas must still be checked.
    pub async fn register(
        pool: PgPool,
        recovery: Binding,
        configuration: Configuration,
    ) -> Result<Self, sqlx::Error> {
        let origin = &recovery.origin;
        if normalize_relay(origin).as_deref() != Ok(origin.as_str())
            || configuration.validate().is_err()
        {
            return Err(unavailable());
        }
        let started = Instant::now();
        let mut tx = pool.begin().await?;
        sqlx::query("SET LOCAL statement_timeout='5s'")
            .execute(&mut *tx)
            .await?;
        recovery.lock(&mut tx).await?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 1))")
            .bind(origin)
            .execute(&mut *tx)
            .await?;
        let saved: Option<(i64, Value)> = sqlx::query_as(
            "SELECT generation,replicas FROM station_verifier_rosters WHERE origin=$1 FOR UPDATE",
        )
        .bind(origin)
        .fetch_optional(&mut *tx)
        .await?;
        let replicas = json!(configuration.replicas);
        if let Some((generation, previous)) = saved {
            if generation > configuration.generation
                || (generation == configuration.generation && previous != replicas)
            {
                return Err(unavailable());
            }
        }
        sqlx::query("INSERT INTO station_verifier_rosters(origin,generation,replicas) VALUES($1,$2,$3) ON CONFLICT(origin) DO UPDATE SET generation=EXCLUDED.generation,replicas=EXCLUDED.replicas")
            .bind(origin).bind(configuration.generation).bind(replicas).execute(&mut *tx).await?;
        let previous: Option<SavedReport> = sqlx::query_as(
            "SELECT replica_id,roster_generation,recovery_generation,connection,connection_generation,inventory,highest_inventory,floor(extract(epoch FROM expires_at-clock_timestamp())*1000)::bigint AS ms_left FROM station_verifier_replicas WHERE origin=$1 AND replica_id=$2 FOR UPDATE")
            .bind(origin).bind(&configuration.replica).fetch_optional(&mut *tx).await?;
        // A rolling replacement must first drain its old slot. Do not turn a
        // second process into proof that the first process upgraded or stopped.
        if previous
            .as_ref()
            .is_some_and(|row| row.recovery_generation == recovery.generation && row.ms_left > 0)
        {
            return Err(unavailable());
        }
        let connection_generation = previous
            .as_ref()
            .map_or(Some(1), |row| row.connection_generation.checked_add(1))
            .filter(|value| *value <= MAX_INTEGER)
            .ok_or_else(unavailable)?;
        let inventory = VerifierInventory::ours();
        let previous_highest = previous
            .as_ref()
            .map(|row| VerifierInventory::from_json(&row.highest_inventory))
            .transpose()
            .map_err(|_| unavailable())?;
        let supported = previous_highest
            .as_ref()
            .is_none_or(|highest| widens(&inventory, highest));
        let highest = if supported {
            inventory.to_json()
        } else {
            previous.unwrap().highest_inventory
        };
        let connection = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO station_verifier_replicas(origin,replica_id,roster_generation,connection,connection_generation,inventory,highest_inventory,expires_at,recovery_generation) VALUES($1,$2,$3,$4,$5,$6,$7,clock_timestamp()+$8::bigint*interval '1 millisecond',$9) ON CONFLICT(origin,replica_id) DO UPDATE SET roster_generation=EXCLUDED.roster_generation,recovery_generation=EXCLUDED.recovery_generation,connection=EXCLUDED.connection,connection_generation=EXCLUDED.connection_generation,inventory=EXCLUDED.inventory,highest_inventory=EXCLUDED.highest_inventory,expires_at=EXCLUDED.expires_at")
            .bind(origin).bind(&configuration.replica).bind(configuration.generation).bind(&connection)
            .bind(connection_generation).bind(supported.then(|| inventory.to_json())).bind(highest).bind(LEASE_MS)
            .bind(recovery.generation)
            .execute(&mut *tx).await?;
        tx.commit().await?;
        if !supported {
            return Err(unavailable());
        }
        let valid_before = started + Duration::from_millis(LEASE_MS as u64);
        if Instant::now() >= valid_before {
            return Err(unavailable());
        }
        Ok(Self {
            pool,
            origin: origin.clone(),
            recovery,
            configuration,
            connection,
            connection_generation,
            valid_before: Arc::new(Mutex::new(valid_before)),
        })
    }

    /// Expiration cannot be renewed, even by a process with a saved connection
    /// ID. It must reconnect and acquire a fresh, increasing generation.
    pub async fn refresh(&self) -> Result<(), sqlx::Error> {
        let started = Instant::now();
        if started >= *self.valid_before.lock().await {
            return Err(unavailable());
        }
        let mut tx = self.pool.begin().await?;
        sqlx::query("SET LOCAL statement_timeout='5s'")
            .execute(&mut *tx)
            .await?;
        self.recovery.lock(&mut tx).await?;
        let updated = sqlx::query("UPDATE station_verifier_replicas AS r SET expires_at=clock_timestamp()+$6::bigint*interval '1 millisecond' FROM station_verifier_rosters AS roster WHERE r.origin=$1 AND r.replica_id=$2 AND r.connection=$3 AND r.connection_generation=$4 AND r.roster_generation=$5 AND r.expires_at>clock_timestamp() AND r.expires_at<=clock_timestamp()+$6::bigint*interval '1 millisecond' AND r.inventory IS NOT NULL AND roster.origin=r.origin AND roster.generation=r.roster_generation AND roster.replicas=$7 AND r.recovery_generation=$8")
            .bind(&self.origin).bind(&self.configuration.replica).bind(&self.connection).bind(self.connection_generation)
            .bind(self.configuration.generation).bind(LEASE_MS).bind(json!(self.configuration.replicas))
            .bind(self.recovery.generation).execute(&mut *tx).await?;
        if updated.rows_affected() != 1 {
            return Err(unavailable());
        }
        let next = started + Duration::from_millis(LEASE_MS as u64);
        if Instant::now() >= *self.valid_before.lock().await || Instant::now() >= next {
            return Err(unavailable());
        }
        tx.commit().await?;
        let mut valid_before = self.valid_before.lock().await;
        if Instant::now() >= *valid_before {
            return Err(unavailable());
        }
        *valid_before = (*valid_before).max(next);
        Ok(())
    }

    pub async fn withdraw(&self) -> Result<(), sqlx::Error> {
        *self.valid_before.lock().await = Instant::now();
        sqlx::query("UPDATE station_verifier_replicas SET inventory=NULL,expires_at=clock_timestamp() WHERE origin=$1 AND replica_id=$2 AND connection=$3 AND connection_generation=$4")
            .bind(&self.origin).bind(&self.configuration.replica).bind(&self.connection).bind(self.connection_generation)
            .execute(&self.pool).await?;
        Ok(())
    }

    pub fn spawn_refresh(&self) -> tokio::task::JoinHandle<()> {
        let registry = self.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                if registry.refresh().await.is_err() {
                    tracing::error!(
                        "Station verifier report lost its authenticated deployment lease"
                    );
                    return;
                }
            }
        })
    }

    #[cfg(test)]
    pub async fn snapshot(&self) -> Result<Value, sqlx::Error> {
        self.snapshot_inner(None, None)
            .await?
            .ok_or_else(unavailable)
    }

    pub async fn snapshot_for(
        &self,
        genesis: &str,
        owner: &str,
    ) -> Result<Option<Value>, sqlx::Error> {
        self.snapshot_inner(Some((genesis, owner)), None).await
    }

    pub async fn managed_services_for(
        &self,
        genesis: &str,
        owner: &str,
        runtime: &crate::station_integrations::StationIntegrations,
        ids: &[String],
        expected: &atem_client::membership::Head,
    ) -> Result<Option<Value>, sqlx::Error> {
        if ids.is_empty()
            || ids.len() > 64
            || !ids.windows(2).all(|pair| pair[0] < pair[1])
            || ids.iter().any(|id| {
                id.is_empty() || id.len() > 128 || !id.bytes().all(|b| b.is_ascii_graphic())
            })
        {
            return Err(unavailable());
        }
        self.snapshot_inner(Some((genesis, owner)), Some((runtime, ids, expected)))
            .await
    }

    async fn snapshot_inner(
        &self,
        account: Option<(&str, &str)>,
        services: Option<(
            &crate::station_integrations::StationIntegrations,
            &[String],
            &atem_client::membership::Head,
        )>,
    ) -> Result<Option<Value>, sqlx::Error> {
        if Instant::now() >= *self.valid_before.lock().await {
            return Err(unavailable());
        }
        let mut tx = self.pool.begin().await?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            .execute(&mut *tx)
            .await?;
        sqlx::query("SET LOCAL statement_timeout='5s'")
            .execute(&mut *tx)
            .await?;
        self.recovery.lock(&mut tx).await?;
        self.lock_live(&mut tx).await?;
        let log = if let Some((genesis, owner)) = account {
            let saved: Option<Option<Value>> = sqlx::query_scalar(
                "SELECT CASE WHEN octet_length(state::text)<=$3 THEN state END FROM remote_recovery_roots WHERE genesis_hash=$1 AND account_subject=$2 FOR SHARE")
                .bind(genesis).bind(owner).bind(MAX_STATE as i64).fetch_optional(&mut *tx).await?;
            let Some(saved) = saved else {
                return Ok(None);
            };
            let root: Root = serde_json::from_value(saved.ok_or_else(unavailable)?)
                .map_err(|_| unavailable())?;
            let genesis = atem_client::Hash32::from_hex(genesis).map_err(|_| unavailable())?;
            let mut log = atem_client::membership::Membership::from_stored(
                &root.account,
                &genesis,
                &root.membership,
            )
            .map_err(|_| unavailable())?;
            log.advance(&super::now());
            if log.frozen().is_some() {
                return Err(unavailable());
            }
            Some(log)
        } else {
            None
        };
        let (generation, replicas): (i64, Value) = sqlx::query_as(
            "SELECT generation,replicas FROM station_verifier_rosters WHERE origin=$1",
        )
        .bind(&self.origin)
        .fetch_one(&mut *tx)
        .await?;
        if generation != self.configuration.generation
            || replicas != json!(self.configuration.replicas)
        {
            return Err(unavailable());
        }
        let reports: Vec<SavedReport> = sqlx::query_as(
            "SELECT replica_id,roster_generation,recovery_generation,connection,connection_generation,inventory,highest_inventory,floor(extract(epoch FROM expires_at-clock_timestamp())*1000)::bigint AS ms_left FROM station_verifier_replicas WHERE origin=$1 AND replica_id=ANY($2) LIMIT 64")
            .bind(&self.origin).bind(&self.configuration.replicas).fetch_all(&mut *tx).await?;
        if !reports.iter().any(|row| {
            row.replica_id == self.configuration.replica
                && row.connection == self.connection
                && row.connection_generation == self.connection_generation
                && row.roster_generation == generation
                && row.recovery_generation == self.recovery.generation
                && row.inventory.is_some()
                && (1..=LEASE_MS).contains(&row.ms_left)
        }) {
            return Err(unavailable());
        }
        let mut members = Vec::with_capacity(self.configuration.replicas.len());
        for id in &self.configuration.replicas {
            let mut member = json!({"id":id});
            if let Some(row) = reports.iter().find(|row| &row.replica_id == id) {
                member["connection_generation"] = json!(row.connection_generation);
                if row.roster_generation == generation
                    && row.recovery_generation == self.recovery.generation
                    && (1..=LEASE_MS).contains(&row.ms_left)
                {
                    if let Some(value) = &row.inventory {
                        let inventory =
                            VerifierInventory::from_json(value).map_err(|_| unavailable())?;
                        let highest = VerifierInventory::from_json(&row.highest_inventory)
                            .map_err(|_| unavailable())?;
                        if !widens(&inventory, &highest) {
                            return Err(unavailable());
                        }
                        member["verifier"] = inventory.to_json();
                        member["authorization_ms_left"] = json!(row.ms_left);
                    }
                }
            }
            members.push(member);
        }
        let service_members = if let Some((runtime, ids, expected)) = services {
            let log = log.as_ref().ok_or_else(unavailable)?;
            if log.head() != *expected {
                return Err(unavailable());
            }
            Some(
                runtime
                    .managed_verifier_members(
                        &mut tx,
                        &self.origin,
                        account.ok_or_else(unavailable)?.1,
                        log,
                        ids,
                    )
                    .await?,
            )
        } else {
            None
        };
        tx.commit().await?;
        if Instant::now() >= *self.valid_before.lock().await {
            return Err(unavailable());
        }
        let mut result =
            json!({"origin":self.origin,"roster_generation":generation,"replicas":members});
        if let Some(log) = log {
            result["account_id"] = json!(log.account_id());
            result["genesis_hash"] = json!(log.genesis_hash().to_hex());
            result["head"] = log.head().to_json();
        }
        if let Some(services) = service_members {
            result["services"] = json!(services);
        }
        Ok(Some(result))
    }
}

fn widens(new: &VerifierInventory, old: &VerifierInventory) -> bool {
    new.version() >= old.version()
        && old
            .actions()
            .iter()
            .all(|action| new.actions().contains(action))
        && (new.version() != old.version() || new == old)
}

#[cfg(test)]
#[path = "verifier_replicas/tests.rs"]
mod tests;
