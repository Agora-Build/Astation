//! Station report identity and bounded HTTPS client for the published Portal API.
use crate::integration_feed::{FeedBinding, FeedPage, PolicyStore, PAGE_LIMIT};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ring::{
    rand::SystemRandom,
    signature::{self, KeyPair},
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PortalError {
    Configuration,
    Unavailable,
    Denied,
    Contract,
    Conflict,
    CursorAhead,
}

/// Separate report-only key. It is never an R9 service/native signing provider.
pub(crate) struct StationReportKey(signature::EcdsaKeyPair);

impl StationReportKey {
    /// The operator must load these bytes from protected storage. Neither a
    /// browser request nor the Portal supplies this private key.
    pub fn from_pkcs8(bytes: &[u8]) -> Result<Self, PortalError> {
        signature::EcdsaKeyPair::from_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            bytes,
            &SystemRandom::new(),
        )
        .map(Self)
        .map_err(|_| PortalError::Configuration)
    }
    pub fn public_jwk(&self) -> Value {
        let key = self.0.public_key().as_ref();
        json!({"kty":"EC","crv":"P-256","x":URL_SAFE_NO_PAD.encode(&key[1..33]),
            "y":URL_SAFE_NO_PAD.encode(&key[33..65])})
    }
    fn assertion(&self, binding: &FeedBinding, now: i64) -> Result<String, PortalError> {
        if now < 0 {
            return Err(PortalError::Configuration);
        }
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"ES256"}"#);
        let claims = URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&json!({
                "iss":binding.report_client_id,"sub":binding.report_client_id,
                "aud":format!("{}/token",binding.issuer),"jti":uuid::Uuid::new_v4().to_string(),
                "iat":now,"exp":now.checked_add(60).ok_or(PortalError::Configuration)?
            }))
            .map_err(|_| PortalError::Configuration)?,
        );
        let input = format!("{header}.{claims}");
        let signature = self
            .0
            .sign(&SystemRandom::new(), input.as_bytes())
            .map_err(|_| PortalError::Configuration)?;
        Ok(format!(
            "{input}.{}",
            URL_SAFE_NO_PAD.encode(signature.as_ref())
        ))
    }
}

struct ReportToken {
    value: String,
    until: Instant,
}

pub(crate) struct PortalReportClient {
    binding: FeedBinding,
    key: StationReportKey,
    http: reqwest::Client,
    token: Mutex<Option<ReportToken>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IntegrationReport<'a> {
    pub integration_id: &'a str,
    pub state: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<&'a str>,
}

