//! Provider adapters only. Callers must authenticate the host and select control
//! members before using these; a relay room join is insufficient authority.
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use ring::{rand::SystemRandom, signature};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{path::Path, time::Duration};
use tokio::sync::Mutex;

use crate::push_tokens::{PushPlatform, RegisteredPushToken};
use atem_client::push::{guard, Hint, HintState, CLIENT_SKEW_MS};

/// Only the shared verifier can construct a Hint. No plaintext provider path.
pub struct PushNotice(pub Hint);

impl PushNotice {
    pub fn approval_id(&self) -> &str {
        &self.0.key().approval_id
    }

    fn valid(&self) -> bool {
        let id = self.approval_id();
        uuid::Uuid::parse_str(id).is_ok() && id.len() == 36 && self.0.check_sealed().is_ok()
    }

    fn data(&self) -> Value {
        // FCM data values must be strings. Both providers carry identical
        // signed bytes; unsigned outer fields never supply approval identity.
        json!({"r9_hint":self.0.object().to_json().to_string()})
    }

    fn expiration(&self, _now: i64) -> i64 {
        let end = if self.resolved() { self.0.expires_at().saturating_add(CLIENT_SKEW_MS) }
            else { guard(self.0.expires_at()) };
        (end / 1000).min(i64::MAX as u64) as i64
    }

    fn resolved(&self) -> bool {
        matches!(self.0.state(), HintState::Resolved { .. })
    }

    fn apns_payload(&self) -> Value {
        let mut payload = self.data();
        payload["aps"] = if self.resolved() { json!({"content-available":1}) } else {
            json!({"alert":{"title":"Agent approval requested",
                "body":"Open Astation to review this request."},
                "sound":"default", "mutable-content":1, "category":"AGENT_APPROVAL"})
        };
        payload
    }

