use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::RwLock;

/// Cache for verified sessions from Astation.
/// Reduces load on Astation by caching validation results.
#[derive(Clone)]
pub struct SessionVerifyCache {
    cache: Arc<RwLock<HashMap<String, CachedSession>>>,
}

struct CachedSession {
    session_id: String,
    astation_id: String,
    valid: bool,
    cached_at: u64,
    ttl_seconds: u64,
}

impl SessionVerifyCache {
    pub fn new() -> Self {
        Self {
            cache: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Check if we have a cached validation for this session.
    /// Returns Some(valid) if cached and not expired, None if needs verification.
    pub async fn get(&self, session_id: &str) -> Option<bool> {
        let cache = self.cache.read().await;
        if let Some(cached) = cache.get(session_id) {
            let now = now_timestamp();
            let age = now.saturating_sub(cached.cached_at);

            if age < cached.ttl_seconds {
                tracing::debug!(
                    "Session {} cache HIT (age: {}s, valid: {})",
                    session_id,
                    age,
                    cached.valid
                );
                return Some(cached.valid);
            } else {
                tracing::debug!("Session {} cache EXPIRED (age: {}s)", session_id, age);
            }
        }
        None
    }

    /// Cache a session validation result.
    pub async fn set(&self, session_id: String, astation_id: String, valid: bool, ttl_seconds: u64) {
        let mut cache = self.cache.write().await;
        cache.insert(
            session_id.clone(),
            CachedSession {
                session_id: session_id.clone(),
                astation_id,
                valid,
                cached_at: now_timestamp(),
                ttl_seconds,
            },
        );
        tracing::debug!(
            "Session {} cached (valid: {}, ttl: {}s)",
            session_id,
            valid,
            ttl_seconds
        );
    }

    /// Remove a session from cache (e.g., after explicit invalidation).
    pub async fn remove(&self, session_id: &str) {
        let mut cache = self.cache.write().await;
        cache.remove(session_id);
        tracing::debug!("Session {} removed from cache", session_id);
    }

    /// Clean up expired entries (called periodically).
    pub async fn cleanup_expired(&self) {
        let now = now_timestamp();
        let mut cache = self.cache.write().await;
        let before_count = cache.len();

        cache.retain(|_, cached| {
            let age = now.saturating_sub(cached.cached_at);
            age < cached.ttl_seconds
        });

        let removed = before_count - cache.len();
        if removed > 0 {
            tracing::info!("Cleaned up {} expired session cache entries", removed);
        }
    }

    /// Get cache statistics.
    pub async fn stats(&self) -> CacheStats {
        let cache = self.cache.read().await;
        let now = now_timestamp();
        let mut valid_count = 0;
        let mut invalid_count = 0;
        let mut expired_count = 0;

        for cached in cache.values() {
            let age = now.saturating_sub(cached.cached_at);
            if age >= cached.ttl_seconds {
                expired_count += 1;
            } else if cached.valid {
                valid_count += 1;
            } else {
                invalid_count += 1;
            }
        }

        CacheStats {
            total: cache.len(),
            valid: valid_count,
            invalid: invalid_count,
            expired: expired_count,
        }
    }
}

impl Default for SessionVerifyCache {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Serialize)]
pub struct CacheStats {
    pub total: usize,
    pub valid: usize,
    pub invalid: usize,
    pub expired: usize,
}

/// Message sent from Relay to Astation to verify a session.
#[derive(Debug, Serialize, Deserialize)]
pub struct SessionVerifyRequest {
    pub session_id: String,
    pub request_id: String, // For matching response
}

/// Message sent from Astation to Relay with verification result.
#[derive(Debug, Serialize, Deserialize)]
pub struct SessionVerifyResponse {
    pub session_id: String,
    pub request_id: String,
    pub valid: bool,
    pub astation_id: Option<String>, // Only if valid
}

fn now_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_cache_miss() {
        let cache = SessionVerifyCache::new();
        assert!(cache.get("nonexistent").await.is_none());
    }

    #[tokio::test]
    async fn test_cache_hit_valid() {
        let cache = SessionVerifyCache::new();
        cache.set(
            "sess-123".to_string(),
            "astation-home".to_string(),
            true,
            300,
        ).await;

        let result = cache.get("sess-123").await;
        assert_eq!(result, Some(true));
    }

    #[tokio::test]
    async fn test_cache_hit_invalid() {
        let cache = SessionVerifyCache::new();
        cache.set(
            "sess-456".to_string(),
            "astation-home".to_string(),
            false,
            300,
        ).await;

        let result = cache.get("sess-456").await;
        assert_eq!(result, Some(false));
    }

    #[tokio::test]
    async fn test_cache_expiry() {
        let cache = SessionVerifyCache::new();
        cache.set(
            "sess-789".to_string(),
            "astation-home".to_string(),
            true,
            1, // 1 second TTL
        ).await;

        // Should be cached initially
        assert_eq!(cache.get("sess-789").await, Some(true));

        // Wait for expiry
        tokio::time::sleep(Duration::from_secs(2)).await;

        // Should be expired now
        assert!(cache.get("sess-789").await.is_none());
    }

    #[tokio::test]
    async fn test_cache_remove() {
        let cache = SessionVerifyCache::new();
        cache.set(
            "sess-abc".to_string(),
            "astation-home".to_string(),
            true,
            300,
        ).await;

        assert!(cache.get("sess-abc").await.is_some());
        cache.remove("sess-abc").await;
        assert!(cache.get("sess-abc").await.is_none());
    }

    #[tokio::test]
    async fn test_cleanup_expired() {
        let cache = SessionVerifyCache::new();

        // Add valid session
        cache.set("sess-1".to_string(), "astation-1".to_string(), true, 300).await;

        // Add expired session
        cache.set("sess-2".to_string(), "astation-2".to_string(), true, 1).await;
        tokio::time::sleep(Duration::from_secs(2)).await;

        cache.cleanup_expired().await;

        // Valid session should remain
        assert!(cache.get("sess-1").await.is_some());
        // Expired should be gone (cleanup removes it)
        let stats = cache.stats().await;
        assert_eq!(stats.total, 1);
    }

    #[tokio::test]
    async fn test_cache_stats() {
        let cache = SessionVerifyCache::new();

        cache.set("sess-1".to_string(), "ast-1".to_string(), true, 300).await;
        cache.set("sess-2".to_string(), "ast-2".to_string(), false, 300).await;
        cache.set("sess-3".to_string(), "ast-3".to_string(), true, 1).await;

        tokio::time::sleep(Duration::from_secs(2)).await;

        let stats = cache.stats().await;
        assert_eq!(stats.total, 3);
        assert_eq!(stats.valid, 1);
        assert_eq!(stats.invalid, 1);
        assert_eq!(stats.expired, 1);
    }
}