impl PortalReportClient {
    pub fn public_jwk(&self) -> Value {
        self.key.public_jwk()
    }
    pub fn new(binding: FeedBinding, key: StationReportKey) -> Result<Self, PortalError> {
        binding.validate().map_err(|_| PortalError::Configuration)?;
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(5))
            .no_proxy()
            .build()
            .map_err(|_| PortalError::Configuration)?;
        Ok(Self {
            binding,
            key,
            http,
            token: Mutex::new(None),
        })
    }

    async fn response<T: DeserializeOwned>(
        mut response: reqwest::Response,
        bound: usize,
    ) -> Result<T, PortalError> {
        let status = response.status().as_u16();
        match status {
            200 | 409 => {}
            401 | 403 => return Err(PortalError::Denied),
            400 | 404 | 422 => return Err(PortalError::Contract),
            _ => return Err(PortalError::Unavailable),
        }
        if response.content_length().is_some_and(|n| n > bound as u64) {
            return Err(PortalError::Contract);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| PortalError::Unavailable)?
        {
            if bytes.len().saturating_add(chunk.len()) > bound {
                return Err(PortalError::Contract);
            }
            bytes.extend_from_slice(&chunk);
        }
        if status == 409 {
            return Err(
                if serde_json::from_slice::<Value>(&bytes)
                    .is_ok_and(|v| v["code"] == "cursor_ahead")
                {
                    PortalError::CursorAhead
                } else {
                    PortalError::Conflict
                },
            );
        }
        serde_json::from_slice(&bytes).map_err(|_| PortalError::Contract)
    }

    async fn access_token(&self) -> Result<String, PortalError> {
        let mut cached = self.token.lock().await;
        if let Some(token) = cached.as_ref().filter(|t| Instant::now() < t.until) {
            return Ok(token.value.clone());
        }
        *cached = None;
        #[derive(Deserialize)]
        struct Reply {
            access_token: String,
            token_type: String,
            expires_in: u64,
            scope: String,
        }
        let assertion = self
            .key
            .assertion(&self.binding, chrono::Utc::now().timestamp())?;
        let start = Instant::now();
        let response = self
            .http
            .post(format!("{}/token", self.binding.issuer))
            .form(&[
                ("grant_type", "client_credentials"),
                ("resource", self.binding.portal_origin.as_str()),
                ("scope", "station.report"),
                (
                    "client_assertion_type",
                    "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                ),
                ("client_assertion", assertion.as_str()),
            ])
            .send()
            .await
            .map_err(|_| PortalError::Unavailable)?;
        let reply: Reply = Self::response(response, 16_384).await?;
        if !reply.token_type.eq_ignore_ascii_case("bearer")
            || reply.access_token.is_empty()
            || reply.access_token.len() > 8192
            || reply.access_token.bytes().any(|b| !b.is_ascii_graphic())
            || !(31..=3600).contains(&reply.expires_in)
            || reply.scope != "station.report"
        {
            return Err(PortalError::Contract);
        }
        let until = start + Duration::from_secs(reply.expires_in - 30);
        if Instant::now() >= until {
            return Err(PortalError::Unavailable);
        }
        *cached = Some(ReportToken {
            value: reply.access_token.clone(),
            until,
        });
        Ok(reply.access_token)
    }

    pub async fn changes(&self, cursor: u64) -> Result<FeedPage, PortalError> {
        let token = self.access_token().await?;
        let response = self
            .http
            .get(format!(
                "{}/api/v1/stations/changes",
                self.binding.portal_origin
            ))
            .query(&[("cursor", cursor)])
            .bearer_auth(token)
            .send()
            .await
            .map_err(|_| PortalError::Unavailable)?;
        let result = Self::response(response, 4_194_304).await;
        if matches!(result, Err(PortalError::Denied)) {
            *self.token.lock().await = None;
        }
        result
    }

    pub async fn report(&self, report: IntegrationReport<'_>) -> Result<(), PortalError> {
        if !crate::integration_feed::client_id(report.integration_id, "i-")
            || !matches!(
                report.state,
                "waiting_for_host" | "ready" | "revoked" | "error"
            )
            || (report.state == "error" && report.reason.is_none())
            || report.reason.is_some_and(|r| {
                r.is_empty() || r.chars().count() > 200 || r.chars().any(char::is_control)
            })
        {
            return Err(PortalError::Configuration);
        }
        let token = self.access_token().await?;
        let response = self
            .http
            .post(format!(
                "{}/api/v1/stations/reports",
                self.binding.portal_origin
            ))
            .bearer_auth(token)
            .json(&report)
            .send()
            .await
            .map_err(|_| PortalError::Unavailable)?;
        let result = Self::response::<Value>(response, 65_536).await;
        if matches!(result, Err(PortalError::Denied)) {
            *self.token.lock().await = None;
        }
        result.map(|_| ())
    }

    /// Durable policy and cursor are updated together before callers may use
    /// them. Transport errors never refresh the previous policy's freshness.
    pub async fn poll(&self, store: &PolicyStore, reconcile: bool) -> Result<bool, PortalError> {
        let old = store
            .load(&self.binding)
            .await
            .map_err(|_| PortalError::Unavailable)?;
        let cursor = if reconcile || old.revision == 0 || old.denied {
            0
        } else {
            old.cursor
        };
        match self.changes(cursor).await {
            Ok(page) => {
                let full = page.changes.len() == PAGE_LIMIT;
                let next = old
                    .apply(cursor, page, chrono::Utc::now().timestamp())
                    .map_err(|_| PortalError::Contract)?;
                store
                    .commit(&old, &next)
                    .await
                    .map_err(|_| PortalError::Conflict)?;
                Ok(full)
            }
            Err(error @ (PortalError::Denied | PortalError::CursorAhead)) => {
                store
                    .deny(&self.binding)
                    .await
                    .map_err(|_| PortalError::Unavailable)?;
                // Persist the fence before a cursor-zero refresh. A response
                // already in flight on another replica cannot undo this denial.
                Err(error)
            }
            Err(error) => Err(error),
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use axum::{
        extract::State,
        http::{HeaderMap, StatusCode},
        response::IntoResponse,
        routing::{get, post},
        Json, Router,
    };
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };
    use tokio::task::JoinHandle;

    pub(crate) struct Fixture {
        pub binding: FeedBinding,
        pub key: Option<StationReportKey>,
        pub shared: Arc<Shared>,
        task: JoinHandle<()>,
    }
    pub(crate) struct Shared {
        public: Vec<u8>,
        tokens: AtomicUsize,
        feeds: AtomicUsize,
        status: AtomicUsize,
        assertions: Mutex<Vec<String>>,
        pub reports: Mutex<Vec<Value>>,
        pub feed: Mutex<Option<Value>>,
        pub cursors: Mutex<Vec<u64>>,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.task.abort();
        }
    }
    impl Fixture {
        pub fn set_status(&self, status: usize) {
            self.shared.status.store(status, Ordering::SeqCst);
        }
        pub async fn new() -> Self {
            let bytes = signature::EcdsaKeyPair::generate_pkcs8(
                &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
                &SystemRandom::new(),
            )
            .unwrap();
            let key = StationReportKey::from_pkcs8(bytes.as_ref()).unwrap();
            let shared = Arc::new(Shared {
                public: key.0.public_key().as_ref().to_vec(),
                tokens: AtomicUsize::new(0),
                feeds: AtomicUsize::new(0),
                status: AtomicUsize::new(200),
                assertions: Mutex::new(vec![]),
                reports: Mutex::new(vec![]),
                feed: Mutex::new(None),
                cursors: Mutex::new(vec![]),
            });
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let origin = format!("http://{}", listener.local_addr().unwrap());
            let app = Router::new()
                .route("/token", post(token))
                .route("/api/v1/stations/changes", get(changes))
                .route("/api/v1/stations/reports", post(report))
                .with_state(shared.clone());
            let task = tokio::spawn(async move {
                axum::serve(listener, app).await.unwrap();
            });
            Self {
                binding: FeedBinding {
                    issuer: origin.clone(),
                    portal_origin: origin,
                    station_origin: "https://custom.example".into(),
                    report_client_id: "s-01234567890123456789012345".into(),
                },
                key: Some(key),
                shared,
                task,
            }
        }
        fn client(&mut self) -> PortalReportClient {
            PortalReportClient::new(self.binding.clone(), self.key.take().unwrap()).unwrap()
        }
    }
    async fn token(
        State(shared): State<Arc<Shared>>,
        axum::extract::Form(form): axum::extract::Form<std::collections::HashMap<String, String>>,
    ) -> Json<Value> {
        assert_eq!(form["grant_type"], "client_credentials");
        assert_eq!(form["scope"], "station.report");
        let assertion = &form["client_assertion"];
        let parts: Vec<_> = assertion.split('.').collect();
        assert_eq!(parts.len(), 3);
        signature::UnparsedPublicKey::new(&signature::ECDSA_P256_SHA256_FIXED, &shared.public)
            .verify(
                format!("{}.{}", parts[0], parts[1]).as_bytes(),
                &URL_SAFE_NO_PAD.decode(parts[2]).unwrap(),
            )
            .unwrap();
        let claims: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(claims["iss"], claims["sub"]);
        assert_eq!(
            claims["exp"].as_i64().unwrap() - claims["iat"].as_i64().unwrap(),
            60
        );
        assert_eq!(claims["aud"], format!("{}/token", form["resource"]));
        shared
            .assertions
            .lock()
            .await
            .push(claims["jti"].as_str().unwrap().into());
        shared.tokens.fetch_add(1, Ordering::SeqCst);
        Json(
            json!({"access_token":"test-report-token","token_type":"Bearer","expires_in":300,"scope":"station.report"}),
        )
    }
    async fn changes(
        State(shared): State<Arc<Shared>>,
        axum::extract::Query(query): axum::extract::Query<std::collections::HashMap<String, u64>>,
        headers: HeaderMap,
    ) -> axum::response::Response {
        assert_eq!(headers["authorization"], "Bearer test-report-token");
        shared.feeds.fetch_add(1, Ordering::SeqCst);
        shared.cursors.lock().await.push(query["cursor"]);
        let code = shared.status.load(Ordering::SeqCst) as u16;
        (
            StatusCode::from_u16(code).unwrap(),
            Json(
                shared
                    .feed
                    .lock()
                    .await
                    .clone()
                    .unwrap_or_else(|| json!({"changes":[],"cursor":0,"integrations":[]})),
            ),
        )
            .into_response()
    }
    async fn report(
        State(shared): State<Arc<Shared>>,
        headers: HeaderMap,
        Json(body): Json<Value>,
    ) -> axum::response::Response {
        assert_eq!(headers["authorization"], "Bearer test-report-token");
        shared.reports.lock().await.push(body);
        (
            StatusCode::from_u16(shared.status.load(Ordering::SeqCst) as u16).unwrap(),
            Json(json!({"state":"waiting_for_host"})),
        )
            .into_response()
    }
    #[tokio::test]
    async fn reports_contain_only_the_published_fields_and_refusals_are_not_retried() {
        let mut fixture = Fixture::new().await;
        let client = fixture.client();
        let id = "i-01234567890123456789012345";
        client
            .report(IntegrationReport {
                integration_id: id,
                state: "waiting_for_host",
                reason: None,
            })
            .await
            .unwrap();
        assert_eq!(
            *fixture.shared.reports.lock().await,
            vec![json!({"integrationId":id,"state":"waiting_for_host"})]
        );
        assert_eq!(
            client
                .report(IntegrationReport {
                    integration_id: id,
                    state: "error",
                    reason: None
                })
                .await,
            Err(PortalError::Configuration)
        );
        assert_eq!(fixture.shared.reports.lock().await.len(), 1);
        fixture.shared.status.store(409, Ordering::SeqCst);
        assert_eq!(
            client
                .report(IntegrationReport {
                    integration_id: id,
                    state: "ready",
                    reason: None
                })
                .await,
            Err(PortalError::Conflict)
        );
        assert_eq!(fixture.shared.reports.lock().await.len(), 2);
    }
    #[tokio::test]
    async fn report_assertions_are_single_use_and_tokens_are_cached_only_for_the_report_resource() {
        let mut f = Fixture::new().await;
        let client = f.client();
        let public = client.key.public_jwk();
        assert_eq!(public["kty"], "EC");
        assert!(public.get("d").is_none());
        client.changes(0).await.unwrap();
        client.changes(0).await.unwrap();
        assert_eq!(f.shared.tokens.load(Ordering::SeqCst), 1);
        f.shared.status.store(401, Ordering::SeqCst);
        assert!(matches!(client.changes(0).await, Err(PortalError::Denied)));
        f.shared.status.store(200, Ordering::SeqCst);
        client.changes(0).await.unwrap();
        assert_eq!(f.shared.tokens.load(Ordering::SeqCst), 2);
        let assertions = f.shared.assertions.lock().await;
        assert_eq!(assertions.len(), 2);
        assert_ne!(assertions[0], assertions[1]);
        f.shared.status.store(302, Ordering::SeqCst);
        assert!(matches!(
            client.changes(0).await,
            Err(PortalError::Unavailable)
        ));
    }
    #[tokio::test]
    #[ignore]
    async fn postgres_portal_authentication_refusal_durably_denies_cached_policy() {
        let db =
            crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 2).await;
        let store = PolicyStore(db.pool.clone());
        let mut f = Fixture::new().await;
        let client = f.client();
        assert!(!client.poll(&store, false).await.unwrap());
        assert!(!store.load(&f.binding).await.unwrap().denied);
        f.shared.status.store(403, Ordering::SeqCst);
        assert_eq!(client.poll(&store, false).await, Err(PortalError::Denied));
        let saved = store.load(&f.binding).await.unwrap();
        assert!(saved.denied);
        f.shared.status.store(503, Ordering::SeqCst);
        assert_eq!(
            client.poll(&store, false).await,
            Err(PortalError::Unavailable)
        );
        assert_eq!(store.load(&f.binding).await.unwrap(), saved);
        db.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_cursor_ahead_fences_inflight_policy_then_reconciles_from_zero() {
        let db =
            crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
        let store = PolicyStore(db.pool.clone());
        let mut f = Fixture::new().await;
        let client = f.client();
        *f.shared.feed.lock().await = Some(
            json!({"changes":[{"id":47,"kind":"station_registered"}],"cursor":47,"integrations":[]}),
        );
        client.poll(&store, false).await.unwrap();
        let previous = store.load(&f.binding).await.unwrap();
        f.shared.status.store(409, Ordering::SeqCst);
        *f.shared.feed.lock().await =
            Some(json!({"error":"cursor is ahead","code":"cursor_ahead"}));
        assert_eq!(
            client.poll(&store, false).await,
            Err(PortalError::CursorAhead)
        );
        let denied = store.load(&f.binding).await.unwrap();
        assert!(denied.denied);
        assert_eq!(denied.cursor, 47);
        assert!(store
            .commit(
                &previous,
                &previous
                    .apply(
                        47,
                        serde_json::from_value(json!({"changes":[],"cursor":47})).unwrap(),
                        chrono::Utc::now().timestamp()
                    )
                    .unwrap()
            )
            .await
            .is_err());
        f.shared.status.store(200, Ordering::SeqCst);
        *f.shared.feed.lock().await = Some(
            json!({"changes":[{"id":2,"kind":"station_registered"}],"cursor":2,"integrations":[]}),
        );
        client.poll(&store, false).await.unwrap();
        let repaired = store.load(&f.binding).await.unwrap();
        assert!(!repaired.denied);
        assert_eq!(repaired.cursor, 2);
        assert!(repaired.revision > denied.revision);
        assert_eq!(*f.shared.cursors.lock().await, vec![0, 47, 0]);
        db.cleanup().await;
    }

    #[tokio::test]
    async fn unrelated_conflict_never_becomes_a_cursor_reset() {
        let mut f = Fixture::new().await;
        let client = f.client();
        f.shared.status.store(409, Ordering::SeqCst);
        *f.shared.feed.lock().await = Some(json!({"code":"some_other_conflict","cursor":0}));
        assert!(matches!(
            client.changes(47).await,
            Err(PortalError::Conflict)
        ));
        assert_eq!(*f.shared.cursors.lock().await, vec![47]);
    }
}
