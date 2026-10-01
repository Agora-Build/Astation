//! Shared per-IP limits: a fixed one-minute window per bucket and IP.

use async_trait::async_trait;

use super::{keys, RedisConn};
use crate::cluster::ratelimit::{window_decision, RateDecision, SharedRateLimiter};
use crate::cluster::StoreError;

/// A window's counter outlives its minute by one more.
const WINDOW_KEY_TTL_SECS: i64 = 120;

pub struct RedisRateLimiter {
    conn: RedisConn,
}

impl RedisRateLimiter {
    pub fn new(conn: RedisConn) -> Self {
        Self { conn }
    }
}

#[async_trait]
impl SharedRateLimiter for RedisRateLimiter {
    fn backend_name(&self) -> &'static str {
        "redis"
    }

    async fn hit(
        &self,
        bucket: &str,
        ip: &str,
        limit: u64,
        now: i64,
    ) -> Result<RateDecision, StoreError> {
        let key = keys::rate(bucket, ip, now.div_euclid(60));
        // INCR and EXPIRE in one MULTI/EXEC: a counter never exists without its expiry.
        let (count,): (u64,) = self
            .conn
            .run(|mut c| async move {
                redis::pipe()
                    .atomic()
                    .incr(&key, 1)
                    .expire(&key, WINDOW_KEY_TTL_SECS)
                    .ignore()
                    .query_async(&mut c)
                    .await
            })
            .await?;
        Ok(window_decision(count, limit, now))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::redis::test_support::{fresh_conn, REDIS_LOCK};

    #[tokio::test]
    #[ignore]
    async fn redis_rate_limit_is_a_shared_fixed_window() {
        let _guard = REDIS_LOCK.lock().await;
        let conn = fresh_conn().await;
        let one = RedisRateLimiter::new(conn.clone());
        let two = RedisRateLimiter::new(conn.clone()); // another replica
        let now = 1_699_999_990; // 10 s into its minute
        assert_eq!(
            one.hit("grant", "203.0.113.5", 2, now).await.unwrap(),
            RateDecision::Allowed
        );
        assert_eq!(
            two.hit("grant", "203.0.113.5", 2, now).await.unwrap(),
            RateDecision::Allowed
        );
        assert_eq!(
            one.hit("grant", "203.0.113.5", 2, now).await.unwrap(),
            RateDecision::Limited {
                retry_after_secs: 50
            }
        );
        assert_eq!(
            one.hit("grant", "203.0.113.6", 2, now).await.unwrap(),
            RateDecision::Allowed
        );
        assert_eq!(
            one.hit("general", "203.0.113.5", 2, now).await.unwrap(),
            RateDecision::Allowed
        );
        assert_eq!(
            one.hit("grant", "203.0.113.5", 2, now + 60).await.unwrap(),
            RateDecision::Allowed
        );
        let key = keys::rate("grant", "203.0.113.5", now / 60);
        let ttl: i64 = conn
            .run(|mut c| async move { redis::cmd("TTL").arg(&key).query_async(&mut c).await })
            .await
            .unwrap();
        assert!((1..=120).contains(&ttl), "ttl {ttl}");
    }
}
