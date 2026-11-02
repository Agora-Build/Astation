//! Login authenticates storage visibility; it never establishes device trust.
use async_trait::async_trait;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ring::signature::{UnparsedPublicKey, ECDSA_P256_SHA256_FIXED};
use serde::Deserialize;
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;

use crate::account_store::{AccountIdentityVerifier, VerifyError};

pub const LEGACY_ISSUER: &str = "legacy:agora";
pub(crate) const BUILT_IN_STATION_ORIGIN: &str = "https://station.agora.build";
const MAX_DOCUMENT: usize = 64 * 1024;
const CACHE_TTL: Duration = Duration::from_secs(60);
const MAX_CACHE_AGE: Duration = Duration::from_secs(60 * 60);
const REFRESH_COOLDOWN: Duration = Duration::from_secs(5);

#[derive(Clone, Debug)]
pub struct VerifiedIdentity {
    pub issuer: String,
    pub subject: String,
    pub authenticated_at: Option<i64>,
}

pub struct UnavailableVerifier(pub String);

#[async_trait]
impl AccountIdentityVerifier for UnavailableVerifier {
    async fn verify(&self, _: &str) -> Result<VerifiedIdentity, VerifyError> {
        Err(VerifyError::Unavailable(self.0.clone()))
    }
}

pub fn configured_verifier() -> Arc<dyn AccountIdentityVerifier> {
    let get = |key| std::env::var(key).ok().filter(|v| !v.trim().is_empty());
    let issuer = get("ACCOUNT_OIDC_ISSUER");
    let audience = get("ACCOUNT_OIDC_AUDIENCE");
    let scope = get("ACCOUNT_OIDC_REQUIRED_SCOPE");
    let public_origin = get("PUBLIC_BASE_URL");
    verifier_from_configuration(
        issuer.as_deref(),
        audience.as_deref(),
        scope.as_deref(),
        public_origin.as_deref(),
    )
}

fn verifier_from_configuration(
    issuer: Option<&str>,
    audience: Option<&str>,
    scope: Option<&str>,
    public_origin: Option<&str>,
) -> Arc<dyn AccountIdentityVerifier> {
    let (Some(issuer), Some(audience), Some(scope)) = (issuer, audience, scope) else {
        return Arc::new(UnavailableVerifier("configure ACCOUNT_OIDC_ISSUER, ACCOUNT_OIDC_AUDIENCE and ACCOUNT_OIDC_REQUIRED_SCOPE together".into()));
    };
    if public_origin.is_some_and(|origin| origin != audience) {
        return Arc::new(UnavailableVerifier(
            "ACCOUNT_OIDC_AUDIENCE must equal PUBLIC_BASE_URL exactly".into(),
        ));
    }
    match OidcVerifier::new(issuer, audience, scope) {
        Ok(verifier) => Arc::new(verifier),
        Err(_) => Arc::new(UnavailableVerifier(
            "invalid account OIDC configuration".into(),
        )),
    }
}

#[derive(Default)]
struct Cache {
    keys: HashMap<String, Vec<u8>>,
    fetched: Option<Instant>,
    attempted: Option<Instant>,
    last_failed: bool,
    #[cfg(test)]
    offline: bool,
}

pub struct OidcVerifier {
    issuer: url::Url,
    issuer_name: String,
    audience: String,
    scope: String,
    http: reqwest::Client,
    cache: Mutex<Cache>,
    now: Arc<dyn Fn() -> i64 + Send + Sync>,
}

#[derive(Deserialize)]
struct Discovery {
    issuer: String,
    jwks_uri: String,
}
#[derive(Deserialize)]
struct KeySet {
    keys: Vec<Jwk>,
}
#[derive(Deserialize)]
struct Jwk {
    kid: Option<String>,
    kty: String,
    crv: Option<String>,
    x: Option<String>,
    y: Option<String>,
    alg: Option<String>,
    r#use: Option<String>,
    key_ops: Option<Vec<String>>,
    #[serde(default, deserialize_with = "present")]
    d: bool,
}
#[derive(Deserialize)]
struct Header {
    alg: String,
    typ: String,
    kid: String,
    #[serde(default, deserialize_with = "present")]
    crit: bool,
}

fn present<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<bool, D::Error> {
    let _ = serde::de::IgnoredAny::deserialize(deserializer)?;
    Ok(true)
}
#[derive(Deserialize)]
#[serde(untagged)]
enum Audience {
    One(String),
    Many(Vec<String>),
}
impl Audience {
    fn matches(&self, expected: &str) -> bool {
        match self {
            Self::One(s) => s == expected,
            Self::Many(v) => v.iter().any(|value| value == expected),
        }
    }
}
#[derive(Deserialize)]
struct Claims {
    iss: String,
    sub: String,
    aud: Audience,
    exp: i64,
    iat: i64,
    scope: Option<String>,
    client_id: String,
    nbf: Option<i64>,
    auth_time: Option<i64>,
    r9_svc: Option<String>,
    sid: Option<String>,
}

/// Signature-verified claims only; a current Station binding and R9 admission
/// are still required before dispatch. Never retain the bearer token here.
pub(crate) struct VerifiedServiceToken {
    pub identity: VerifiedIdentity,
    pub client_id: String,
    pub service_fingerprint: String,
    pub scopes: Vec<String>,
    pub expires_at: i64,
}

