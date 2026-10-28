//! Custom Station provisioning. Portal supplies policy; native managers sign R9.
use crate::{
    account_identity::{OidcVerifier, VerifiedAccessToken},
    account_store::VerifyError,
    integration_auth::{bearer_token, token_error},
    integration_feed::{FeedBinding, PolicyStore},
    integration_portal::{PortalError, PortalReportClient, StationReportKey},
    service_keys::{self, ServiceKeyContext, ServiceKeyVault},
    AppState,
};
use atem_client::{
    keys::{Alg, PublicKey},
    membership::{service_add, MemberStatus, Membership, ServiceScope},
    provider::{KeyId, KeyProvider},
};
use axum::{
    extract::{DefaultBodyLimit, Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::BTreeSet, io::Read, path::Path as FilePath, sync::Arc, time::Duration};
use tokio::sync::{Notify, Semaphore};
use zeroize::Zeroizing;

pub(crate) struct StationIntegrations {
    pub app: AppState,
    pub binding: FeedBinding,
    pub policies: PolicyStore,
    pub verifier: OidcVerifier,
    pub vault: ServiceKeyVault,
    pub portal: PortalReportClient,
    nudge: Notify,
    readiness_offset: std::sync::atomic::AtomicUsize,
    pub requests: Arc<Semaphore>,
}

#[cfg(test)]
pub(crate) mod tests;

#[derive(Clone)]
pub(crate) struct IntegrationState(pub Option<Arc<StationIntegrations>>);

pub(crate) fn error(status: StatusCode, code: &str) -> Response {
    (
        status,
        [(header::CACHE_CONTROL, "no-store")],
        Json(json!({"error":{"code":code}})),
    )
        .into_response()
}
pub(crate) fn unavailable() -> Response {
    error(
        StatusCode::SERVICE_UNAVAILABLE,
        "station_integration_unavailable",
    )
}

/// Read bounded operator files without following a substituted symlink. Never
/// generate replacements at startup: losing a wrapping key requires recovery.
fn protected_file(path: &str, limit: u64) -> Result<Zeroizing<Vec<u8>>, ()> {
    let path = FilePath::new(path);
    let before = std::fs::symlink_metadata(path).map_err(|_| ())?;
    if !before.is_file() || before.len() == 0 || before.len() > limit {
        return Err(());
    }
    let file = std::fs::File::open(path).map_err(|_| ())?;
    let opened = file.metadata().map_err(|_| ())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.dev() != opened.dev()
            || before.ino() != opened.ino()
            || opened.mode() & 0o077 != 0
        {
            return Err(());
        }
    }
    #[cfg(not(unix))]
    {
        return Err(());
    }
    let mut bytes = Zeroizing::new(Vec::new());
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ())?;
    if bytes.is_empty() || bytes.len() as u64 > limit {
        return Err(());
    }
    Ok(bytes)
}

impl StationIntegrations {
    pub(crate) async fn owner_principal(&self, owner: &str) -> Result<String, Response> {
        self.app.accounts.principal_for_identity(&self.binding.issuer, owner)
            .await.map_err(|_| unavailable())?.ok_or_else(unavailable)
    }

    pub(crate) async fn recovery_log(&self, genesis: &str, owner: &str) -> Result<Membership, Response> {
        let principal = self.owner_principal(owner).await?;
        self.app.recovery.integration_log(genesis, &principal).await.ok_or_else(unavailable)
    }