    fn fcm_payload(&self, token: &str, now: i64) -> Value {
        let data = self.data();
        let mut message = json!({"token":token, "data":data, "android":{
            "priority":"HIGH", "ttl":format!("{}s", (self.expiration(now) - now).clamp(0, 86400))}});
        if !self.resolved() {
            message["notification"] = json!({"title":"Agent approval requested",
                "body":"Open Astation to review this request."});
            message["android"]["notification"] =
                json!({"tag":self.approval_id(), "channel_id":"agent_approvals"});
        }
        json!({"message":message})
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum PushDeliveryResult {
    Sent,
    Expired,
    InvalidToken,
    Retry,
    Rejected,
    Disabled,
}

#[derive(Debug)]
pub struct PushConfigError(pub &'static str);

struct ApnsCredentials {
    key: signature::EcdsaKeyPair,
    key_id: String,
    team_id: String,
    topic: String,
}
struct FcmCredentials {
    key: signature::RsaKeyPair,
    email: String,
    project: String,
}
struct AccessToken {
    value: String,
    issued_at: i64,
    expires_at: i64,
}

struct ProviderResponse {
    status: u16,
    body: Value,
}

#[async_trait::async_trait]
trait PushTransport: Send + Sync {
    async fn execute(
        &self,
        request: reqwest::Request,
    ) -> Result<ProviderResponse, PushDeliveryResult>;
}

struct HttpPushTransport(reqwest::Client);

#[async_trait::async_trait]
impl PushTransport for HttpPushTransport {
    async fn execute(
        &self,
        request: reqwest::Request,
    ) -> Result<ProviderResponse, PushDeliveryResult> {
        let response = self
            .0
            .execute(request)
            .await
            .map_err(|_| PushDeliveryResult::Retry)?;
        let status = response.status().as_u16();
        let body = bounded_json(response).await.unwrap_or(Value::Null);
        Ok(ProviderResponse { status, body })
    }
}

pub struct PushDelivery {
    http: reqwest::Client,
    apns: Option<ApnsCredentials>,
    fcm: Option<FcmCredentials>,
    transport: std::sync::Arc<dyn PushTransport>,
    apns_access_token: std::sync::Mutex<Option<AccessToken>>,
    fcm_access_token: Mutex<Option<AccessToken>>,
}

fn pem_private_key(path: &Path) -> Result<Vec<u8>, PushConfigError> {
    let text = std::fs::read_to_string(path)
        .map_err(|_| PushConfigError("cannot read push signing key file"))?;
    decode_pem(&text)
}

fn decode_pem(text: &str) -> Result<Vec<u8>, PushConfigError> {
    let body = text
        .trim()
        .strip_prefix("-----BEGIN PRIVATE KEY-----")
        .and_then(|body| body.strip_suffix("-----END PRIVATE KEY-----"))
        .ok_or(PushConfigError("push signing key must be PKCS#8 PEM"))?;
    STANDARD
        .decode(body.split_whitespace().collect::<String>())
        .map_err(|_| PushConfigError("invalid push signing key"))
}

fn env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
}

fn jwt_input(header: Value, claims: Value) -> String {
    format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(header.to_string()),
        URL_SAFE_NO_PAD.encode(claims.to_string())
    )
}

impl PushDelivery {
    pub fn from_env() -> Result<Self, PushConfigError> {
        let apns_values = [
            env("APNS_KEY_FILE"),
            env("APNS_KEY_ID"),
            env("APNS_TEAM_ID"),
            env("APNS_TOPIC"),
        ];
        let apns = if apns_values.iter().any(Option::is_some) {
            let [Some(path), Some(key_id), Some(team_id), Some(topic)] = apns_values else {
                return Err(PushConfigError(
                    "set APNS_KEY_FILE, APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC together",
                ));
            };
            if ![&key_id, &team_id].iter().all(|value| {
                value.len() == 10 && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
            }) || topic.len() > 255
                || !topic.contains('.')
                || !topic
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
            {
                return Err(PushConfigError("invalid APNs team, key id or topic"));
            }
            let key = signature::EcdsaKeyPair::from_pkcs8(
                &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
                &pem_private_key(Path::new(&path))?,
                &SystemRandom::new(),
            )
            .map_err(|_| PushConfigError("invalid APNs P-256 key"))?;
            Some(ApnsCredentials {
                key,
                key_id,
                team_id,
                topic,
            })
        } else {
            None
        };
        let fcm = if let Some(path) = env("FCM_SERVICE_ACCOUNT_FILE") {
            #[derive(Deserialize)]
            struct Account {
                project_id: String,
                client_email: String,
                private_key: String,
            }
            let bytes = std::fs::read(path)
                .map_err(|_| PushConfigError("cannot read FCM service account file"))?;
            let account: Account = serde_json::from_slice(&bytes)
                .map_err(|_| PushConfigError("invalid FCM service account JSON"))?;
            if account.project_id.is_empty()
                || account.project_id.len() > 63
                || !account
                    .project_id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                || !account.client_email.ends_with(".gserviceaccount.com")
                || account.client_email.len() > 255
            {
                return Err(PushConfigError(
                    "invalid FCM service account project or email",
                ));
            }
            let key = signature::RsaKeyPair::from_pkcs8(&decode_pem(&account.private_key)?)
                .map_err(|_| PushConfigError("invalid FCM RSA key"))?;
            Some(FcmCredentials {
                key,
                email: account.client_email,
                project: account.project_id,
            })
        } else {
            None
        };
        let http = reqwest::Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(10))
            .build()
            .map_err(|_| PushConfigError("cannot initialize push HTTP client"))?;
        Ok(Self {
            transport: std::sync::Arc::new(HttpPushTransport(http.clone())),
            http,
            apns,
            fcm,
            apns_access_token: std::sync::Mutex::new(None),
            fcm_access_token: Mutex::new(None),
        })
    }

    pub fn enabled(&self) -> bool {
        self.apns.is_some() || self.fcm.is_some()
    }