pub(crate) struct VerifiedAccessToken {
    pub identity: VerifiedIdentity,
    pub client_id: String,
    pub scopes: Vec<String>,
    pub service_fingerprint: Option<String>,
    pub expires_at: i64,
    pub session_id: Option<String>,
}

pub(crate) fn service_key_fingerprint(alg: &str, public_key: &[u8]) -> Result<String, VerifyError> {
    let alg = match alg {
        "p256" => atem_client::keys::Alg::P256,
        "ed25519" => atem_client::keys::Alg::Ed25519,
        _ => return Err(VerifyError::Rejected),
    };
    let key =
        atem_client::keys::PublicKey::new(alg, public_key).map_err(|_| VerifyError::Rejected)?;
    atem_client::membership::service_key_fingerprint(&key).map_err(|_| VerifyError::Rejected)
}

fn integration_id(value: &str) -> bool {
    value.strip_prefix("i-").is_some_and(|id| {
        id.len() == 26
            && id
                .bytes()
                .all(|b| b"0123456789abcdefghjkmnpqrstvwxyz".contains(&b))
    })
}

fn unavailable() -> VerifyError {
    VerifyError::Unavailable("account signing keys are unavailable; retry later".into())
}
fn safe_url(value: &str) -> Result<url::Url, VerifyError> {
    let url = url::Url::parse(value).map_err(|_| VerifyError::InvalidResponse)?;
    let loopback = matches!(url.host_str(), Some("127.0.0.1" | "[::1]" | "localhost"))
        || url
            .host_str()
            .is_some_and(|host| host.ends_with(".localhost"));
    if !(url.scheme() == "https" || url.scheme() == "http" && loopback)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(VerifyError::InvalidResponse);
    }
    Ok(url)
}
fn decoded(value: &str) -> Result<Vec<u8>, VerifyError> {
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| VerifyError::Rejected)?;
    if URL_SAFE_NO_PAD.encode(&bytes) != value {
        return Err(VerifyError::Rejected);
    }
    Ok(bytes)
}

fn scope_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| matches!(b, 0x21 | 0x23..=0x5b | 0x5d..=0x7e))
}

pub(crate) fn station_origin(value: &str) -> bool {
    safe_url(value).is_ok_and(|url| url.origin().ascii_serialization() == value)
}

pub(crate) fn integration_station_origin(value: &str) -> bool {
    station_origin(value)
        && url::Url::parse(value).is_ok_and(|url| {
            url.scheme() == "https"
                && url.port() != Some(0)
                && matches!(url.host(), Some(url::Host::Domain(host)) if host.contains('.')
                && !host.ends_with('.'))
        })
}

pub(crate) fn configured_integration_origin(
    public_origin: Option<&str>,
    audience: &str,
) -> Result<String, ()> {
    let origin = public_origin.unwrap_or(BUILT_IN_STATION_ORIGIN);
    if origin != audience || !integration_station_origin(origin) {
        return Err(());
    }
    Ok(origin.into())
}

