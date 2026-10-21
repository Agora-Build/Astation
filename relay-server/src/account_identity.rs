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
const MAX_DOCUMENT: usize = 64 * 1024;
const CACHE_TTL: Duration = Duration::from_secs(60);
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

pub fn configured_verifier(
    legacy: impl FnOnce() -> Arc<dyn AccountIdentityVerifier>,
) -> Arc<dyn AccountIdentityVerifier> {
    let get = |key| std::env::var(key).ok().filter(|v| !v.trim().is_empty());
    let issuer = get("ACCOUNT_OIDC_ISSUER");
    let audience = get("ACCOUNT_OIDC_AUDIENCE");
    let scope = get("ACCOUNT_OIDC_REQUIRED_SCOPE");
    if ![
        "ACCOUNT_OIDC_ISSUER",
        "ACCOUNT_OIDC_AUDIENCE",
        "ACCOUNT_OIDC_REQUIRED_SCOPE",
    ]
    .iter()
    .any(|key| std::env::var_os(key).is_some())
    {
        return legacy();
    }
    let (Some(issuer), Some(audience), Some(scope)) = (issuer, audience, scope) else {
        return Arc::new(UnavailableVerifier("configure ACCOUNT_OIDC_ISSUER, ACCOUNT_OIDC_AUDIENCE and ACCOUNT_OIDC_REQUIRED_SCOPE together".into()));
    };
    match OidcVerifier::new(&issuer, &audience, &scope) {
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
}

pub struct OidcVerifier {
    issuer: url::Url,
    issuer_name: String,
    audience: String,
    scope: String,
    http: reqwest::Client,
    cache: Mutex<Cache>,
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
}
#[derive(Deserialize)]
struct Header {
    alg: String,
    typ: String,
    kid: String,
    crit: Option<Vec<String>>,
}
#[derive(Deserialize)]
#[serde(untagged)]
enum Audience {
    One(String),
    Many(Vec<String>),
}
impl Audience {
    fn includes(&self, expected: &str) -> bool {
        match self {
            Self::One(s) => s == expected,
            Self::Many(v) => v.iter().any(|s| s == expected),
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
    scope: String,
    client_id: String,
    nbf: Option<i64>,
    auth_time: Option<i64>,
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

impl OidcVerifier {
    pub fn new(issuer: &str, audience: &str, scope: &str) -> Result<Self, VerifyError> {
        let url = safe_url(issuer)?;
        if url.as_str().trim_end_matches('/') != issuer.trim_end_matches('/')
            || audience.is_empty()
            || audience.len() > 512
            || scope.is_empty()
            || scope.len() > 128
            || scope.chars().any(char::is_whitespace)
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
            return Err(if fresh {
                VerifyError::Rejected
            } else {
                unavailable()
            });
        }
        cache.attempted = Some(now);
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
        if set.keys.is_empty() || set.keys.len() > 64 {
            return Err(unavailable());
        }
        let mut keys = HashMap::new();
        for key in set.keys {
            if key.kty != "EC"
                || key.crv.as_deref() != Some("P-256")
                || key.alg.as_deref().is_some_and(|alg| alg != "ES256")
                || key.r#use.as_deref().is_some_and(|u| u != "sig")
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
        if keys.is_empty() {
            return Err(unavailable());
        }
        cache.keys = keys;
        cache.fetched = Some(Instant::now());
        cache.keys.get(kid).cloned().ok_or(VerifyError::Rejected)
    }
}

#[async_trait]
impl AccountIdentityVerifier for OidcVerifier {
    async fn verify(&self, token: &str) -> Result<VerifiedIdentity, VerifyError> {
        if token.len() > 16 * 1024 {
            return Err(VerifyError::Rejected);
        }
        let pieces: Vec<_> = token.split('.').collect();
        if pieces.len() != 3 {
            return Err(VerifyError::Rejected);
        }
        let header: Header =
            serde_json::from_slice(&decoded(pieces[0])?).map_err(|_| VerifyError::Rejected)?;
        if header.alg != "ES256"
            || header.typ != "at+jwt"
            || header.kid.is_empty()
            || header.kid.len() > 128
            || header.crit.is_some()
        {
            return Err(VerifyError::Rejected);
        }
        let signature = decoded(pieces[2])?;
        if signature.len() != 64 {
            return Err(VerifyError::Rejected);
        }
        let claims: Claims =
            serde_json::from_slice(&decoded(pieces[1])?).map_err(|_| VerifyError::Rejected)?;
        let now = chrono::Utc::now().timestamp();
        if claims.iss != self.issuer_name
            || !claims.aud.includes(&self.audience)
            || claims.exp <= now
            || claims.iat > now + 30
            || claims.iat < 0
            || claims.exp <= claims.iat
            || claims.exp.saturating_sub(claims.iat) > 900
            || claims.nbf.is_some_and(|nbf| nbf > now)
            || claims
                .auth_time
                .is_some_and(|at| at < 0 || at > claims.iat + 30)
            || !claims.sub.starts_with("acct_")
            || claims.sub.len() != 31
            || !claims.sub[5..].bytes().all(|b| b.is_ascii_alphanumeric())
            || claims.client_id.is_empty()
            || claims.client_id.len() > 128
            || !claims.scope.split(' ').any(|s| s == self.scope)
        {
            return Err(VerifyError::Rejected);
        }
        let key = self.key(&header.kid).await?;
        let signed = format!("{}.{}", pieces[0], pieces[1]);
        UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, key)
            .verify(signed.as_bytes(), &signature)
            .map_err(|_| VerifyError::Rejected)?;
        Ok(VerifiedIdentity {
            issuer: claims.iss,
            subject: claims.sub,
            authenticated_at: claims.auth_time,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::State, routing::get, Json, Router};
    use ring::{
        rand::SystemRandom,
        signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING},
    };
    use serde_json::{json, Value};
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Server {
        document: Mutex<Value>,
        jwks: Mutex<Value>,
        gets: AtomicUsize,
    }
    struct Fixture {
        issuer: String,
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
        async fn new() -> Self {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let issuer = format!("http://{}", listener.local_addr().unwrap());
            let signer = signer();
            let state = Arc::new(Server {
                document: Mutex::new(json!({"issuer":issuer,"jwks_uri":format!("{issuer}/keys")})),
                jwks: Mutex::new(jwks(&signer, "one")),
                gets: AtomicUsize::new(0),
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
                        Json(s.jwks.lock().await.clone())
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
        fn claims(&self) -> Value {
            let now = chrono::Utc::now().timestamp();
            json!({"iss":self.issuer,"sub":"acct_01234567890123456789012345","aud":"https://station.example",
                "exp":now+900,"iat":now,"client_id":"astation","scope":"openid station:account"})
        }
        fn token(&self, header: Value, claims: Value) -> String {
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
        fn header(&self) -> Value {
            json!({"alg":"ES256","typ":"at+jwt","kid":"one"})
        }
        async fn allow_refresh(&self, expired: bool) {
            let mut cache = self.verifier.cache.lock().await;
            cache.attempted = Some(Instant::now() - REFRESH_COOLDOWN - Duration::from_secs(1));
            if expired {
                cache.fetched = Some(Instant::now() - CACHE_TTL - Duration::from_secs(1));
            }
        }
    }

    #[tokio::test]
    async fn signed_access_tokens_enforce_issuer_audience_type_scope_and_lifetime() {
        let f = Fixture::new().await;
        let token = f.token(f.header(), f.claims());
        let identity = f.verifier.verify(&token).await.unwrap();
        assert_eq!(identity.issuer, f.issuer);
        assert_eq!(identity.subject, "acct_01234567890123456789012345");
        assert_eq!(identity.authenticated_at, None); // iat is never fresh-authentication proof.
        for (field, value) in [
            ("iss", json!("https://evil.example")),
            ("aud", json!("different-api")),
            ("sub", json!("email@example.com")),
            ("scope", json!("openid station:account-extra")),
            ("exp", json!(chrono::Utc::now().timestamp())),
            ("iat", json!(chrono::Utc::now().timestamp() + 60)),
            ("exp", json!(chrono::Utc::now().timestamp() + 3600)),
            ("nbf", json!(chrono::Utc::now().timestamp() + 30)),
            ("iat", json!(true)),
            ("client_id", json!("")),
        ] {
            let mut claims = f.claims();
            claims[field] = value;
            assert!(
                matches!(
                    f.verifier.verify(&f.token(f.header(), claims)).await,
                    Err(VerifyError::Rejected)
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
        *f.state.jwks.lock().await = json!({"keys":[]});
        f.verifier.verify(&next).await.unwrap(); // Valid cache, within the explicit 60-second revocation window.
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
        *f.state.jwks.lock().await = json!({"keys":[]});
        {
            let mut cache = verifier.cache.lock().await;
            cache.fetched = Some(Instant::now() - CACHE_TTL - Duration::from_secs(1));
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
        *f.state.jwks.lock().await = jwks(&f.signer, "one");
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
        other["sub"] = json!("acct_98765432109876543210987654");
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
