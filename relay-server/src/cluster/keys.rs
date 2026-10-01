//! The relay's copy of the registered Astation keys (astation_id →
//! lowercase hex). Postgres is authoritative; connects and verifications
//! read this cache with no I/O, so a connect flood or a database outage
//! can't lock registered Astations out. A change on one replica is announced
//! on the bus (`key-changed`) and every replica re-reads that one key.
//!
//! Fail-closed exception: a key marked stale (its re-read failed) is
//! re-read before it verifies anything, so during a continuing database
//! outage even the correct key is rejected until the store answers.

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

#[derive(Default)]
struct Inner {
    keys: HashMap<String, CachedKey>,
    /// Bumped on every `set` and `forget` (even of an absent id, so a
    /// forget leaves a tombstone). A slow read applies its result only if
    /// the generation it started from is unchanged.
    generations: HashMap<String, u64>,
}

impl Inner {
    fn generation(&self, astation_id: &str) -> u64 {
        self.generations.get(astation_id).copied().unwrap_or(0)
    }

    fn bump(&mut self, astation_id: &str) {
        *self.generations.entry(astation_id.to_string()).or_insert(0) += 1;
    }

    fn set(&mut self, astation_id: &str, public_key: &str) {
        self.bump(astation_id);
        self.keys.insert(
            astation_id.to_string(),
            CachedKey {
                public_key: public_key.to_ascii_lowercase(),
                stale: false,
            },
        );
    }

    fn forget(&mut self, astation_id: &str) {
        self.bump(astation_id);
        self.keys.remove(astation_id);
    }
}

#[derive(Clone, Default)]
pub struct KeyCache {
    inner: Arc<RwLock<Inner>>,
}

impl KeyCache {
    pub fn new() -> Self {
        Self::default()
    }