    fn apns_bearer(&self, now: i64) -> Result<String, PushDeliveryResult> {
        let credentials = self.apns.as_ref().ok_or(PushDeliveryResult::Disabled)?;
        let mut cached = self
            .apns_access_token
            .lock()
            .map_err(|_| PushDeliveryResult::Rejected)?;
        if let Some(token) = cached
            .as_ref()
            .filter(|token| now >= token.issued_at && now < token.expires_at)
        {
            return Ok(token.value.clone());
        }
        let input = jwt_input(
            json!({"alg":"ES256", "kid":credentials.key_id}),
            json!({"iss":credentials.team_id, "iat":now}),
        );
        let signature = credentials
            .key
            .sign(&SystemRandom::new(), input.as_bytes())
            .map_err(|_| PushDeliveryResult::Rejected)?;
        let value = format!("{input}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref()));
        // Apple rejects provider JWTs refreshed too often; reuse for 50 minutes.
        *cached = Some(AccessToken {
            value: value.clone(),
            issued_at: now,
            expires_at: now + 3000,
        });
        Ok(value)
    }

    async fn fcm_bearer(&self, now: i64) -> Result<String, PushDeliveryResult> {
        let credentials = self.fcm.as_ref().ok_or(PushDeliveryResult::Disabled)?;
        let mut cached = self.fcm_access_token.lock().await;
        if let Some(token) = cached
            .as_ref()
            .filter(|token| now >= token.issued_at && token.expires_at > now + 60)
        {
            return Ok(token.value.clone());
        }
        let input = jwt_input(
            json!({"alg":"RS256", "typ":"JWT"}),
            json!({"iss":credentials.email,
            "scope":"https://www.googleapis.com/auth/firebase.messaging", "aud":"https://oauth2.googleapis.com/token",
            "iat":now, "exp":now + 3600}),
        );
        let mut signed = vec![0; credentials.key.public().modulus_len()];
        credentials
            .key
            .sign(
                &signature::RSA_PKCS1_SHA256,
                &SystemRandom::new(),
                input.as_bytes(),
                &mut signed,
            )
            .map_err(|_| PushDeliveryResult::Rejected)?;
        let assertion = format!("{input}.{}", URL_SAFE_NO_PAD.encode(signed));
        let request = self
            .http
            .post("https://oauth2.googleapis.com/token")
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                ("assertion", assertion.as_str()),
            ])
            .build()
            .map_err(|_| PushDeliveryResult::Rejected)?;
        let response = self.transport.execute(request).await?;
        if response.status == 429 || response.status >= 500 {
            return Err(PushDeliveryResult::Retry);
        }
        if !(200..300).contains(&response.status) {
            return Err(PushDeliveryResult::Rejected);
        }
        let value = response.body;
        let token = value["access_token"]
            .as_str()
            .filter(|token| !token.is_empty() && token.len() <= 8192)
            .ok_or(PushDeliveryResult::Rejected)?
            .to_string();
        let lifetime = value["expires_in"]
            .as_i64()
            .filter(|seconds| (61..=3600).contains(seconds))
            .ok_or(PushDeliveryResult::Rejected)?;
        *cached = Some(AccessToken {
            value: token.clone(),
            issued_at: now,
            expires_at: now + lifetime,
        });
        Ok(token)
    }

    pub async fn send(
        &self,
        token: &RegisteredPushToken,
        notice: &PushNotice,
    ) -> PushDeliveryResult {
        self.send_with_clock(token, notice, || chrono::Utc::now().timestamp())
            .await
    }

    #[cfg(test)]
    async fn send_at(
        &self,
        token: &RegisteredPushToken,
        notice: &PushNotice,
        now: i64,
    ) -> PushDeliveryResult {
        self.send_with_clock(token, notice, || now).await
    }

    async fn send_with_clock(
        &self,
        token: &RegisteredPushToken,
        notice: &PushNotice,
        clock: impl Fn() -> i64 + Send + Sync,
    ) -> PushDeliveryResult {
        let now = clock();
        if !notice.valid() || !token.registration.valid() {
            return PushDeliveryResult::Rejected;
        }
        if matches!(notice.0.state(), HintState::Open { device_id, .. } if *device_id != token.device_id) {
            return PushDeliveryResult::Rejected;
        }
        if notice.expiration(now) <= now {
            return PushDeliveryResult::Expired;
        }
        let bearer = match token.registration.platform {
            PushPlatform::ApnsSandbox | PushPlatform::ApnsProduction => self.apns_bearer(now),
            PushPlatform::Fcm => self.fcm_bearer(now).await,
        };
        let bearer = match bearer {
            Ok(value) => value,
            Err(result) => return result,
        };
        // OAuth refresh may outlast the approval. Check again at dispatch time.
        let now = clock();
        if notice.expiration(now) <= now {
            return PushDeliveryResult::Expired;
        }
        let request = match token.registration.platform {
            PushPlatform::ApnsSandbox | PushPlatform::ApnsProduction => {
                let endpoint = if token.registration.platform == PushPlatform::ApnsSandbox {
                    "api.sandbox.push.apple.com"
                } else {
                    "api.push.apple.com"
                };
                let resolved = notice.resolved();
                self.http
                    .post(format!(
                        "https://{endpoint}/3/device/{}",
                        token.registration.token
                    ))
                    .version(reqwest::Version::HTTP_2)
                    .bearer_auth(bearer)
                    .header("apns-topic", &self.apns.as_ref().unwrap().topic)
                    .header("apns-collapse-id", notice.approval_id())
                    .header("apns-expiration", notice.expiration(now))
                    .header(
                        "apns-push-type",
                        if resolved { "background" } else { "alert" },
                    )
                    .header("apns-priority", if resolved { "5" } else { "10" })
                    .json(&notice.apns_payload())
            }
            PushPlatform::Fcm => self
                .http
                .post(format!(
                    "https://fcm.googleapis.com/v1/projects/{}/messages:send",
                    self.fcm.as_ref().unwrap().project
                ))
                .bearer_auth(bearer)
                .json(&notice.fcm_payload(&token.registration.token, now)),
        };
        let request = match request.build() {
            Ok(value) => value,
            Err(_) => return PushDeliveryResult::Rejected,
        };
        if request.body().and_then(|body| body.as_bytes()).is_none_or(|body| body.len() > 4096) {
            return PushDeliveryResult::Rejected;
        }
        let response = match self.transport.execute(request).await {
            Ok(value) => value,
            Err(result) => return result,
        };
        if (200..300).contains(&response.status) {
            return PushDeliveryResult::Sent;
        }
        if response.status == 429 || response.status >= 500 {
            return PushDeliveryResult::Retry;
        }
        if token.registration.platform == PushPlatform::Fcm && response.status == 401 {
            *self.fcm_access_token.lock().await = None;
            return PushDeliveryResult::Retry;
        }
        if response.status == 403 && response.body["reason"] == "ExpiredProviderToken" {
            if let Ok(mut cached) = self.apns_access_token.lock() {
                *cached = None;
            }
            return PushDeliveryResult::Retry;
        }
        classify_rejection(token.registration.platform, response.status, &response.body)
    }
}