    fn from_env(app: AppState) -> Result<Option<Arc<Self>>, ()> {
        let get = |key| std::env::var(key).map_err(|_| ());
        if std::env::var_os("STATION_REPORT_CLIENT_ID").is_none() {
            return Ok(None);
        }
        let binding = FeedBinding {
            issuer: get("ACCOUNT_OIDC_ISSUER")?,
            portal_origin: get("STATION_PORTAL_ORIGIN")?,
            station_origin: get("PUBLIC_BASE_URL")?,
            report_client_id: get("STATION_REPORT_CLIENT_ID")?,
        };
        binding.validate()?;
        if get("ACCOUNT_OIDC_AUDIENCE")? != binding.station_origin {
            return Err(());
        }
        let wrapping = protected_file(&get("STATION_SERVICE_WRAPPING_KEY_FILE")?, 32)?;
        let key: &[u8; 32] = wrapping.as_slice().try_into().map_err(|_| ())?;
        let vault = ServiceKeyVault::new(key, &get("STATION_SERVICE_WRAPPING_KEY_ID")?)?;
        let report = protected_file(&get("STATION_REPORT_KEY_FILE")?, 4096)?;
        Self::new(
            app,
            binding,
            vault,
            StationReportKey::from_pkcs8(&report).map_err(|_| ())?,
        )
        .map(Some)
    }

    pub(crate) fn new(
        app: AppState,
        binding: FeedBinding,
        vault: ServiceKeyVault,
        report: StationReportKey,
    ) -> Result<Arc<Self>, ()> {
        binding.validate()?;
        let pool = app.recovery.pool().ok_or(())?;
        let portal = PortalReportClient::new(binding.clone(), report).map_err(|_| ())?;
        let verifier =
            OidcVerifier::new(&binding.issuer, &binding.station_origin, "astation.remote")
                .map_err(|_| ())?;
        Ok(Arc::new(Self {
            app,
            binding,
            policies: PolicyStore(pool),
            verifier,
            vault,
            portal,
            nudge: Notify::new(),
            readiness_offset: std::sync::atomic::AtomicUsize::new(0),
            requests: Arc::new(Semaphore::new(8)),
        }))
    }

    /// One bounded worker per replica. Checkpoint CAS fences overlapping polls.
    async fn run(self: Arc<Self>) {
        let mut reconcile = true;
        loop {
            if !matches!(self.policies.claim_poll(&self.binding).await, Ok(true)) {
                tokio::time::sleep(Duration::from_secs(1)).await;
                continue;
            }
            // Even a full page or an unsigned nudge cannot exceed 120 polls/min.
            let result = self.portal.poll(&self.policies, reconcile).await;
            if result.is_ok() {
                self.report_readiness().await;
            }
            reconcile = matches!(result, Err(PortalError::CursorAhead));
            let immediate = matches!(
                result,
                Ok(true) | Err(PortalError::CursorAhead | PortalError::Conflict)
            );
            tokio::time::sleep(Duration::from_millis(if immediate { 1000 } else { 500 })).await;
            if !immediate {
                tokio::select! { _ = self.nudge.notified() => {}, _ = tokio::time::sleep(Duration::from_secs(59)) => {} }
            }
        }
    }

    async fn report_readiness(&self) {
        use futures_util::StreamExt;
        let Ok(checkpoint) = self.policies.load(&self.binding).await else {
            return;
        };
        let candidates: Vec<_> = checkpoint
            .integrations
            .iter()
            .filter(|(id, policy)| {
                matches!(
                    policy.state.as_str(),
                    "provisioning" | "waiting_for_host" | "ready"
                ) && checkpoint
                    .current(id, &policy.owner_account, chrono::Utc::now().timestamp())
                    .is_ok()
                    && policy.r9_svc.is_some()
            })
            .collect();
        if candidates.is_empty() {
            return;
        }
        let start = self
            .readiness_offset
            .fetch_add(8, std::sync::atomic::Ordering::Relaxed)
            % candidates.len();
        let checkpoint = &checkpoint;
        let mut work = futures_util::stream::iter((0..candidates.len().min(8)).map(|i| {
            let (id, policy) = candidates[(start + i) % candidates.len()];
            async move {
                let verified = if crate::hosted_agents::HOSTED_EXECUTION_ENABLED {
                    matches!(
                        tokio::time::timeout(Duration::from_secs(10), self.probe(id, policy)).await,
                        Ok(Ok(()))
                    )
                } else {
                    false
                };
                let state = if verified {
                    "ready"
                } else {
                    "waiting_for_host"
                };
                if policy.state == state
                    || checkpoint
                        .current(id, &policy.owner_account, chrono::Utc::now().timestamp())
                        .is_err()
                {
                    return;
                }
                let Ok(latest) = self.policies.load(&self.binding).await else {
                    return;
                };
                if latest
                    .current(id, &policy.owner_account, chrono::Utc::now().timestamp())
                    .ok()
                    != Some(policy)
                {
                    return;
                }
                // Never advertise ready while the hosted release gate is closed.
                // Portal may safely retain this state across restarts and retries.
                let _ = self
                    .portal
                    .report(crate::integration_portal::IntegrationReport {
                        integration_id: id,
                        state,
                        reason: if !crate::hosted_agents::HOSTED_EXECUTION_ENABLED {
                            Some("Hosted execution awaits end-to-end verification")
                        } else {
                            None
                        },
                    })
                    .await;
            }
        }))
        .buffer_unordered(4);
        while work.next().await.is_some() {}
    }

