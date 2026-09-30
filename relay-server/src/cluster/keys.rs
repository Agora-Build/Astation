//! The relay's copy of the registered Astation keys (astation_id →
//! lowercase hex). Postgres is authoritative; connects and verifications
//! read this cache with no I/O, so a connect flood or a database outage
//! can't lock registered Astations out. A change on one replica is announced
//! on the bus (`key-changed`) and every replica re-reads that one key.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::Duration;

use crate::identity_store::{IdentityError, IdentityStore};

/// Bound on a re-read after a `key-changed` announcement.
pub const KEY_REREAD_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CachedKey {
    pub public_key: String,
    /// A `key-changed` re-read failed: re-read before trusting this key.
    pub stale: bool,
}

#[derive(Clone, Default)]
pub struct KeyCache {
    keys: Arc<RwLock<HashMap<String, CachedKey>>>,
}

impl KeyCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// Replace the cache with every key in `identity` (startup, resubscribe).
    pub async fn load(&self, identity: &dyn IdentityStore) -> Result<usize, IdentityError> {
        let keys: HashMap<String, CachedKey> = identity
            .list_keys()
            .await?
            .into_iter()
            .map(|(id, key)| {
                (id, CachedKey { public_key: key.to_ascii_lowercase(), stale: false })
            })
            .collect();
        let count = keys.len();
        *self.keys.write().unwrap_or_else(|e| e.into_inner()) = keys;
        Ok(count)
    }

    pub fn get(&self, astation_id: &str) -> Option<CachedKey> {
        self.keys
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .get(astation_id)
            .cloned()
    }

    pub fn contains(&self, astation_id: &str) -> bool {
        self.keys
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(astation_id)
    }

    pub fn set(&self, astation_id: &str, public_key: &str) {
        self.keys.write().unwrap_or_else(|e| e.into_inner()).insert(
            astation_id.to_string(),
            CachedKey { public_key: public_key.to_ascii_lowercase(), stale: false },
        );
    }

    pub fn forget(&self, astation_id: &str) {
        self.keys
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .remove(astation_id);
    }

    fn mark_stale(&self, astation_id: &str) {
        if let Some(entry) = self
            .keys
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .get_mut(astation_id)
        {
            entry.stale = true;
        }
    }

    /// After a `key-changed` announcement: re-read one key. If the store
    /// can't be read, a cached key is kept but marked stale, so it still
    /// makes connects pending and is re-read before it verifies anything.
    pub async fn reload_one(&self, identity: &dyn IdentityStore, astation_id: &str) {
        match tokio::time::timeout(KEY_REREAD_TIMEOUT, identity.get_key(astation_id)).await {
            Ok(Ok(Some(key))) => self.set(astation_id, &key),
            Ok(Ok(None)) => self.forget(astation_id),
            Ok(Err(error)) => {
                tracing::warn!(
                    "Could not re-read the key of Astation {}: {}",
                    crate::relay::mask_code(astation_id),
                    error
                );
                self.mark_stale(astation_id);
            }
            Err(_) => {
                tracing::warn!(
                    "Timed out re-reading the key of Astation {}",
                    crate::relay::mask_code(astation_id)
                );
                self.mark_stale(astation_id);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity_store::{
        BindOutcome, InMemoryIdentityStore, RegisterOutcome, ReplaceOutcome,
    };

    /// A store whose every call fails (database down).
    struct DownStore;

    #[async_trait::async_trait]
    impl IdentityStore for DownStore {
        fn backend_name(&self) -> &'static str {
            "down"
        }
        async fn get_key(&self, _: &str) -> Result<Option<String>, IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
        async fn register_key_if_absent(&self, _: &str, _: &str, _: i64) -> Result<RegisterOutcome, IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
        async fn touch_key(&self, _: &str, _: i64) -> Result<(), IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
        async fn list_keys(&self) -> Result<Vec<(String, String)>, IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
        async fn bind(&self, _: &str, _: &str, _: i64) -> Result<BindOutcome, IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
        async fn unbind(&self, _: &str, _: &str) -> Result<bool, IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
        async fn replace_all(&self, _: &str, _: &[String], _: i64) -> Result<ReplaceOutcome, IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
        async fn resolve(&self, _: &str, _: i64) -> Result<Option<String>, IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
    }

    #[tokio::test]
    async fn load_set_forget() {
        let store = InMemoryIdentityStore::new();
        store.register_key_if_absent("astation-a", "04AA", 1).await.unwrap();
        let cache = KeyCache::new();
        assert_eq!(cache.load(&store).await.unwrap(), 1);
        assert_eq!(
            cache.get("astation-a"),
            Some(CachedKey { public_key: "04aa".into(), stale: false })
        );
        cache.set("astation-b", "04BB");
        assert!(cache.contains("astation-b"));
        assert_eq!(cache.get("astation-b").unwrap().public_key, "04bb");
        cache.forget("astation-b");
        assert!(!cache.contains("astation-b"));
    }

    #[tokio::test]
    async fn reload_one_follows_the_store() {
        let store = InMemoryIdentityStore::new();
        let cache = KeyCache::new();
        cache.set("astation-a", "04aa");
        // The key was replaced in the store.
        store.register_key_if_absent("astation-a", "04CC", 1).await.unwrap();
        cache.reload_one(&store, "astation-a").await;
        assert_eq!(cache.get("astation-a").unwrap().public_key, "04cc");
        // A key registered elsewhere reaches this cache.
        store.register_key_if_absent("astation-new", "04dd", 1).await.unwrap();
        cache.reload_one(&store, "astation-new").await;
        assert!(cache.contains("astation-new"));
        // Deleted (admin reset): forgotten.
        cache.set("astation-gone", "04ee");
        cache.reload_one(&store, "astation-gone").await;
        assert!(!cache.contains("astation-gone"));
    }

    #[tokio::test]
    async fn failed_reload_marks_the_key_stale() {
        let cache = KeyCache::new();
        cache.set("astation-a", "04aa");
        cache.reload_one(&DownStore, "astation-a").await;
        assert_eq!(
            cache.get("astation-a"),
            Some(CachedKey { public_key: "04aa".into(), stale: true })
        );
        // Still pending on connect.
        assert!(cache.contains("astation-a"));
        // A later successful set clears it.
        cache.set("astation-a", "04aa");
        assert!(!cache.get("astation-a").unwrap().stale);
        // An unknown id stays unknown.
        cache.reload_one(&DownStore, "astation-unknown").await;
        assert!(!cache.contains("astation-unknown"));
    }
}