    fn read(&self) -> std::sync::RwLockReadGuard<'_, Inner> {
        self.inner.read().unwrap_or_else(|e| e.into_inner())
    }

    fn write(&self) -> std::sync::RwLockWriteGuard<'_, Inner> {
        self.inner.write().unwrap_or_else(|e| e.into_inner())
    }

    /// Replace the cache with every key in `identity` (startup, resubscribe).
    /// An id set or forgotten while the listing was in flight keeps its
    /// newer state.
    pub async fn load(&self, identity: &dyn IdentityStore) -> Result<usize, IdentityError> {
        let before = self.read().generations.clone();
        let listed = identity.list_keys().await?;
        let mut inner = self.write();
        let moved =
            |inner: &Inner, id: &str| inner.generation(id) != before.get(id).copied().unwrap_or(0);
        let mut keys: HashMap<String, CachedKey> = HashMap::new();
        for (id, key) in listed {
            if !moved(&inner, &id) {
                keys.insert(
                    id,
                    CachedKey {
                        public_key: key.to_ascii_lowercase(),
                        stale: false,
                    },
                );
            }
        }
        for (id, cached) in inner.keys.iter() {
            if moved(&inner, id) {
                keys.insert(id.clone(), cached.clone());
            }
        }
        let count = keys.len();
        inner.keys = keys;
        Ok(count)
    }

    pub fn get(&self, astation_id: &str) -> Option<CachedKey> {
        self.read().keys.get(astation_id).cloned()
    }

    pub fn contains(&self, astation_id: &str) -> bool {
        self.read().keys.contains_key(astation_id)
    }

    pub fn set(&self, astation_id: &str, public_key: &str) {
        self.write().set(astation_id, public_key);
    }

    pub fn forget(&self, astation_id: &str) {
        self.write().forget(astation_id);
    }

    /// Mark stale, unless the entry changed since `generation`.
    fn mark_stale(&self, astation_id: &str, generation: u64) {
        let mut inner = self.write();
        if inner.generation(astation_id) != generation {
            return;
        }
        if let Some(entry) = inner.keys.get_mut(astation_id) {
            entry.stale = true;
        }
    }

    /// After a `key-changed` announcement: re-read one key. If the store
    /// can't be read, a cached key is kept but marked stale, so it still
    /// makes connects pending and is re-read before it verifies anything.
    /// A `set`/`forget` that lands during the read wins over its result.
    pub async fn reload_one(&self, identity: &dyn IdentityStore, astation_id: &str) {
        let generation = self.read().generation(astation_id);
        match tokio::time::timeout(KEY_REREAD_TIMEOUT, identity.get_key(astation_id)).await {
            Ok(Ok(result)) => {
                let mut inner = self.write();
                if inner.generation(astation_id) != generation {
                    return;
                }
                match result {
                    Some(key) => inner.set(astation_id, &key),
                    None => inner.forget(astation_id),
                }
            }
            Ok(Err(error)) => {
                tracing::warn!(
                    "Could not re-read the key of Astation {}: {}",
                    crate::relay::mask_code(astation_id),
                    error
                );
                self.mark_stale(astation_id, generation);
            }
            Err(_) => {
                tracing::warn!(
                    "Timed out re-reading the key of Astation {}",
                    crate::relay::mask_code(astation_id)
                );
                self.mark_stale(astation_id, generation);
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
        async fn register_key_if_absent(
            &self,
            _: &str,
            _: &str,
            _: i64,
        ) -> Result<RegisterOutcome, IdentityError> {
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
        async fn replace_all(
            &self,
            _: &str,
            _: &[String],
            _: i64,
        ) -> Result<ReplaceOutcome, IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
        async fn resolve(&self, _: &str, _: i64) -> Result<Option<String>, IdentityError> {
            Err(IdentityError::Db("down".into()))
        }
    }

    #[tokio::test]
    async fn load_set_forget() {
        let store = InMemoryIdentityStore::new();
        store
            .register_key_if_absent("astation-a", "04AA", 1)
            .await
            .unwrap();
        let cache = KeyCache::new();
        assert_eq!(cache.load(&store).await.unwrap(), 1);
        assert_eq!(
            cache.get("astation-a"),
            Some(CachedKey {
                public_key: "04aa".into(),
                stale: false
            })
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
        store
            .register_key_if_absent("astation-a", "04CC", 1)
            .await
            .unwrap();
        cache.reload_one(&store, "astation-a").await;
        assert_eq!(cache.get("astation-a").unwrap().public_key, "04cc");
        // A key registered elsewhere reaches this cache.
        store
            .register_key_if_absent("astation-new", "04dd", 1)
            .await
            .unwrap();
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
            Some(CachedKey {
                public_key: "04aa".into(),
                stale: true
            })
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

    /// A store whose `get_key` waits until released (a slow read), then
    /// returns the configured answer.
    struct SlowStore {
        entered: std::sync::Arc<tokio::sync::Notify>,
        release: std::sync::Arc<tokio::sync::Notify>,
        answer: Option<String>,
    }

    #[async_trait::async_trait]
    impl IdentityStore for SlowStore {
        fn backend_name(&self) -> &'static str {
            "slow"
        }
        async fn get_key(&self, _: &str) -> Result<Option<String>, IdentityError> {
            self.entered.notify_one();
            self.release.notified().await;
            Ok(self.answer.clone())
        }
        async fn register_key_if_absent(
            &self,
            _: &str,
            _: &str,
            _: i64,
        ) -> Result<RegisterOutcome, IdentityError> {
            unreachable!()
        }
        async fn touch_key(&self, _: &str, _: i64) -> Result<(), IdentityError> {
            unreachable!()
        }
        async fn list_keys(&self) -> Result<Vec<(String, String)>, IdentityError> {
            self.entered.notify_one();
            self.release.notified().await;
            Ok(self
                .answer
                .iter()
                .map(|k| ("astation-a".to_string(), k.clone()))
                .collect())
        }
        async fn bind(&self, _: &str, _: &str, _: i64) -> Result<BindOutcome, IdentityError> {
            unreachable!()
        }
        async fn unbind(&self, _: &str, _: &str) -> Result<bool, IdentityError> {
            unreachable!()
        }
        async fn replace_all(
            &self,
            _: &str,
            _: &[String],
            _: i64,
        ) -> Result<ReplaceOutcome, IdentityError> {
            unreachable!()
        }
        async fn resolve(&self, _: &str, _: i64) -> Result<Option<String>, IdentityError> {
            unreachable!()
        }
    }

    fn slow(
        answer: &str,
    ) -> (
        SlowStore,
        std::sync::Arc<tokio::sync::Notify>,
        std::sync::Arc<tokio::sync::Notify>,
    ) {
        let entered = std::sync::Arc::new(tokio::sync::Notify::new());
        let release = std::sync::Arc::new(tokio::sync::Notify::new());
        let store = SlowStore {
            entered: entered.clone(),
            release: release.clone(),
            answer: Some(answer.to_string()),
        };
        (store, entered, release)
    }

    #[tokio::test]
    async fn slow_reload_does_not_resurrect_a_forgotten_key() {
        let (store, entered, release) = slow("04aa");
        let cache = KeyCache::new();
        cache.set("astation-a", "04aa");
        let c2 = cache.clone();
        let task = tokio::spawn(async move { c2.reload_one(&store, "astation-a").await });
        entered.notified().await;
        cache.forget("astation-a"); // admin reset while the read is in flight
        release.notify_one();
        task.await.unwrap();
        assert!(!cache.contains("astation-a"));
    }

    #[tokio::test]
    async fn forget_of_an_absent_id_still_beats_a_slow_reload() {
        let (store, entered, release) = slow("04aa");
        let cache = KeyCache::new();
        let c2 = cache.clone();
        let task = tokio::spawn(async move { c2.reload_one(&store, "astation-a").await });
        entered.notified().await;
        cache.forget("astation-a");
        release.notify_one();
        task.await.unwrap();
        assert!(!cache.contains("astation-a"));
    }

    #[tokio::test]
    async fn slow_reload_does_not_overwrite_a_newer_set() {
        let (store, entered, release) = slow("04aa");
        let cache = KeyCache::new();
        cache.set("astation-a", "04aa");
        let c2 = cache.clone();
        let task = tokio::spawn(async move { c2.reload_one(&store, "astation-a").await });
        entered.notified().await;
        cache.set("astation-a", "04bb");
        release.notify_one();
        task.await.unwrap();
        assert_eq!(cache.get("astation-a").unwrap().public_key, "04bb");
    }

    #[tokio::test]
    async fn load_does_not_clobber_a_concurrent_set_or_forget() {
        let (store, entered, release) = slow("04aa");
        let cache = KeyCache::new();
        cache.set("astation-b", "04bb");
        cache.set("astation-c", "04cc");
        let c2 = cache.clone();
        let task = tokio::spawn(async move { c2.load(&store).await.unwrap() });
        entered.notified().await;
        cache.set("astation-a", "04ff"); // listed as 04aa, but set newer
        cache.forget("astation-b");
        release.notify_one();
        task.await.unwrap();
        assert_eq!(cache.get("astation-a").unwrap().public_key, "04ff");
        assert!(!cache.contains("astation-b"));
        // Untouched and not listed: dropped by the reload.
        assert!(!cache.contains("astation-c"));
    }

    #[tokio::test]
    async fn load_clears_stale() {
        let cache = KeyCache::new();
        cache.set("astation-a", "04aa");
        cache.reload_one(&DownStore, "astation-a").await;
        assert!(cache.get("astation-a").unwrap().stale);
        let store = InMemoryIdentityStore::new();
        store
            .register_key_if_absent("astation-a", "04aa", 1)
            .await
            .unwrap();
        cache.load(&store).await.unwrap();
        assert!(!cache.get("astation-a").unwrap().stale);
    }

    #[tokio::test(start_paused = true)]
    async fn reload_timeout_marks_the_key_stale() {
        struct Hang;
        #[async_trait::async_trait]
        impl IdentityStore for Hang {
            fn backend_name(&self) -> &'static str {
                "hang"
            }
            async fn get_key(&self, _: &str) -> Result<Option<String>, IdentityError> {
                std::future::pending().await
            }
            async fn register_key_if_absent(
                &self,
                _: &str,
                _: &str,
                _: i64,
            ) -> Result<RegisterOutcome, IdentityError> {
                unreachable!()
            }
            async fn touch_key(&self, _: &str, _: i64) -> Result<(), IdentityError> {
                unreachable!()
            }
            async fn list_keys(&self) -> Result<Vec<(String, String)>, IdentityError> {
                unreachable!()
            }
            async fn bind(&self, _: &str, _: &str, _: i64) -> Result<BindOutcome, IdentityError> {
                unreachable!()
            }
            async fn unbind(&self, _: &str, _: &str) -> Result<bool, IdentityError> {
                unreachable!()
            }
            async fn replace_all(
                &self,
                _: &str,
                _: &[String],
                _: i64,
            ) -> Result<ReplaceOutcome, IdentityError> {
                unreachable!()
            }
            async fn resolve(&self, _: &str, _: i64) -> Result<Option<String>, IdentityError> {
                unreachable!()
            }
        }
        let cache = KeyCache::new();
        cache.set("astation-a", "04aa");
        cache.reload_one(&Hang, "astation-a").await;
        assert_eq!(
            cache.get("astation-a"),
            Some(CachedKey {
                public_key: "04aa".into(),
                stale: true
            })
        );
    }
}