    async fn probe(
        &self,
        id: &str,
        policy: &crate::integration_feed::IntegrationPolicy,
    ) -> Result<(), Response> {
        let context = self.context(id).await?;
        if context.owner != policy.owner_account {
            return Err(unavailable());
        }
        let fingerprint = policy.r9_svc.as_deref().ok_or_else(unavailable)?;
        let log = self.recovery_log(&context.genesis, &context.owner).await?;
        let (scope, _) = atem_client::membership::service_grant(&log, &context.service_id)
            .ok_or_else(unavailable)?;
        if scope.hosts.is_empty() {
            return Err(unavailable());
        }
        for host in &scope.hosts {
            crate::hosted_agents::client::HostedConnection::open(self, &context, fingerprint, host)
                .await?;
        }
        Ok(())
    }

    async fn native(&self, headers: &HeaderMap) -> Result<VerifiedAccessToken, Response> {
        let token = bearer_token(headers).map_err(|e| token_error(&e, "astation.remote"))?;
        let verified = self
            .verifier
            .verify_station(token, Some("astation.remote"), None)
            .await
            .map_err(|e| token_error(&e, "astation.remote"))?;
        if verified.client_id != "astation"
            || verified.session_id.is_some()
            || verified.service_fingerprint.is_some()
        {
            return Err(token_error(&VerifyError::Rejected, "astation.remote"));
        }
        Ok(verified)
    }
}

pub(crate) fn routes(app: AppState) -> Router<AppState> {
    let runtime = match StationIntegrations::from_env(app) {
        Ok(value) => value,
        Err(()) => {
            tracing::error!("Station integrations disabled: invalid operator configuration or protected key files");
            None
        }
    };
    if let Some(runtime) = &runtime {
        tokio::spawn(runtime.clone().run());
    }
    Router::new()
        .route("/agora-build/v1/changes", post(nudge))
        .route("/agora-build/v1/details", get(details))
        .route(
            "/agora-build/v1/integrations/:id/provision",
            post(provision),
        )
        .merge(crate::hosted_agents::routes())
        .layer(DefaultBodyLimit::max(65_536))
        .layer(axum::middleware::map_response(
            |mut response: Response| async move {
                response.headers_mut().insert(
                    header::CACHE_CONTROL,
                    header::HeaderValue::from_static("no-store"),
                );
                response
            },
        ))
        .with_state(IntegrationState(runtime))
}

async fn nudge(
    State(IntegrationState(runtime)): State<IntegrationState>,
    body: axum::body::Bytes,
) -> Response {
    // Ignore the claimed cursor. Invalid payloads cannot allocate work either.
    let Some(runtime) = runtime else {
        return unavailable();
    };
    if body.len() > 256
        || serde_json::from_slice::<Value>(&body).ok().is_none_or(|v| {
            v.as_object()
                .is_none_or(|o| o.len() != 1 || !o.contains_key("cursor"))
        })
    {
        return error(StatusCode::BAD_REQUEST, "invalid_nudge");
    }
    runtime.nudge.notify_one();
    StatusCode::ACCEPTED.into_response()
}