async fn bounded_json(mut response: reqwest::Response) -> Result<Value, PushDeliveryResult> {
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| PushDeliveryResult::Retry)?
    {
        if bytes.len() + chunk.len() > 16_384 {
            return Err(PushDeliveryResult::Rejected);
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| PushDeliveryResult::Rejected)
}

fn classify_rejection(platform: PushPlatform, status: u16, body: &Value) -> PushDeliveryResult {
    let invalid = match platform {
        PushPlatform::ApnsSandbox | PushPlatform::ApnsProduction => {
            (status == 410 && body["reason"] == "Unregistered")
                || (status == 400
                    && ["BadDeviceToken", "DeviceTokenNotForTopic"]
                        .iter()
                        .any(|reason| body["reason"] == *reason))
        }
        PushPlatform::Fcm => {
            status == 404
                && body["error"]["details"].as_array().is_some_and(|details| {
                    details.iter().any(|detail| {
                        detail["@type"] == "type.googleapis.com/google.firebase.fcm.v1.FcmError"
                            && detail["errorCode"] == "UNREGISTERED"
                    })
                })
        }
    };
    if invalid {
        PushDeliveryResult::InvalidToken
    } else {
        PushDeliveryResult::Rejected
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::KeyPair;

    fn notice() -> PushNotice {
        PushNotice(crate::remote_api::push_ingress::tests::Fixture::new(700_000).verified(false))
    }

    fn resolution() -> PushNotice {
        PushNotice(crate::remote_api::push_ingress::tests::Fixture::new(700_000).verified(true))
    }

    struct RecordingTransport {
        requests: std::sync::Mutex<Vec<reqwest::Request>>,
        statuses: std::sync::Mutex<std::collections::VecDeque<ProviderResponse>>,
    }

    #[async_trait::async_trait]
    impl PushTransport for RecordingTransport {
        async fn execute(
            &self,
            request: reqwest::Request,
        ) -> Result<ProviderResponse, PushDeliveryResult> {
            self.requests.lock().unwrap().push(request);
            Ok(self.statuses.lock().unwrap().pop_front().unwrap())
        }
    }

    fn fcm_delivery(
        responses: Vec<ProviderResponse>,
    ) -> (PushDelivery, std::sync::Arc<RecordingTransport>, Vec<u8>) {
        let key = signature::RsaKeyPair::from_pkcs8(
            &decode_pem(include_str!("../tests/fixtures/fcm-test-key.pem")).unwrap(),
        )
        .unwrap();
        let public = key.public_key().as_ref().to_vec();
        let transport = std::sync::Arc::new(RecordingTransport {
            requests: std::sync::Mutex::new(Vec::new()),
            statuses: std::sync::Mutex::new(responses.into()),
        });
        let delivery = PushDelivery {
            http: reqwest::Client::new(),
            apns: None,
            fcm: Some(FcmCredentials {
                key,
                email: "test@test-project.iam.gserviceaccount.com".into(),
                project: "test-project".into(),
            }),
            transport: transport.clone(),
            apns_access_token: std::sync::Mutex::new(None),
            fcm_access_token: Mutex::new(None),
        };
        (delivery, transport, public)
    }

    fn fcm_token() -> RegisteredPushToken {
        RegisteredPushToken {
            device_id: "phone".into(),
            generation: "generation".into(),
            registration: crate::push_tokens::PushRegistration {
                platform: PushPlatform::Fcm,
                token: "synthetic-fcm-address".repeat(3),
            },
        }
    }

    #[tokio::test]
    async fn fcm_oauth_signature_cache_refresh_and_delivery_use_the_injected_transport() {
        let oauth = |token: &str| ProviderResponse {
            status: 200,
            body: json!({"access_token":token, "expires_in":3600}),
        };
        let (delivery, transport, public) = fcm_delivery(vec![
            oauth("synthetic-oauth-one"),
            ProviderResponse {
                status: 200,
                body: json!({"name":"messages/test"}),
            },
            ProviderResponse {
                status: 401,
                body: Value::Null,
            },
            oauth("synthetic-oauth-two"),
            ProviderResponse {
                status: 404,
                body: json!({"error":{"details":[{
                "@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode":"UNREGISTERED"}]}}),
            },
            ProviderResponse {
                status: 503,
                body: Value::Null,
            },
        ]);
        let token = fcm_token();
        let approval = notice();
        assert_eq!(
            delivery.send_at(&token, &approval, 900).await,
            PushDeliveryResult::Sent
        );
        assert_eq!(
            delivery.send_at(&token, &approval, 901).await,
            PushDeliveryResult::Retry
        );
        assert_eq!(
            delivery.send_at(&token, &approval, 902).await,
            PushDeliveryResult::InvalidToken
        );
        assert_eq!(
            delivery.send_at(&token, &approval, 903).await,
            PushDeliveryResult::Retry
        );
        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests.len(), 6);
        for index in [0, 3] {
            assert_eq!(
                requests[index].url().as_str(),
                "https://oauth2.googleapis.com/token"
            );
            let form: std::collections::HashMap<_, _> =
                url::form_urlencoded::parse(requests[index].body().unwrap().as_bytes().unwrap())
                    .into_owned()
                    .collect();
            assert_eq!(
                form["grant_type"],
                "urn:ietf:params:oauth:grant-type:jwt-bearer"
            );
            let parts: Vec<_> = form["assertion"].split('.').collect();
            let claims: Value =
                serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
            assert_eq!(claims["aud"], "https://oauth2.googleapis.com/token");
            assert_eq!(
                claims["scope"],
                "https://www.googleapis.com/auth/firebase.messaging"
            );
            assert_eq!(claims["iss"], "test@test-project.iam.gserviceaccount.com");
            assert_eq!(
                claims["exp"].as_i64().unwrap() - claims["iat"].as_i64().unwrap(),
                3600
            );
            signature::UnparsedPublicKey::new(&signature::RSA_PKCS1_2048_8192_SHA256, &public)
                .verify(
                    format!("{}.{}", parts[0], parts[1]).as_bytes(),
                    &URL_SAFE_NO_PAD.decode(parts[2]).unwrap(),
                )
                .unwrap();
        }
        for index in [1, 2, 4, 5] {
            assert_eq!(
                requests[index].url().as_str(),
                "https://fcm.googleapis.com/v1/projects/test-project/messages:send"
            );
        }
        assert_eq!(
            requests[1].headers()["authorization"],
            "Bearer synthetic-oauth-one"
        );
        assert_eq!(
            requests[2].headers()["authorization"],
            requests[1].headers()["authorization"]
        );
        assert_eq!(
            requests[4].headers()["authorization"],
            "Bearer synthetic-oauth-two"
        );
        assert_eq!(
            requests[5].headers()["authorization"],
            requests[4].headers()["authorization"]
        );
        let payload: Value =
            serde_json::from_slice(requests[1].body().unwrap().as_bytes().unwrap()).unwrap();
        assert_eq!(payload["message"]["token"], token.registration.token);
        assert_eq!(
            payload["message"]["android"]["notification"]["tag"],
            approval.approval_id()
        );
    }

    #[tokio::test]
    async fn an_approval_expiring_during_oauth_refresh_is_never_dispatched() {
        let (delivery, transport, _) = fcm_delivery(vec![ProviderResponse {
            status: 200,
            body: json!({"access_token":"synthetic-oauth", "expires_in":3600}),
        }]);
        let ticks = std::sync::atomic::AtomicUsize::new(0);
        let result = delivery
            .send_with_clock(&fcm_token(), &notice(), || {
                if ticks.fetch_add(1, std::sync::atomic::Ordering::Relaxed) == 0 {
                    900
                } else {
                    1000
                }
            })
            .await;
        assert_eq!(result, PushDeliveryResult::Expired);
        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].url().as_str(),
            "https://oauth2.googleapis.com/token"
        );
    }

    #[tokio::test]
    async fn apns_wire_headers_and_provider_refusals_are_exercised_without_network() {
        let random = SystemRandom::new();
        let document = signature::EcdsaKeyPair::generate_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &random,
        )
        .unwrap();
        let key = signature::EcdsaKeyPair::from_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            document.as_ref(),
            &random,
        )
        .unwrap();
        let transport = std::sync::Arc::new(RecordingTransport {
            requests: std::sync::Mutex::new(Vec::new()),
            statuses: std::sync::Mutex::new(std::collections::VecDeque::from([
                ProviderResponse {
                    status: 200,
                    body: Value::Null,
                },
                ProviderResponse {
                    status: 410,
                    body: json!({"reason":"Unregistered"}),
                },
                ProviderResponse {
                    status: 429,
                    body: Value::Null,
                },
            ])),
        });
        let delivery = PushDelivery {
            http: reqwest::Client::new(),
            apns: Some(ApnsCredentials {
                key,
                key_id: "0123456789".into(),
                team_id: "9876543210".into(),
                topic: "build.agora.astation".into(),
            }),
            fcm: None,
            transport: transport.clone(),
            apns_access_token: std::sync::Mutex::new(None),
            fcm_access_token: Mutex::new(None),
        };
        let token = RegisteredPushToken {
            device_id: "phone".into(),
            generation: "generation".into(),
            registration: crate::push_tokens::PushRegistration {
                platform: PushPlatform::ApnsSandbox,
                token: "ab".repeat(32),
            },
        };
        let approval = notice();
        assert_eq!(
            delivery.send_at(&token, &approval, 1000).await,
            PushDeliveryResult::Expired
        );
        assert!(transport.requests.lock().unwrap().is_empty());
        assert_eq!(
            delivery.send_at(&token, &approval, 900).await,
            PushDeliveryResult::Sent
        );
        let resolved = resolution();
        assert_eq!(
            delivery.send_at(&token, &resolved, 901).await,
            PushDeliveryResult::InvalidToken
        );
        assert_eq!(
            delivery.send_at(&token, &approval, 902).await,
            PushDeliveryResult::Retry
        );
        let requests = transport.requests.lock().unwrap();
        assert_eq!(
            requests[0].url().host_str(),
            Some("api.sandbox.push.apple.com")
        );
        assert_eq!(requests[0].version(), reqwest::Version::HTTP_2);
        assert_eq!(
            requests[0].headers()["apns-collapse-id"],
            approval.approval_id()
        );
        assert_eq!(requests[0].headers()["apns-topic"], "build.agora.astation");
        assert_eq!(requests[0].headers()["apns-expiration"], "985");
        assert_eq!(requests[0].headers()["apns-push-type"], "alert");
        assert_eq!(requests[0].headers()["apns-priority"], "10");
        assert_eq!(requests[1].headers()["apns-push-type"], "background");
        assert_eq!(requests[1].headers()["apns-priority"], "5");
        assert_eq!(
            requests[0].headers()["authorization"],
            requests[2].headers()["authorization"]
        );
    }

    #[test]
    fn sealed_tool_and_summary_never_enter_notification_payloads_in_plaintext() {
        let approval = notice();
        for payload in [approval.apns_payload(), approval.fcm_payload("device-token", 900)] {
            let bytes = payload.to_string();
            assert!(!bytes.contains("npm test"));
            assert!(!bytes.contains("Bash"));
            assert!(bytes.len() <= 4096);
        }
        let envelope: Value = serde_json::from_str(approval.apns_payload()["r9_hint"].as_str().unwrap()).unwrap();
        assert_eq!(envelope, approval.0.object().to_json());
    }

    #[tokio::test]
    async fn wrong_recipient_and_oversized_provider_wrapper_never_reach_transport() {
        let (delivery, transport, _) = fcm_delivery(vec![]);
        let mut token = fcm_token();
        token.device_id = "other".into();
        assert_eq!(delivery.send_at(&token, &notice(), 900).await, PushDeliveryResult::Rejected);
        assert!(transport.requests.lock().unwrap().is_empty());

        // Individually valid fields still must fit the whole provider budget,
        // including the address, signed envelope and provider wrapper.
        let large = notice();
        let (delivery, transport, _) = fcm_delivery(vec![ProviderResponse {
            status:200, body:json!({"access_token":"synthetic-oauth", "expires_in":3600})
        }]);
        token = fcm_token();
        token.registration.token = "t".repeat(4096);
        assert!(token.registration.valid());
        assert!(large.fcm_payload(&token.registration.token, 900).to_string().len() > 4096);
        assert_eq!(delivery.send_at(&token, &large, 900).await, PushDeliveryResult::Rejected);
        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].url().host_str(), Some("oauth2.googleapis.com"));
    }

    #[test]
    fn notification_payloads_preserve_collapse_identity_and_resolution_is_data_only() {
        let approval = notice();
        assert!(approval.valid());
        let apns = approval.apns_payload();
        assert_eq!(apns["aps"]["mutable-content"], 1);
        assert_eq!(apns["aps"]["alert"]["body"], "Open Astation to review this request.");
        let fcm = approval.fcm_payload("device-token", 900);
        assert_eq!(
            fcm["message"]["android"]["notification"]["tag"],
            approval.approval_id()
        );
        assert_eq!(fcm["message"]["android"]["ttl"], "85s");
        assert!(fcm["message"]["data"]
            .as_object()
            .unwrap()
            .values()
            .all(Value::is_string));
        let resolved = resolution();
        assert_eq!(
            resolved.apns_payload()["aps"],
            json!({"content-available":1})
        );
        assert!(resolved.fcm_payload("device-token", 900)["message"]
            .get("notification")
            .is_none());
    }

    #[test]
    fn provider_failures_only_invalidate_specific_unregistered_tokens() {
        assert_eq!(
            classify_rejection(
                PushPlatform::Fcm,
                400,
                &json!({"error":{"status":"INVALID_ARGUMENT"}})
            ),
            PushDeliveryResult::Rejected
        );
        assert_eq!(
            classify_rejection(
                PushPlatform::Fcm,
                404,
                &json!({"error":{"details":[{
            "@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode":"UNREGISTERED"}]}})
            ),
            PushDeliveryResult::InvalidToken
        );
        assert_eq!(
            classify_rejection(
                PushPlatform::ApnsSandbox,
                410,
                &json!({"reason":"Unregistered"})
            ),
            PushDeliveryResult::InvalidToken
        );
    }

    #[test]
    fn apns_uses_a_verifiable_fixed_width_es256_signature() {
        let random = SystemRandom::new();
        let document = signature::EcdsaKeyPair::generate_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &random,
        )
        .unwrap();
        let key = signature::EcdsaKeyPair::from_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            document.as_ref(),
            &random,
        )
        .unwrap();
        let public = key.public_key().as_ref().to_vec();
        let delivery = PushDelivery {
            http: reqwest::Client::new(),
            apns: Some(ApnsCredentials {
                key,
                key_id: "0123456789".into(),
                team_id: "9876543210".into(),
                topic: "build.agora.astation".into(),
            }),
            fcm: None,
            transport: std::sync::Arc::new(HttpPushTransport(reqwest::Client::new())),
            apns_access_token: std::sync::Mutex::new(None),
            fcm_access_token: Mutex::new(None),
        };
        let jwt = delivery.apns_bearer(900).unwrap();
        assert_eq!(delivery.apns_bearer(901).unwrap(), jwt);
        let parts: Vec<_> = jwt.split('.').collect();
        let input = format!("{}.{}", parts[0], parts[1]);
        signature::UnparsedPublicKey::new(&signature::ECDSA_P256_SHA256_FIXED, public)
            .verify(input.as_bytes(), &URL_SAFE_NO_PAD.decode(parts[2]).unwrap())
            .unwrap();
    }
}