impl OidcVerifier {
    pub fn new(issuer: &str, audience: &str, scope: &str) -> Result<Self, VerifyError> {
        let url = safe_url(issuer)?;
        if url.as_str().trim_end_matches('/') != issuer.trim_end_matches('/')
            || audience.len() > 512
            || !station_origin(audience)
            || !scope_token(scope)
        {
            return Err(VerifyError::InvalidResponse);
        }
        Ok(Self {
            issuer: url,
            issuer_name: issuer.into(),
            audience: audience.into(),
            scope: scope.into(),
            http: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(5))
                .build()
                .map_err(|_| unavailable())?,
            cache: Mutex::new(Cache::default()),
            now: Arc::new(|| chrono::Utc::now().timestamp()),
        })
    }

    async fn document<T: serde::de::DeserializeOwned>(
        &self,
        url: url::Url,
    ) -> Result<T, VerifyError> {
        let mut response = self.http.get(url).send().await.map_err(|_| unavailable())?;
        if !response.status().is_success()
            || response
                .content_length()
                .is_some_and(|n| n > MAX_DOCUMENT as u64)
        {
            return Err(unavailable());
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| unavailable())? {
            if body.len() + chunk.len() > MAX_DOCUMENT {
                return Err(unavailable());
            }
            body.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&body).map_err(|_| unavailable())
    }

    async fn key(&self, kid: &str) -> Result<Vec<u8>, VerifyError> {
        let mut cache = self.cache.lock().await;
        #[cfg(test)]
        if cache.offline {
            return cache.keys.get(kid).cloned().ok_or(VerifyError::Rejected);
        }
        let now = Instant::now();
        let fresh = cache
            .fetched
            .is_some_and(|at| now.duration_since(at) < CACHE_TTL);
        if fresh {
            if let Some(key) = cache.keys.get(kid) {
                return Ok(key.clone());
            }
        }
        if cache
            .attempted
            .is_some_and(|at| now.duration_since(at) < REFRESH_COOLDOWN)
        {
            return cached_key(&cache, kid).ok_or_else(|| {
                if cache.last_failed || cache.fetched.is_none() {
                    unavailable()
                } else {
                    VerifyError::Rejected
                }
            });
        }
        let result = self.fetch_keys().await;
        // Backoff starts when the fetch finishes, including after a timeout.
        cache.attempted = Some(Instant::now());
        match result {
            Ok(keys) => {
                // A successful replacement, even an empty set, removes old keys.
                cache.keys = keys;
                cache.fetched = Some(Instant::now());
                cache.last_failed = false;
                cache.keys.get(kid).cloned().ok_or(VerifyError::Rejected)
            }
            Err(error) => {
                cache.last_failed = true;
                cached_key(&cache, kid).ok_or(error)
            }
        }
    }

    async fn fetch_keys(&self) -> Result<HashMap<String, Vec<u8>>, VerifyError> {
        let discovery_url = format!(
            "{}/.well-known/openid-configuration",
            self.issuer.as_str().trim_end_matches('/')
        );
        let discovery: Discovery = self.document(safe_url(&discovery_url)?).await?;
        if discovery.issuer != self.issuer_name {
            return Err(unavailable());
        }
        let jwks = safe_url(&discovery.jwks_uri).map_err(|_| unavailable())?;
        if jwks.origin() != self.issuer.origin() {
            return Err(unavailable());
        }
        let set: KeySet = self.document(jwks).await?;
        Self::parse_keys(set)
    }

    fn parse_keys(set: KeySet) -> Result<HashMap<String, Vec<u8>>, VerifyError> {
        if set.keys.len() > 64 {
            return Err(unavailable());
        }
        let mut keys = HashMap::new();
        for key in set.keys {
            if key.kty != "EC"
                || key.crv.as_deref() != Some("P-256")
                || key.alg.as_deref().is_some_and(|alg| alg != "ES256")
                || key.r#use.as_deref().is_some_and(|u| u != "sig")
                || key.d
                || key
                    .key_ops
                    .as_ref()
                    .is_some_and(|ops| !ops.iter().any(|op| op == "verify"))
            {
                continue;
            }
            let (Some(kid), Some(x), Some(y)) = (key.kid, key.x, key.y) else {
                return Err(unavailable());
            };
            if kid.is_empty() || kid.len() > 128 {
                return Err(unavailable());
            }
            let x = decoded(&x).map_err(|_| unavailable())?;
            let y = decoded(&y).map_err(|_| unavailable())?;
            if x.len() != 32 || y.len() != 32 {
                return Err(unavailable());
            }
            let mut raw = vec![4];
            raw.extend(x);
            raw.extend(y);
            if keys.insert(kid, raw).is_some() {
                return Err(unavailable());
            }
        }
        Ok(keys)
    }

    async fn verify_claims(&self, token: &str) -> Result<Claims, VerifyError> {
        if token.len() > 8192 {
            return Err(VerifyError::Rejected);
        }
        let pieces: Vec<_> = token.split('.').collect();
        if pieces.len() != 3 {
            return Err(VerifyError::Rejected);
        }
        let header: Header =
            serde_json::from_slice(&decoded(pieces[0])?).map_err(|_| VerifyError::Rejected)?;
        if header.alg != "ES256"
            || !(header.typ.eq_ignore_ascii_case("at+jwt")
                || header.typ.eq_ignore_ascii_case("application/at+jwt"))
            || header.kid.is_empty()
            || header.kid.len() > 128
            || header.crit
        {
            return Err(VerifyError::Rejected);
        }
        let signature = decoded(pieces[2])?;
        if signature.len() != 64 {
            return Err(VerifyError::Rejected);
        }
        let claims: Claims =
            serde_json::from_slice(&decoded(pieces[1])?).map_err(|_| VerifyError::Rejected)?;
        let key = self.key(&header.kid).await?;
        let signed = format!("{}.{}", pieces[0], pieces[1]);
        UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, key)
            .verify(signed.as_bytes(), &signature)
            .map_err(|_| VerifyError::Rejected)?;
        // Validate time after discovery/key retrieval, using Auth's 60 s skew.
        let now = (self.now)();
        let max_lifetime = if claims.client_id.starts_with("i-") {
            300
        } else {
            900
        };
        if claims.iss != self.issuer_name
            || !claims.aud.matches(&self.audience)
            || claims.exp < now.saturating_sub(60)
            || claims.iat > now.saturating_add(60)
            || claims.iat < 0
            || claims.exp <= claims.iat
            || claims.exp.saturating_sub(claims.iat) > max_lifetime
            || claims
                .nbf
                .is_some_and(|nbf| nbf < 0 || nbf > now.saturating_add(60))
            || claims
                .auth_time
                .is_some_and(|at| at < 0 || at > claims.iat.saturating_add(60))
            || !claims.sub.starts_with("ab")
            || claims.sub.len() != 28
            || !claims.sub[2..]
                .bytes()
                .all(|b| b"0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(&b))
            || claims.client_id.is_empty()
            || claims.client_id.len() > 128
            || claims.client_id.chars().any(char::is_control)
        {
            return Err(VerifyError::Rejected);
        }
        Ok(claims)
    }

    pub(crate) async fn verify_station(
        &self,
        token: &str,
        scope: Option<&str>,
        service_fingerprint: Option<&str>,
    ) -> Result<VerifiedAccessToken, VerifyError> {
        let claims = self.verify_claims(token).await?;
        if claims.client_id.starts_with("i-")
            && (!integration_id(&claims.client_id)
                || !claims.r9_svc.as_deref().is_some_and(|value| {
                    value.len() == 64
                        && value
                            .bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                        && Some(value) == service_fingerprint
                }))
        {
            return Err(VerifyError::Rejected);
        }
        let scopes: Vec<String> = claims
            .scope
            .unwrap_or_default()
            .split(' ')
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect();
        if scope.is_some_and(|required| {
            !scope_token(required) || !scopes.iter().any(|value| value == required)
        }) {
            return Err(VerifyError::InsufficientScope);
        }
        Ok(VerifiedAccessToken {
            identity: VerifiedIdentity {
                issuer: claims.iss,
                subject: claims.sub,
                authenticated_at: claims.auth_time,
            },
            client_id: claims.client_id,
            scopes,
            service_fingerprint: claims.r9_svc,
            expires_at: claims.exp,
            session_id: claims.sid,
        })
    }

    pub(crate) async fn verify_integration(
        &self,
        token: &str,
        scope: &str,
        service_fingerprint: &str,
    ) -> Result<VerifiedServiceToken, VerifyError> {
        let verified = self
            .verify_station(token, Some(scope), Some(service_fingerprint))
            .await?;
        if !integration_id(&verified.client_id) || verified.session_id.is_some() {
            return Err(VerifyError::Rejected);
        }
        Ok(VerifiedServiceToken {
            identity: VerifiedIdentity {
                authenticated_at: None,
                ..verified.identity
            },
            client_id: verified.client_id,
            service_fingerprint: verified.service_fingerprint.ok_or(VerifyError::Rejected)?,
            scopes: verified.scopes,
            expires_at: verified.expires_at,
        })
    }
}