async fn details(
    State(IntegrationState(runtime)): State<IntegrationState>,
    headers: HeaderMap,
) -> Response {
    let Some(runtime) = runtime else {
        return unavailable();
    };
    let token = match bearer_token(&headers) {
        Ok(v) => v,
        Err(e) => return token_error(&e, "station.read"),
    };
    if let Err(e) = runtime
        .verifier
        .verify_station(token, Some("station.read"), None)
        .await
    {
        return token_error(&e, "station.read");
    }
    let mut response = Json(
        json!({"label":"Station", "status":"provisioning", "hostedExecutionEnabled":false,
        "reportKey":runtime.portal.public_jwk()}),
    )
    .into_response();
    if headers
        .get(header::ORIGIN)
        .is_some_and(|o| o.as_bytes() == runtime.binding.portal_origin.as_bytes())
    {
        if let Ok(origin) = runtime.binding.portal_origin.parse() {
            response
                .headers_mut()
                .insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, origin);
            response
                .headers_mut()
                .insert(header::VARY, header::HeaderValue::from_static("Origin"));
        }
    }
    response
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ProvisionRequest {
    genesis_hash: String,
    manager_id: String,
    expected_head: Value,
    signed_at: u64,
    hosts: Vec<String>,
    sessions: Option<Vec<String>>,
    projects: Option<Vec<String>>,
}

async fn provision(
    State(IntegrationState(runtime)): State<IntegrationState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(request): Json<ProvisionRequest>,
) -> Response {
    let Some(runtime) = runtime else {
        return unavailable();
    };
    let _permit = match runtime.requests.try_acquire() {
        Ok(v) => v,
        Err(_) => return error(StatusCode::TOO_MANY_REQUESTS, "provisioning_busy"),
    };
    let owner = match runtime.native(&headers).await {
        Ok(v) => v.identity.subject,
        Err(e) => return e,
    };
    match runtime.prepare(&id, &owner, request).await {
        Ok(body) => Json(body).into_response(),
        Err(e) => e,
    }
}

