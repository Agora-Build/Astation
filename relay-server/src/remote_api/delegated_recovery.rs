//! Operational rollback fence. The configured generation must live outside the
//! restored backup; neither a feed UUID nor wall-clock time proves later history.
use super::RecoveryStore;
use serde::Serialize;
use sqlx::{PgConnection, PgPool};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Binding {
    pub origin: String,
    pub generation: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, sqlx::FromRow)]
pub(crate) struct Status {
    pub generation: i64,
    pub ready: bool,
    pub reason: String,
}

pub(crate) fn generation(value: &str) -> Result<i64, &'static str> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) || value.starts_with('0') {
        return Err("recovery generation must be a canonical positive integer");
    }
    value
        .parse::<i64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or("recovery generation is outside the supported range")
}

impl Binding {
    pub fn new(origin: &str, generation: i64) -> Result<Self, &'static str> {
        if generation <= 0
            || atem_client::station_route::normalize_relay(origin).as_deref() != Ok(origin)
        {
            return Err("normalized PUBLIC_BASE_URL and positive recovery generation are required");
        }
        Ok(Self {
            origin: origin.into(),
            generation,
        })
    }

    /// Initialization is safe only before any delegated history exists. A new
    /// generation can close a fence, but cannot reopen it or recreate lost stops.
    pub async fn initialize(&self, pool: &PgPool, fence: bool) -> Result<Status, sqlx::Error> {
        let mut tx = pool.begin().await?;
        sqlx::query(
            "SELECT pg_advisory_xact_lock(hashtextextended('station-delegated-recovery', 0))",
        )
        .execute(&mut *tx)
        .await?;
        let saved: Option<Status> = sqlx::query_as(
            "SELECT generation,ready,reason FROM station_delegated_recovery WHERE origin=$1 FOR UPDATE")
            .bind(&self.origin).fetch_optional(&mut *tx).await?;
        let next = match saved {
            None => {
                let history: bool = sqlx::query_scalar(
                    "SELECT EXISTS(SELECT 1 FROM remote_recovery_roots WHERE state->'delegated' IS NOT NULL AND state->'delegated' <> '{}'::jsonb)")
                    .fetch_one(&mut *tx).await?;
                Status {
                    generation: self.generation,
                    ready: self.generation == 1 && !history && !fence,
                    reason: if fence {
                        "operator_fenced"
                    } else if history || self.generation != 1 {
                        "history_missing"
                    } else {
                        "initialized"
                    }
                    .into(),
                }
            }
            Some(mut saved) => {
                // A stale process/configuration cannot roll the generation back
                // or turn an already closed fence into a ready deployment.
                if self.generation > saved.generation {
                    saved.generation = self.generation;
                    saved.ready = false;
                    saved.reason = "generation_changed".into();
                }
                if fence && self.generation >= saved.generation {
                    saved.ready = false;
                    saved.reason = "operator_fenced".into();
                }
                saved
            }
        };
        if fence && next.generation != self.generation {
            return Err(sqlx::Error::Protocol(
                "a stale recovery generation cannot fence a newer deployment".into(),
            ));
        }
        sqlx::query("INSERT INTO station_delegated_recovery(origin,generation,ready,reason) VALUES ($1,$2,$3,$4) ON CONFLICT(origin) DO UPDATE SET generation=EXCLUDED.generation,ready=EXCLUDED.ready,reason=EXCLUDED.reason")
            .bind(&self.origin).bind(next.generation).bind(next.ready).bind(&next.reason)
            .execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(next)
    }

    /// Hold the shared row lock through actual socket writes/signing/HTTP
    /// delivery. A concurrent fence waits, and no later operation can pass it.
    pub async fn lock(&self, connection: &mut PgConnection) -> Result<(), sqlx::Error> {
        let status: Option<Status> = sqlx::query_as(
            "SELECT generation,ready,reason FROM station_delegated_recovery WHERE origin=$1 FOR SHARE")
            .bind(&self.origin).fetch_optional(connection).await?;
        if status.is_some_and(|s| s.ready && s.generation == self.generation) {
            Ok(())
        } else {
            Err(sqlx::Error::Protocol(
                "delegated recovery fence is closed".into(),
            ))
        }
    }
}

pub(crate) async fn inspect(pool: &PgPool, origin: &str) -> Result<Option<Status>, sqlx::Error> {
    sqlx::query_as("SELECT generation,ready,reason FROM station_delegated_recovery WHERE origin=$1")
        .bind(origin)
        .fetch_optional(pool)
        .await
}

impl RecoveryStore {
    pub(crate) async fn lock_delegated_recovery(
        &self,
        connection: &mut PgConnection,
    ) -> Result<(), sqlx::Error> {
        if let Some(binding) = self.delegated_recovery.get() {
            if !self.delegated_enabled() {
                return Err(sqlx::Error::Protocol(
                    "delegated recovery initialization has not completed".into(),
                ));
            }
            binding.lock(connection).await
        } else if self.delegated_enabled() {
            Err(sqlx::Error::Protocol(
                "delegated recovery generation is not configured".into(),
            ))
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_generation_is_explicit_positive_and_canonical() {
        for value in [
            "",
            "0",
            "-1",
            "+1",
            "01",
            " 1",
            "1 ",
            "1.0",
            "9223372036854775808",
        ] {
            assert!(generation(value).is_err(), "{value:?}");
        }
        assert_eq!(generation("1"), Ok(1));
        assert_eq!(generation("9223372036854775807"), Ok(i64::MAX));
    }
}
