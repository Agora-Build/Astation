//! Per-IP limits shared by all replicas (spec: "Rate limits").
//! tower_governor keeps enforcing its per-replica token bucket on every
//! route, unchanged. This layer adds the same limits as fixed one-minute
//! windows shared through Redis, so N replicas don't allow N× the
//! requests. In-memory mode needs no shared limit (one replica: the
//! governor is the whole limit), so its limiter always allows. On a Redis
//! error the request is allowed and the governor still applies (fail open).

use async_trait::async_trait;
use axum::extract::{Request, State};
use axum::http::{HeaderValue, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use tower_governor::key_extractor::{KeyExtractor, SmartIpKeyExtractor};

use super::StoreError;
use crate::relay::RelayHub;

pub const GRANT_LIMIT_PER_MINUTE: u64 = 60;
pub const GENERAL_LIMIT_PER_MINUTE: u64 = 600;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RateDecision {
    Allowed,
    // Constructed by Task 18 (RedisRateLimiter).
    #[allow(dead_code)]
    Limited { retry_after_secs: u64 },
}

#[async_trait]
pub trait SharedRateLimiter: Send + Sync {
    // Task 18 (RedisRateLimiter)/Task 11 health.
    #[allow(dead_code)]
    fn backend_name(&self) -> &'static str;
    /// Count one request from `ip` in `bucket` for the minute containing
    /// `now` (unix seconds).
    async fn hit(&self, bucket: &str, ip: &str, limit: u64, now: i64) -> Result<RateDecision, StoreError>;
}

/// Single instance: the per-replica governor is the whole limit.
pub struct NoopRateLimiter;

#[async_trait]
impl SharedRateLimiter for NoopRateLimiter {
    fn backend_name(&self) -> &'static str {
        "memory"
    }

    async fn hit(&self, _bucket: &str, _ip: &str, _limit: u64, _now: i64) -> Result<RateDecision, StoreError> {
        Ok(RateDecision::Allowed)
    }
}

/// The decision for the `count`-th request of a one-minute window.
// Task 18 (RedisRateLimiter) applies the window.
#[allow(dead_code)]
pub fn window_decision(count: u64, limit: u64, now: i64) -> RateDecision {
    if count <= limit {
        RateDecision::Allowed
    } else {
        RateDecision::Limited {
            retry_after_secs: (60 - now.rem_euclid(60)) as u64,
        }
    }
}

#[derive(Clone)]
pub struct SharedLimit {
    pub hub: RelayHub,
    pub bucket: &'static str,
    pub limit: u64,
}

pub async fn shared_rate_limit(State(limit): State<SharedLimit>, request: Request, next: Next) -> Response {
    let ip = SmartIpKeyExtractor
        .extract(&request)
        .map(|ip| ip.to_string())
        .unwrap_or_else(|_| "unknown".to_string());
    let now = chrono::Utc::now().timestamp();
    match limit.hub.rate_limiter().hit(limit.bucket, &ip, limit.limit, now).await {
        Ok(RateDecision::Allowed) => next.run(request).await,
        Ok(RateDecision::Limited { retry_after_secs }) => too_many_requests(retry_after_secs),
        Err(error) => {
            tracing::debug!("Shared rate limit unavailable, per-replica limit applies: {}", error);
            next.run(request).await
        }
    }
}

/// Same status and body as tower_governor's rejection.
fn too_many_requests(wait: u64) -> Response {
    let mut response = (
        StatusCode::TOO_MANY_REQUESTS,
        format!("Too Many Requests! Wait for {}s", wait),
    )
        .into_response();
    response
        .headers_mut()
        .insert("retry-after", HeaderValue::from(wait));
    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::{to_bytes, Body};
    use axum::routing::get;
    use axum::Router;
    use std::sync::Arc;
    use tower::ServiceExt;

    #[test]
    fn fixed_window_decision() {
        let now = 1_699_999_990; // 10 s into its minute
        assert_eq!(window_decision(60, 60, now), RateDecision::Allowed);
        assert_eq!(
            window_decision(61, 60, now),
            RateDecision::Limited { retry_after_secs: 50 }
        );
    }

    struct AlwaysLimited;

    #[async_trait]
    impl SharedRateLimiter for AlwaysLimited {
        fn backend_name(&self) -> &'static str {
            "limited"
        }
        async fn hit(&self, _: &str, _: &str, _: u64, _: i64) -> Result<RateDecision, StoreError> {
            Ok(RateDecision::Limited { retry_after_secs: 7 })
        }
    }

    struct Broken;

    #[async_trait]
    impl SharedRateLimiter for Broken {
        fn backend_name(&self) -> &'static str {
            "broken"
        }
        async fn hit(&self, _: &str, _: &str, _: u64, _: i64) -> Result<RateDecision, StoreError> {
            Err(StoreError::Unavailable("down".into()))
        }
    }

    fn app(limiter: Arc<dyn SharedRateLimiter>) -> Router {
        let limit = SharedLimit {
            hub: RelayHub::with_rate_limiter(limiter),
            bucket: "general",
            limit: GENERAL_LIMIT_PER_MINUTE,
        };
        Router::new()
            .route("/limited", get(|| async { "ok" }))
            .layer(axum::middleware::from_fn_with_state(limit, shared_rate_limit))
    }

    async fn call(app: Router) -> axum::response::Response {
        app.oneshot(
            axum::http::Request::builder()
                .uri("/limited")
                .header("x-forwarded-for", "203.0.113.20")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn limited_requests_get_governor_shaped_429() {
        let response = call(app(Arc::new(AlwaysLimited))).await;
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers()["retry-after"], "7");
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        assert_eq!(body.as_ref(), b"Too Many Requests! Wait for 7s");
    }

    #[tokio::test]
    async fn memory_limiter_and_a_broken_backend_let_requests_through() {
        assert_eq!(call(app(Arc::new(NoopRateLimiter))).await.status(), StatusCode::OK);
        assert_eq!(call(app(Arc::new(Broken))).await.status(), StatusCode::OK);
    }
}