impl StationIntegrations {
    pub(crate) async fn prepare(
        &self,
        id: &str,
        owner: &str,
        request: ProvisionRequest,
    ) -> Result<Value, Response> {
        let denied = || error(StatusCode::CONFLICT, "integration_changed");
        let checkpoint = self
            .policies
            .load(&self.binding)
            .await
            .map_err(|_| unavailable())?;
        let now = chrono::Utc::now().timestamp();
        let policy = checkpoint.current(id, owner, now).map_err(|_| denied())?;
        if policy.state != "awaiting_approval" || policy.r9_svc.is_some() {
            return Err(denied());
        }
        let log = self.recovery_log(&request.genesis_hash, owner).await?;
        let wall = chrono::Utc::now().timestamp_millis().max(0) as u64;
        if log.frozen().is_some()
            || log.head().to_json() != request.expected_head
            || request.signed_at > wall
            || wall - request.signed_at > 60_000
            || request.hosts.is_empty()
            || request.hosts.len() > 64
            || request.hosts.iter().any(|h| log.host(h).is_none())
            || request
                .sessions
                .as_ref()
                .is_some_and(|v| v.is_empty() || v.len() > 64)
            || request
                .projects
                .as_ref()
                .is_some_and(|v| v.is_empty() || v.len() > 64)
            || !log
                .member(&request.manager_id)
                .is_some_and(|m| m.status == MemberStatus::Active && m.member.is_manager())
        {
            return Err(denied());
        }
        let context = ServiceKeyContext {
            issuer: self.binding.issuer.clone(),
            station_origin: self.binding.station_origin.clone(),
            owner: owner.into(),
            integration_id: id.into(),
            genesis: request.genesis_hash.clone(),
            service_id: format!("svc-{id}"),
        };
        if log.member(&context.service_id).is_some() {
            return Err(denied());
        }
        let binding = serde_json::to_string(&self.binding).map_err(|_| unavailable())?;
        let encoded = serde_json::to_string(&context).map_err(|_| unavailable())?;
        sqlx::query("INSERT INTO station_integration_provisioning(binding,integration_id,context) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING")
            .bind(&binding).bind(id).bind(&encoded).execute(&self.policies.0).await.map_err(|_| unavailable())?;
        let (stored,established): (String,Option<String>) = sqlx::query_as("SELECT context,fingerprint FROM station_integration_provisioning WHERE binding=$1 AND integration_id=$2")
            .bind(&binding).bind(id).fetch_one(&self.policies.0).await.map_err(|_| unavailable())?;
        if stored != encoded {
            return Err(denied());
        }
        let public = if let Some(expected) = established {
            service_keys::load_approved(&self.policies.0, &self.vault, &context, &expected)
                .await
                .map_err(|_| unavailable())?
                .public_key(&KeyId::new(&context.service_id))
                .map_err(|_| unavailable())?
        } else {
            let sealed =
                service_keys::load_or_create_pending(&self.policies.0, &self.vault, &context)
                    .await
                    .map_err(|_| unavailable())?;
            PublicKey::new(
                Alg::P256,
                &URL_SAFE_NO_PAD
                    .decode(&sealed.public_key)
                    .map_err(|_| unavailable())?,
            )
            .map_err(|_| unavailable())?
        };
        let fingerprint =
            atem_client::membership::service_key_fingerprint(&public).map_err(|_| unavailable())?;
        let saved:Option<String>=sqlx::query_scalar("UPDATE station_integration_provisioning SET fingerprint=$1 WHERE binding=$2 AND integration_id=$3 AND (fingerprint IS NULL OR fingerprint=$1) RETURNING fingerprint")
            .bind(&fingerprint).bind(&binding).bind(id).fetch_optional(&self.policies.0).await.map_err(|_| unavailable())?;
        if saved.as_deref() != Some(&fingerprint) {
            return Err(unavailable());
        }
        let ops: BTreeSet<&str> = policy
            .scopes
            .iter()
            .flat_map(|scope| match scope.as_str() {
                "agent.view" => vec!["view"],
                "agent.prompt" => vec!["prompt"],
                "agent.approve" => vec!["approval", "rule_revoke"],
                "agent.interrupt" => vec!["interrupt", "stop"],
                "agent.terminal" => vec!["terminal"],
                _ => vec![],
            })
            .collect();
        let scope = ServiceScope::new(request.hosts)
            .ops(ops)
            .sessions(request.sessions)
            .projects(request.projects);
        let expiry = u64::try_from(policy.expires_at().map_err(|_| denied())?)
            .map_err(|_| denied())?
            .checked_mul(1000)
            .ok_or_else(denied)?
            .min(request.signed_at.saturating_add(90 * 24 * 60 * 60 * 1000));
        let action = service_add(
            &context.service_id,
            public,
            &scope,
            expiry,
            request.signed_at,
        )
        .map_err(|_| denied())?;
        let body = atem_client::canonical::jcs(&log.draft(
            &request.manager_id,
            request.signed_at,
            &action,
        ))
        .map_err(|_| denied())?;
        let current = self
            .policies
            .load(&self.binding)
            .await
            .map_err(|_| unavailable())?;
        if current != checkpoint {
            return Err(denied());
        }
        Ok(
            json!({"integrationId":id,"ownerAccount":owner,"issuer":self.binding.issuer,
            "stationOrigin":self.binding.station_origin,"genesisHash":request.genesis_hash,
            "bodyJSON":body,"fingerprint":fingerprint,"hostedExecutionEnabled":false}),
        )
    }
}
