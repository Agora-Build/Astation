//! Push addresses are delivery metadata, never proof of membership or control.
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use tokio::sync::Mutex;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum PushPlatform {
    ApnsSandbox,
    ApnsProduction,
    Fcm,
}

impl PushPlatform {
    pub fn name(self) -> &'static str {
        match self {
            Self::ApnsSandbox => "apns_sandbox",
            Self::ApnsProduction => "apns_production",
            Self::Fcm => "fcm",
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushRegistration {
    pub platform: PushPlatform,
    pub token: String,
}

impl PushRegistration {
    fn normalized(mut self) -> Self {
        if self.platform != PushPlatform::Fcm {
            self.token.make_ascii_lowercase();
        }
        self
    }

    pub fn valid(&self) -> bool {
        match self.platform {
            PushPlatform::ApnsSandbox | PushPlatform::ApnsProduction => {
                (32..=512).contains(&self.token.len())
                    && self.token.len() % 2 == 0
                    && self.token.bytes().all(|byte| byte.is_ascii_hexdigit())
            }
            PushPlatform::Fcm => {
                (32..=4096).contains(&self.token.len())
                    && self.token.bytes().all(|byte| byte.is_ascii_graphic())
            }
        }
    }
}

// Deliberately no Debug: device tokens must not appear in diagnostic output.
#[derive(Clone)]
pub struct RegisteredPushToken {
    pub device_id: String,
    pub registration: PushRegistration,
    pub generation: String,
}

#[derive(Debug)]
pub struct PushStoreError;

#[async_trait]
pub trait PushTokenStore: Send + Sync {
    async fn register(
        &self,
        device: &str,
        registration: PushRegistration,
    ) -> Result<(), PushStoreError>;
    async fn unregister(&self, device: &str, platform: PushPlatform) -> Result<(), PushStoreError>;
    async fn for_devices(
        &self,
        devices: &[String],
    ) -> Result<Vec<RegisteredPushToken>, PushStoreError>;
    async fn invalidate(&self, token: &RegisteredPushToken) -> Result<(), PushStoreError>;
}

#[derive(Default)]
pub struct InMemoryPushTokenStore {
    tokens: Mutex<HashMap<(String, PushPlatform), RegisteredPushToken>>,
}

#[async_trait]
impl PushTokenStore for InMemoryPushTokenStore {
    async fn register(
        &self,
        device: &str,
        registration: PushRegistration,
    ) -> Result<(), PushStoreError> {
        let registration = registration.normalized();
        if !registration.valid() {
            return Err(PushStoreError);
        }
        let mut tokens = self.tokens.lock().await;
        tokens.retain(|_, existing| {
            existing.registration.platform != registration.platform
                || existing.registration.token != registration.token
                || existing.device_id == device
        });
        let key = (device.to_string(), registration.platform);
        let generation = tokens
            .get(&key)
            .filter(|existing| existing.registration.token == registration.token)
            .map(|existing| existing.generation.clone())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        tokens.insert(
            key,
            RegisteredPushToken {
                device_id: device.into(),
                registration,
                generation,
            },
        );
        Ok(())
    }

    async fn unregister(&self, device: &str, platform: PushPlatform) -> Result<(), PushStoreError> {
        self.tokens.lock().await.remove(&(device.into(), platform));
        Ok(())
    }

    async fn for_devices(
        &self,
        devices: &[String],
    ) -> Result<Vec<RegisteredPushToken>, PushStoreError> {
        if devices.len() > 1024 {
            return Err(PushStoreError);
        }
        Ok(self
            .tokens
            .lock()
            .await
            .values()
            .filter(|token| devices.contains(&token.device_id))
            .cloned()
            .collect())
    }

    async fn invalidate(&self, token: &RegisteredPushToken) -> Result<(), PushStoreError> {
        let mut tokens = self.tokens.lock().await;
        let key = (token.device_id.clone(), token.registration.platform);
        if tokens
            .get(&key)
            .is_some_and(|current| current.generation == token.generation)
        {
            tokens.remove(&key);
        }
        Ok(())
    }
}

pub struct PgPushTokenStore {
    pool: sqlx::PgPool,
}

impl PgPushTokenStore {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl PushTokenStore for PgPushTokenStore {
    async fn register(
        &self,
        device: &str,
        registration: PushRegistration,
    ) -> Result<(), PushStoreError> {
        let registration = registration.normalized();
        if !registration.valid() {
            return Err(PushStoreError);
        }
        let mut tx = self.pool.begin().await.map_err(|_| PushStoreError)?;
        // Serialize a token's reassignment across replicas without locking unrelated devices.
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!(
                "{}:{}",
                registration.platform.name(),
                registration.token
            ))
            .execute(&mut *tx)
            .await
            .map_err(|_| PushStoreError)?;
        sqlx::query(
            "DELETE FROM device_push_tokens WHERE platform = $1 AND token = $2 AND device_id <> $3",
        )
        .bind(registration.platform.name())
        .bind(&registration.token)
        .bind(device)
        .execute(&mut *tx)
        .await
        .map_err(|_| PushStoreError)?;
        sqlx::query("INSERT INTO device_push_tokens (device_id, platform, token, generation) VALUES ($1, $2, $3, $4) \
            ON CONFLICT (device_id, platform) DO UPDATE SET token = EXCLUDED.token, \
            generation = CASE WHEN device_push_tokens.token = EXCLUDED.token THEN device_push_tokens.generation ELSE EXCLUDED.generation END, \
            updated_at = now()")
            .bind(device).bind(registration.platform.name()).bind(&registration.token).bind(uuid::Uuid::new_v4().to_string())
            .execute(&mut *tx).await.map_err(|_| PushStoreError)?;
        tx.commit().await.map_err(|_| PushStoreError)
    }

    async fn unregister(&self, device: &str, platform: PushPlatform) -> Result<(), PushStoreError> {
        sqlx::query("DELETE FROM device_push_tokens WHERE device_id = $1 AND platform = $2")
            .bind(device)
            .bind(platform.name())
            .execute(&self.pool)
            .await
            .map_err(|_| PushStoreError)?;
        Ok(())
    }

    async fn for_devices(
        &self,
        devices: &[String],
    ) -> Result<Vec<RegisteredPushToken>, PushStoreError> {
        if devices.len() > 1024 {
            return Err(PushStoreError);
        }
        let rows: Vec<(String, String, String, String)> = sqlx::query_as(
            "SELECT device_id, platform, token, generation FROM device_push_tokens WHERE device_id = ANY($1)")
            .bind(devices).fetch_all(&self.pool).await.map_err(|_| PushStoreError)?;
        rows.into_iter()
            .map(|(device_id, platform, token, generation)| {
                let platform = serde_json::from_value(serde_json::Value::String(platform))
                    .map_err(|_| PushStoreError)?;
                Ok(RegisteredPushToken {
                    device_id,
                    registration: PushRegistration { platform, token },
                    generation,
                })
            })
            .collect()
    }

    async fn invalidate(&self, token: &RegisteredPushToken) -> Result<(), PushStoreError> {
        sqlx::query("DELETE FROM device_push_tokens WHERE device_id = $1 AND platform = $2 AND generation = $3")
            .bind(&token.device_id).bind(token.registration.platform.name()).bind(&token.generation)
            .execute(&self.pool).await.map_err(|_| PushStoreError)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn registration(value: char) -> PushRegistration {
        PushRegistration {
            platform: PushPlatform::ApnsSandbox,
            token: value.to_string().repeat(64),
        }
    }

    #[tokio::test]
    async fn rotation_and_old_provider_response_cannot_remove_a_new_token() {
        let store = InMemoryPushTokenStore::default();
        store.register("mac", registration('A')).await.unwrap();
        let old = store.for_devices(&["mac".into()]).await.unwrap().remove(0);
        store.register("mac", registration('b')).await.unwrap();
        store.invalidate(&old).await.unwrap();
        let current = store.for_devices(&["mac".into()]).await.unwrap().remove(0);
        assert_eq!(current.registration.token, "b".repeat(64));
        store.invalidate(&current).await.unwrap();
        assert!(store.for_devices(&["mac".into()]).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn idempotent_registration_is_scoped_and_token_reassignment_is_unique() {
        let store = InMemoryPushTokenStore::default();
        store.register("mac", registration('A')).await.unwrap();
        let old = store.for_devices(&["mac".into()]).await.unwrap().remove(0);
        assert_eq!(old.registration.token, "a".repeat(64));
        store.register("mac", registration('a')).await.unwrap();
        assert_eq!(
            old.generation,
            store.for_devices(&["mac".into()]).await.unwrap()[0].generation
        );
        store
            .unregister("another-device", PushPlatform::ApnsSandbox)
            .await
            .unwrap();
        store
            .register("new-identity", registration('a'))
            .await
            .unwrap();
        assert!(store.for_devices(&["mac".into()]).await.unwrap().is_empty());
        assert_eq!(
            store
                .for_devices(&["new-identity".into()])
                .await
                .unwrap()
                .len(),
            1
        );
    }

    #[tokio::test]
    #[ignore = "requires local Postgres"]
    async fn postgres_push_tokens_survive_reconnect_and_fence_old_provider_responses() {
        let database =
            crate::test_database::TestDatabase::migrated("IDENTITY_TEST_DATABASE_URL", 4).await;
        let first = PgPushTokenStore::new(database.pool.clone());
        first.register("mac", registration('a')).await.unwrap();
        let old = first.for_devices(&["mac".into()]).await.unwrap().remove(0);
        let second_pool = database.reconnect(4).await;
        let second = PgPushTokenStore::new(second_pool.clone());
        second.register("mac", registration('b')).await.unwrap();
        first.invalidate(&old).await.unwrap();
        assert_eq!(
            second.for_devices(&["mac".into()]).await.unwrap()[0]
                .registration
                .token,
            "b".repeat(64)
        );
        second
            .register("another-device", registration('b'))
            .await
            .unwrap();
        assert!(first.for_devices(&["mac".into()]).await.unwrap().is_empty());
        second
            .unregister("another-device", PushPlatform::ApnsSandbox)
            .await
            .unwrap();
        assert!(first
            .for_devices(&["another-device".into()])
            .await
            .unwrap()
            .is_empty());
        second_pool.close().await;
        database.cleanup().await;
    }
}