fn cached_key(cache: &Cache, kid: &str) -> Option<Vec<u8>> {
    cache.fetched.filter(|at| at.elapsed() < MAX_CACHE_AGE)?;
    cache.keys.get(kid).cloned()
}

#[async_trait]
impl AccountIdentityVerifier for OidcVerifier {
    async fn verify(&self, token: &str) -> Result<VerifiedIdentity, VerifyError> {
        let verified = self.verify_station(token, Some(&self.scope), None).await?;
        if verified.client_id.starts_with("i-") || verified.session_id.is_some() {
            return Err(VerifyError::Rejected);
        }
        Ok(verified.identity)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use axum::{
        extract::State, http::StatusCode, response::IntoResponse, routing::get, Json, Router,
    };
    use ring::{
        rand::SystemRandom,
        signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING},
    };
    use serde_json::{json, Value};
    use std::sync::atomic::{AtomicU16, AtomicU64, AtomicUsize, Ordering};

    struct Server {
        document: Mutex<Value>,
        jwks: Mutex<Value>,
        gets: AtomicUsize,
        status: AtomicU16,
        delay_ms: AtomicU64,
    }
    pub(crate) struct Fixture {
        pub issuer: String,
        state: Arc<Server>,
        signer: EcdsaKeyPair,
        verifier: OidcVerifier,
        task: tokio::task::JoinHandle<()>,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.task.abort();
        }
    }
    fn signer() -> EcdsaKeyPair {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap()
    }
    fn jwks(key: &EcdsaKeyPair, kid: &str) -> Value {
        let raw = key.public_key().as_ref();
        json!({"keys":[{"kty":"EC","crv":"P-256","alg":"ES256","use":"sig","kid":kid,
            "x":URL_SAFE_NO_PAD.encode(&raw[1..33]),"y":URL_SAFE_NO_PAD.encode(&raw[33..65])}]})
    }
    impl Fixture {
        pub(crate) async fn new() -> Self {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let issuer = format!("http://{}", listener.local_addr().unwrap());
            let signer = signer();
            let state = Arc::new(Server {
                document: Mutex::new(json!({"issuer":issuer,"jwks_uri":format!("{issuer}/keys")})),
                jwks: Mutex::new(jwks(&signer, "one")),
                gets: AtomicUsize::new(0),
                status: AtomicU16::new(200),
                delay_ms: AtomicU64::new(0),
            });
            let router = Router::new()
                .route(
                    "/.well-known/openid-configuration",
                    get(|State(s): State<Arc<Server>>| async move {
                        Json(s.document.lock().await.clone())
                    }),
                )
                .route(
                    "/keys",
                    get(|State(s): State<Arc<Server>>| async move {
                        s.gets.fetch_add(1, Ordering::SeqCst);
                        tokio::time::sleep(Duration::from_millis(
                            s.delay_ms.load(Ordering::SeqCst),
                        ))
                        .await;
                        (
                            StatusCode::from_u16(s.status.load(Ordering::SeqCst)).unwrap(),
                            Json(s.jwks.lock().await.clone()),
                        )
                            .into_response()
                    }),
                )
                .with_state(state.clone());
            let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
            let verifier =
                OidcVerifier::new(&issuer, "https://station.example", "station:account").unwrap();
            Self {
                issuer,
                signer,
                state,
                verifier,
                task,
            }
        }
        pub(crate) fn claims(&self) -> Value {
            let now = chrono::Utc::now().timestamp();
            json!({"iss":self.issuer,"sub":"ab01234567890123456789012345","aud":"https://station.example",
                "exp":now+900,"iat":now,"client_id":"astation","scope":"openid station:account"})
        }
        pub(crate) fn token(&self, header: Value, claims: Value) -> String {
            self.signed(
                &serde_json::to_string(&header).unwrap(),
                &serde_json::to_string(&claims).unwrap(),
            )
        }
        fn signed(&self, header: &str, claims: &str) -> String {
            let message = format!(
                "{}.{}",
                URL_SAFE_NO_PAD.encode(header),
                URL_SAFE_NO_PAD.encode(claims)
            );
            let signature = self
                .signer
                .sign(&SystemRandom::new(), message.as_bytes())
                .unwrap();
            format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref()))
        }
        pub(crate) fn header(&self) -> Value {
            json!({"alg":"ES256","typ":"at+jwt","kid":"one"})
        }
        async fn allow_refresh(&self, expired: bool) {
            let mut cache = self.verifier.cache.lock().await;
            cache.attempted = Some(Instant::now() - REFRESH_COOLDOWN - Duration::from_secs(1));
            if expired {
                cache.fetched = Some(Instant::now() - MAX_CACHE_AGE - Duration::from_secs(1));
            }
        }
    }

    #[tokio::test]
    async fn signed_access_tokens_enforce_issuer_audience_type_scope_and_lifetime() {
        let f = Fixture::new().await;
        let token = f.token(f.header(), f.claims());
        let identity = f.verifier.verify(&token).await.unwrap();
        assert_eq!(identity.issuer, f.issuer);
        assert_eq!(identity.subject, "ab01234567890123456789012345");
        assert_eq!(identity.authenticated_at, None); // iat is never fresh-authentication proof.
        for (field, value) in [
            ("iss", json!("https://evil.example")),
            ("aud", json!("different-api")),
            ("sub", json!("email@example.com")),
            ("sub", json!("acct_01234567890123456789012345")),
            ("sub", json!("ab0123456789012345678901234I")),
            ("sub", json!("ab0123456789012345678901234a")),
            ("scope", json!("openid station:account-extra")),
            ("exp", json!(chrono::Utc::now().timestamp() - 61)),
            ("iat", json!(chrono::Utc::now().timestamp() + 61)),
            ("exp", json!(chrono::Utc::now().timestamp() + 3600)),
            ("nbf", json!(chrono::Utc::now().timestamp() + 61)),
            ("iat", json!(true)),
            ("client_id", json!("")),
        ] {
            let mut claims = f.claims();
            claims[field] = value;
            assert!(
                matches!(
                    f.verifier.verify(&f.token(f.header(), claims)).await,
                    Err(VerifyError::Rejected | VerifyError::InsufficientScope)
                ),
                "{field}"
            );
        }
        for (field, value) in [
            ("typ", json!("JWT")),
            ("alg", json!("none")),
            ("crit", json!([])),
        ] {
            let mut header = f.header();
            header[field] = value;
            assert!(matches!(
                f.verifier.verify(&f.token(header, f.claims())).await,
                Err(VerifyError::Rejected)
            ));
        }
        let other = Fixture::new().await;
        assert!(matches!(
            f.verifier
                .verify(&other.token(f.header(), f.claims()))
                .await,
            Err(VerifyError::Rejected)
        ));
        let claims = serde_json::to_string(&f.claims()).unwrap();
        let duplicate = format!("{{\"iss\":\"{}\",{}", f.issuer, &claims[1..]);
        assert!(matches!(
            f.verifier
                .verify(&f.signed(&f.header().to_string(), &duplicate))
                .await,
            Err(VerifyError::Rejected)
        ));
        assert_eq!(f.state.gets.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn rotation_is_bounded_and_expired_cache_never_survives_an_outage() {
        let f = Fixture::new().await;
        let original = f.token(f.header(), f.claims());
        f.verifier.verify(&original).await.unwrap();
        let mut next_header = f.header();
        next_header["kid"] = json!("two");
        let next = f.token(next_header, f.claims());
        assert!(matches!(
            f.verifier.verify(&next).await,
            Err(VerifyError::Rejected)
        ));
        assert_eq!(f.state.gets.load(Ordering::SeqCst), 1);
        *f.state.jwks.lock().await = jwks(&f.signer, "two");
        f.allow_refresh(false).await;
        f.verifier.verify(&next).await.unwrap();
        assert_eq!(f.state.gets.load(Ordering::SeqCst), 2);
        f.state.status.store(503, Ordering::SeqCst);
        f.verifier.verify(&next).await.unwrap();
        f.allow_refresh(true).await;
        assert!(matches!(
            f.verifier.verify(&next).await,
            Err(VerifyError::Unavailable(_))
        ));
        assert!(matches!(
            f.verifier.verify(&original).await,
            Err(VerifyError::Unavailable(_))
        ));
        assert_eq!(f.state.gets.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn known_keys_survive_bounded_outages_without_extending_token_expiry() {
        let f = Fixture::new().await;
        let token = f.token(f.header(), f.claims());
        f.verifier.verify(&token).await.unwrap();
        f.state.status.store(503, Ordering::SeqCst);
        {
            let mut cache = f.verifier.cache.lock().await;
            cache.fetched = Some(Instant::now() - Duration::from_secs(3590));
            cache.attempted = None;
        }
        f.verifier.verify(&token).await.unwrap();
        let fetched = f.verifier.cache.lock().await.fetched;
        f.verifier.verify(&token).await.unwrap();
        assert_eq!(f.verifier.cache.lock().await.fetched, fetched);
        assert_eq!(f.state.gets.load(Ordering::SeqCst), 2);
        let mut expired = f.claims();
        expired["exp"] = json!(chrono::Utc::now().timestamp() - 61);
        assert!(matches!(
            f.verifier.verify(&f.token(f.header(), expired)).await,
            Err(VerifyError::Rejected)
        ));
        f.allow_refresh(true).await;
        assert!(matches!(
            f.verifier.verify(&token).await,
            Err(VerifyError::Unavailable(_))
        ));
    }

    #[tokio::test]
    async fn successful_jwks_removal_never_falls_back_to_the_removed_key() {
        let f = Fixture::new().await;
        let token = f.token(f.header(), f.claims());
        f.verifier.verify(&token).await.unwrap();
        *f.state.jwks.lock().await = json!({"keys":[]});
        {
            let mut cache = f.verifier.cache.lock().await;
            cache.fetched = Some(Instant::now() - CACHE_TTL);
            cache.attempted = None;
        }
        assert!(matches!(
            f.verifier.verify(&token).await,
            Err(VerifyError::Rejected)
        ));
        f.state.status.store(503, Ordering::SeqCst);
        f.allow_refresh(false).await;
        assert!(f.verifier.verify(&token).await.is_err());
    }

    #[tokio::test]
    async fn unknown_key_flood_has_a_shared_refresh_budget_and_no_unbounded_negative_cache() {
        let f = Fixture::new().await;
        f.verifier
            .verify(&f.token(f.header(), f.claims()))
            .await
            .unwrap();
        f.state.status.store(503, Ordering::SeqCst);
        f.allow_refresh(false).await;
        let attempts = (0..50).map(|i| {
            let mut header = f.header();
            header["kid"] = json!(format!("unknown-{i}"));
            let token = f.token(header, f.claims());
            let verifier = &f.verifier;
            async move { verifier.verify(&token).await }
        });
        for result in futures_util::future::join_all(attempts).await {
            assert!(result.is_err());
        }
        assert_eq!(f.state.gets.load(Ordering::SeqCst), 2);
        assert_eq!(f.verifier.cache.lock().await.keys.len(), 1);
    }

    #[tokio::test]
    async fn unknown_key_after_failed_refresh_is_503_even_with_a_fresh_cached_set() {
        let f = Fixture::new().await;
        let token = f.token(f.header(), f.claims());
        f.verifier.verify(&token).await.unwrap();
        f.state.status.store(503, Ordering::SeqCst);
        f.allow_refresh(false).await;
        let mut header = f.header();
        header["kid"] = json!("rotated");
        let unknown = f.token(header, f.claims());
        for _ in 0..3 {
            assert!(matches!(
                f.verifier.verify(&unknown).await,
                Err(VerifyError::Unavailable(_))
            ));
        }
        f.verifier.verify(&token).await.unwrap();
        assert_eq!(f.state.gets.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn expiration_during_key_retrieval_is_rejected() {
        let f = Fixture::new().await;
        f.state.delay_ms.store(2100, Ordering::SeqCst);
        let mut claims = f.claims();
        claims["iat"] = json!(chrono::Utc::now().timestamp() - 100);
        claims["exp"] = json!(chrono::Utc::now().timestamp() - 59);
        assert!(matches!(
            f.verifier.verify(&f.token(f.header(), claims)).await,
            Err(VerifyError::Rejected)
        ));
        assert_eq!(f.state.gets.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn incomplete_or_cross_resource_configuration_has_no_legacy_fallback() {
        for (issuer, audience, scope, origin) in [
            (None, None, None, None),
            (
                Some("https://auth.agora.build"),
                None,
                Some("astation.remote"),
                None,
            ),
            (
                Some("https://auth.agora.build"),
                Some("https://station.agora.build"),
                None,
                None,
            ),
            (
                Some("https://auth.agora.build"),
                Some("https://agora.build"),
                Some("astation.remote"),
                Some("https://station.agora.build"),
            ),
            (
                Some("http://auth.example"),
                Some("https://station.agora.build"),
                Some("astation.remote"),
                None,
            ),
        ] {
            let verifier = verifier_from_configuration(issuer, audience, scope, origin);
            assert!(matches!(
                verifier.verify("legacy-or-opaque-token").await,
                Err(VerifyError::Unavailable(_))
            ));
        }
    }

    #[tokio::test]
    async fn outage_cannot_extend_cache_age_while_key_fetch_is_in_flight() {
        let f = Fixture::new().await;
        let token = f.token(f.header(), f.claims());
        f.verifier.verify(&token).await.unwrap();
        {
            let mut cache = f.verifier.cache.lock().await;
            cache.fetched = Some(Instant::now() - MAX_CACHE_AGE + Duration::from_millis(500));
            cache.attempted = None;
        }
        f.state.delay_ms.store(1100, Ordering::SeqCst);
        f.state.status.store(503, Ordering::SeqCst);
        assert!(matches!(
            f.verifier.verify(&token).await,
            Err(VerifyError::Unavailable(_))
        ));
    }

    #[tokio::test]
    async fn native_and_integration_profiles_are_not_interchangeable() {
        use crate::integration_auth::IntegrationBinding;
        let f = Fixture::new().await;
        let mut claims = f.claims();
        claims["exp"] = json!(chrono::Utc::now().timestamp() + 300);
        claims["scope"] = json!("agent.view agent.prompt");
        claims["client_id"] = json!("i-01234567890123456789012345");
        claims["r9_svc"] = json!("a".repeat(64));
        let binding = IntegrationBinding {
            issuer: f.issuer.clone(),
            owner: claims["sub"].as_str().unwrap().into(),
            client_id: "i-01234567890123456789012345".into(),
            service_fingerprint: "a".repeat(64),
            account_allowed: true,
            active: true,
            expires_at: chrono::Utc::now().timestamp() + 3600,
            scopes: vec!["agent.view".into()],
        };
        let token = f.token(f.header(), claims.clone());
        let verified = binding
            .verify(&f.verifier, &token, "agent.view")
            .await
            .unwrap();
        assert_eq!(verified.identity.authenticated_at, None);
        assert!(binding
            .verify(&f.verifier, &token, "agent.prompt")
            .await
            .is_err());
        assert!(matches!(
            f.verifier.verify(&token).await,
            Err(VerifyError::Rejected)
        ));
        assert!(f
            .verifier
            .verify_integration(
                &f.token(f.header(), f.claims()),
                "station:account",
                &"a".repeat(64)
            )
            .await
            .is_err());
        for (field, value) in [
            ("aud", json!("https://dev.agora.build")),
            (
                "aud",
                json!(["https://other.example", "https://dev.agora.build"]),
            ),
            ("client_id", json!("i-11234567890123456789012345")),
            ("sub", json!("ab98765432109876543210987654")),
            ("r9_svc", json!("b".repeat(64))),
            ("r9_svc", json!(null)),
            ("sid", json!("assistant-session")),
            ("exp", json!(chrono::Utc::now().timestamp() + 301)),
            ("scope", json!("agent.view.extra")),
        ] {
            let mut altered = claims.clone();
            altered[field] = value;
            assert!(
                binding
                    .verify(&f.verifier, &f.token(f.header(), altered), "agent.view")
                    .await
                    .is_err(),
                "{field}"
            );
        }
        // A misleading native scope cannot turn a service token into a login.
        claims["scope"] = json!("station:account agent.view");
        assert!(matches!(
            f.verifier.verify(&f.token(f.header(), claims)).await,
            Err(VerifyError::Rejected)
        ));
        assert_eq!(f.state.gets.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn audience_is_an_exact_canonical_station_origin() {
        let f = Fixture::new().await;
        for audience in [
            "api",
            "https://station.example/",
            "https://station.example/path",
            "https://Station.example",
            "https://station.example:443",
            "https://station.example?x=1",
        ] {
            assert!(
                OidcVerifier::new(&f.issuer, audience, "station:account").is_err(),
                "{audience}"
            );
        }
        for audience in [
            json!("https://station.example/"),
            json!(["https://other.example", "https://dev.agora.build"]),
        ] {
            let mut claims = f.claims();
            claims["aud"] = audience;
            assert!(matches!(
                f.verifier.verify(&f.token(f.header(), claims)).await,
                Err(VerifyError::Rejected)
            ));
        }
        let mut claims = f.claims();
        claims["aud"] = json!(["https://station.example", "https://dev.agora.build"]);
        f.verifier
            .verify(&f.token(f.header(), claims))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn auth_pinned_station_contract_vectors() {
        let vectors: Value =
            serde_json::from_str(include_str!("../tests/fixtures/auth-station-tokens.json"))
                .unwrap();
        let mut verifier = OidcVerifier::new(
            vectors["issuer"].as_str().unwrap(),
            vectors["origin"].as_str().unwrap(),
            "astation.remote",
        )
        .unwrap();
        let now = vectors["now"].as_i64().unwrap();
        verifier.now = Arc::new(move || now);
        {
            let mut cache = verifier.cache.lock().await;
            cache.keys =
                OidcVerifier::parse_keys(serde_json::from_value(vectors["jwks"].clone()).unwrap())
                    .unwrap();
            cache.offline = true;
        }
        let cases = vectors["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 42);
        for case in cases {
            let name = case["name"].as_str().unwrap();
            if let Some(key) = case.get("r9Key") {
                let fingerprint = service_key_fingerprint(
                    key["alg"].as_str().unwrap(),
                    &decoded(key["publicKey"].as_str().unwrap()).unwrap(),
                )
                .unwrap();
                assert_eq!(fingerprint, case["r9Svc"].as_str().unwrap(), "{name}");
            }
            let scope = case["scope"].as_str();
            let result = verifier
                .verify_station(
                    case["token"].as_str().unwrap(),
                    scope,
                    case["r9Svc"].as_str(),
                )
                .await;
            if case["expect"] == "ok" {
                let verified = result.unwrap_or_else(|error| panic!("{name}: {error}"));
                assert_eq!(
                    serde_json::json!({"sub": verified.identity.subject,
                    "clientId": verified.client_id, "scopes": verified.scopes}),
                    case["result"],
                    "{name}"
                );
            } else {
                let response = crate::integration_auth::token_error(
                    &result
                        .err()
                        .unwrap_or_else(|| panic!("{name} unexpectedly accepted")),
                    scope.unwrap_or(""),
                );
                assert_eq!(
                    response.status().as_u16(),
                    case["expect"]["status"].as_u64().unwrap() as u16,
                    "{name}"
                );
                let bytes = axum::body::to_bytes(response.into_body(), 4096)
                    .await
                    .unwrap();
                let error: Value = serde_json::from_slice(&bytes).unwrap();
                assert_eq!(error["error"], case["expect"]["error"], "{name}");
            }
        }
    }

    #[tokio::test]
    async fn discovery_cannot_substitute_an_issuer_or_choose_another_key_origin() {
        for document in [
            json!({"issuer":"https://evil.example","jwks_uri":"http://127.0.0.1/keys"}),
            json!({"jwks_uri":"http://169.254.169.254/keys"}),
        ] {
            let f = Fixture::new().await;
            let mut document = document;
            if document.get("issuer").is_none() {
                document["issuer"] = json!(f.issuer);
            }
            *f.state.document.lock().await = document;
            assert!(f
                .verifier
                .verify(&f.token(f.header(), f.claims()))
                .await
                .is_err());
            assert_eq!(f.state.gets.load(Ordering::SeqCst), 0);
        }
        for issuer in [
            "http://auth.example",
            "https://user:password@auth.example",
            "https://auth.example?override=1",
        ] {
            assert!(OidcVerifier::new(issuer, "api", "account").is_err());
        }
    }

    #[tokio::test]
    async fn signed_login_reaches_recovery_http_and_preserves_exact_retry_and_account_isolation() {
        use crate::account_store::{AccountStore, InMemoryAccountStore};
        use atem_client::membership::Entry;
        use axum::http::StatusCode;
        let f = Fixture::new().await;
        let token = f.token(f.header(), f.claims());
        let mut state = crate::tests::test_state();
        let verifier = Arc::new(
            OidcVerifier::new(&f.issuer, "https://station.example", "station:account").unwrap(),
        );
        let accounts = Arc::new(InMemoryAccountStore::with_verifier(
            state.knowledge.clone(),
            state.vault.clone(),
            verifier.clone(),
        ));
        let principal = accounts.verify_access_token(&token).await.unwrap().subject;
        accounts
            .register("dev-mac", &principal, "Mac", 1)
            .await
            .unwrap();
        state.accounts = accounts;
        state.recovery = crate::remote_api::recovery::RecoveryStore::memory();
        let (base, server) = crate::relay::tests::spawn_relay(state).await;
        let vectors: Value = serde_json::from_str(include_str!(
            "remote_api/fixtures/recovery-public-vectors.json"
        ))
        .unwrap();
        let key = ring::signature::Ed25519KeyPair::from_seed_unchecked(&[0x27; 32]).unwrap();
        let mut genesis = vectors["entries"]["E1"].clone();
        genesis["body"]["account_id"] = json!("dev-mac");
        genesis["body"]["member"]["auth_key"] =
            json!({"alg":"ed25519","pub":URL_SAFE_NO_PAD.encode(key.public_key().as_ref())});
        let unsigned = Entry::parse_bytes(&serde_json::to_vec(&genesis).unwrap()).unwrap();
        genesis["sig"] = json!(URL_SAFE_NO_PAD.encode(
            key.sign(unsigned.object().signing_input().as_bytes())
                .as_ref()
        ));
        let signed = Entry::parse_bytes(&serde_json::to_vec(&genesis).unwrap()).unwrap();
        let url = base.replace("ws://", "http://").replace(
            "/ws",
            &format!("/api/remote/v1/logs/{}/entries", signed.hash().to_hex()),
        );
        let client = reqwest::Client::new();
        let body = json!({"entry":genesis,"expected":{"seq":0,"hash":"0".repeat(64)}});
        f.state.status.store(503, Ordering::SeqCst);
        {
            let mut cache = verifier.cache.lock().await;
            cache.fetched = Some(Instant::now() - MAX_CACHE_AGE - Duration::from_secs(1));
            cache.attempted = None;
        }
        assert_eq!(
            client
                .post(&url)
                .bearer_auth(&token)
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
        f.state.status.store(200, Ordering::SeqCst);
        verifier.cache.lock().await.attempted = None;
        for _ in 0..2 {
            let response = client
                .post(&url)
                .bearer_auth(&token)
                .json(&body)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(response.json::<Value>().await.unwrap()["entry"], genesis);
        }
        assert_eq!(
            client
                .get(&url)
                .bearer_auth(&token)
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        let mut other = f.claims();
        other["sub"] = json!("ab98765432109876543210987654");
        assert!(!client
            .get(&url)
            .bearer_auth(f.token(f.header(), other))
            .send()
            .await
            .unwrap()
            .status()
            .is_success());
        let mut wrong = f.claims();
        wrong["aud"] = json!("wrong-api");
        assert_eq!(
            client
                .get(&url)
                .bearer_auth(f.token(f.header(), wrong))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        let mut id_header = f.header();
        id_header["typ"] = json!("JWT");
        assert_eq!(
            client
                .get(&url)
                .bearer_auth(f.token(id_header, f.claims()))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            client
                .get(&url)
                .bearer_auth("opaque-agora-service-token")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        let evil = Fixture::new().await;
        assert_eq!(
            client
                .get(&url)
                .bearer_auth(evil.token(f.header(), f.claims()))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        server.abort();
    }
}
