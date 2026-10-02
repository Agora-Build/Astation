//! Agora account registration and explicit Astation data grouping.
//!
//! Device identity remains in `identity_store`; this layer only maps a
//! verified Astation id to the data account used by memory, skills and vaults.

use async_trait::async_trait;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::identity_store::REVOKED_PUBLIC_KEY;
use crate::knowledge_store::KnowledgeStore;
use crate::vault_store::VaultStore;

pub const ONLINE_WINDOW_SECS: i64 = 10 * 60;
pub const ONLINE_REQUEST_TTL_SECS: i64 = 10 * 60;
pub const DELAYED_MERGE_WAIT_SECS: i64 = 24 * 60 * 60;
pub const DELAYED_MERGE_EXPIRY_SECS: i64 = 48 * 60 * 60;
pub const FRESH_SIGN_IN_SECS: i64 = 5 * 60;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedAgoraAccount {
    pub subject: String,
    pub authenticated_at: Option<i64>,
}

#[derive(Debug)]
pub enum VerifyError {
    Unavailable(String),
    Rejected,
    InvalidResponse,
}

impl std::fmt::Display for VerifyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(message) => write!(f, "Agora identity verification unavailable: {message}"),
            Self::Rejected => write!(f, "Agora access token was rejected"),
            Self::InvalidResponse => write!(f, "Agora identity response has no stable subject"),
        }
    }
}

#[async_trait]
pub trait AccountIdentityVerifier: Send + Sync {
    async fn verify(&self, access_token: &str) -> Result<VerifiedAgoraAccount, VerifyError>;
}

struct DisabledVerifier;

#[async_trait]
impl AccountIdentityVerifier for DisabledVerifier {
    async fn verify(&self, _access_token: &str) -> Result<VerifiedAgoraAccount, VerifyError> {
        Err(VerifyError::Unavailable(
            "AGORA_ACCOUNT_USERINFO_URL and AGORA_ACCOUNT_SUBJECT_FIELD are not configured"
                .to_string(),
        ))
    }
}

struct HttpAccountIdentityVerifier {
    url: String,
    subject_field: String,
    authenticated_at_field: Option<String>,
    http: reqwest::Client,
}

impl HttpAccountIdentityVerifier {
    fn from_env() -> Arc<dyn AccountIdentityVerifier> {
        let url = std::env::var("AGORA_ACCOUNT_USERINFO_URL")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let subject_field = std::env::var("AGORA_ACCOUNT_SUBJECT_FIELD")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let (Some(url), Some(subject_field)) = (url, subject_field) else {
            return Arc::new(DisabledVerifier);
        };
        Arc::new(Self {
            url,
            subject_field,
            authenticated_at_field: std::env::var("AGORA_ACCOUNT_AUTH_TIME_FIELD")
                .ok()
                .filter(|value| !value.trim().is_empty()),
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(10))
                .build()
                .unwrap_or_else(|_| reqwest::Client::new()),
        })
    }
}

#[async_trait]
impl AccountIdentityVerifier for HttpAccountIdentityVerifier {
    async fn verify(&self, access_token: &str) -> Result<VerifiedAgoraAccount, VerifyError> {
        let response = self
            .http
            .get(&self.url)
            .bearer_auth(access_token)
            .send()
            .await
            .map_err(|error| VerifyError::Unavailable(error.to_string()))?;
        if matches!(response.status().as_u16(), 401 | 403) {
            return Err(VerifyError::Rejected);
        }
        if !response.status().is_success() {
            return Err(VerifyError::Unavailable(format!(
                "userinfo returned HTTP {}",
                response.status().as_u16()
            )));
        }
        let body: serde_json::Value = response
            .json()
            .await
            .map_err(|_| VerifyError::InvalidResponse)?;
        let subject = body
            .get(&self.subject_field)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty() && value.len() <= 512)
            .ok_or(VerifyError::InvalidResponse)?;
        let authenticated_at = self
            .authenticated_at_field
            .as_ref()
            .and_then(|field| body.get(field))
            .and_then(serde_json::Value::as_i64);
        Ok(VerifiedAgoraAccount {
            subject: subject.to_string(),
            authenticated_at,
        })
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct AccountDevice {
    pub astation_id: String,
    pub label: String,
    pub data_account: String,
    pub registered_at: i64,
    pub last_seen_at: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeMode {
    Online,
    Delayed,
}

impl MergeMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Online => "online",
            Self::Delayed => "delayed",
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct MergeRequest {
    pub request_id: String,
    pub requester_astation_id: String,
    pub target_astation_id: String,
    pub mode: String,
    pub created_at: i64,
    pub ready_at: Option<i64>,
    pub expires_at: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct MergeOutcome {
    pub request_id: String,
    pub data_account: String,
    pub astation_ids: Vec<String>,
}

#[derive(Debug)]
pub enum AccountError {
    Db(String),
    NotRegistered,
    NotSameUser,
    AlreadyGrouped,
    WouldOrphanGroup,
    InvalidRequest,
    RequestExpired,
}

impl std::fmt::Display for AccountError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Db(message) => write!(f, "database error: {message}"),
            Self::NotRegistered => write!(f, "Astation is not registered to an Agora account"),
            Self::NotSameUser => write!(f, "Astations are not registered to the same Agora account"),
            Self::AlreadyGrouped => write!(f, "Astations already share a data account"),
            Self::WouldOrphanGroup => write!(
                f,
                "the last Astation in a shared group cannot leave or be removed"
            ),
            Self::InvalidRequest => write!(f, "merge request is not pending for this Astation"),
            Self::RequestExpired => write!(f, "merge request expired"),
        }
    }
}

#[async_trait]
pub trait AccountStore: Send + Sync {
    fn backend_name(&self) -> &'static str;

    async fn verify_access_token(
        &self,
        access_token: &str,
    ) -> Result<VerifiedAgoraAccount, VerifyError>;

    async fn resolve_data_account(&self, astation_id: &str) -> Result<String, AccountError>;

    async fn subject_for_astation(
        &self,
        astation_id: &str,
    ) -> Result<Option<String>, AccountError>;

    async fn register(
        &self,
        astation_id: &str,
        agora_user: &str,
        label: &str,
        now: i64,
    ) -> Result<(), AccountError>;

    async fn touch(&self, astation_id: &str, now: i64) -> Result<(), AccountError>;

    async fn list_for_astation(
        &self,
        astation_id: &str,
    ) -> Result<(Vec<AccountDevice>, Vec<MergeRequest>), AccountError>;

    async fn start_merge(
        &self,
        requester: &str,
        target: &str,
        mode: MergeMode,
        now: i64,
    ) -> Result<MergeRequest, AccountError>;

    async fn approve_merge(
        &self,
        approver: &str,
        request_id: &str,
        now: i64,
    ) -> Result<MergeOutcome, AccountError>;

    async fn cancel_merge(
        &self,
        astation_id: &str,
        request_id: &str,
    ) -> Result<(), AccountError>;

    async fn complete_due_merges(&self, now: i64) -> Result<Vec<MergeOutcome>, AccountError>;

    async fn leave_group(&self, astation_id: &str) -> Result<(), AccountError>;

    async fn remove_astation(
        &self,
        requester: &str,
        target: &str,
        now: i64,
    ) -> Result<(), AccountError>;
}

#[derive(Clone)]
struct AccountRec {
    agora_user: String,
    label: String,
    data_account: String,
    registered_at: i64,
    last_seen_at: i64,
}

#[derive(Clone)]
struct RequestRec {
    request: MergeRequest,
    agora_user: String,
    status: &'static str,
}

#[derive(Default)]
struct InMemoryState {
    accounts: HashMap<String, AccountRec>,
    requests: HashMap<String, RequestRec>,
}

pub struct InMemoryAccountStore {
    state: Mutex<InMemoryState>,
    knowledge: Arc<dyn KnowledgeStore>,
    vault: Arc<dyn VaultStore>,
    verifier: Arc<dyn AccountIdentityVerifier>,
}

impl InMemoryAccountStore {
    pub fn new(knowledge: Arc<dyn KnowledgeStore>, vault: Arc<dyn VaultStore>) -> Self {
        Self::with_verifier(knowledge, vault, Arc::new(DisabledVerifier))
    }

    pub fn with_verifier(
        knowledge: Arc<dyn KnowledgeStore>,
        vault: Arc<dyn VaultStore>,
        verifier: Arc<dyn AccountIdentityVerifier>,
    ) -> Self {
        Self {
            state: Mutex::new(InMemoryState::default()),
            knowledge,
            vault,
            verifier,
        }
    }

    async fn complete_request(
        &self,
        request_id: &str,
        approver: Option<&str>,
        now: i64,
    ) -> Result<MergeOutcome, AccountError> {
        let (sources, target_account, preferred_source, user) = {
            let state = self.state.lock().await;
            let stored = state.requests.get(request_id).ok_or(AccountError::InvalidRequest)?;
            if stored.status != "pending" {
                return Err(AccountError::InvalidRequest);
            }
            if now >= stored.request.expires_at {
                return Err(AccountError::RequestExpired);
            }
            let requester = state
                .accounts
                .get(&stored.request.requester_astation_id)
                .ok_or(AccountError::NotRegistered)?;
            let target = state
                .accounts
                .get(&stored.request.target_astation_id)
                .ok_or(AccountError::NotRegistered)?;
            if requester.agora_user != target.agora_user || requester.agora_user != stored.agora_user {
                return Err(AccountError::NotSameUser);
            }
            if let Some(approver) = approver {
                let approving = state.accounts.get(approver).ok_or(AccountError::NotRegistered)?;
                if stored.request.mode != "online"
                    || approving.agora_user != stored.agora_user
                    || approving.data_account != target.data_account
                {
                    return Err(AccountError::InvalidRequest);
                }
            } else if stored.request.mode != "delayed"
                || stored.request.ready_at.is_none_or(|ready| now < ready)
            {
                return Err(AccountError::InvalidRequest);
            }
            let destination = choose_group(&target.data_account, &requester.data_account);
            (
                dedup_strings(vec![requester.data_account.clone(), target.data_account.clone()]),
                destination,
                target.data_account.clone(),
                stored.agora_user.clone(),
            )
        };

        self.knowledge
            .merge_accounts(&sources, &target_account, &preferred_source)
            .await
            .map_err(|error| AccountError::Db(error.to_string()))?;
        self.vault
            .merge_accounts(&sources, &target_account)
            .await
            .map_err(|error| AccountError::Db(error.to_string()))?;

        let mut state = self.state.lock().await;
        for account in state.accounts.values_mut() {
            if account.agora_user == user && sources.contains(&account.data_account) {
                account.data_account = target_account.clone();
            }
        }
        let stored = state.requests.get_mut(request_id).ok_or(AccountError::InvalidRequest)?;
        stored.status = "completed";
        let mut astation_ids: Vec<String> = state
            .accounts
            .iter()
            .filter(|(_, account)| account.agora_user == user && account.data_account == target_account)
            .map(|(id, _)| id.clone())
            .collect();
        astation_ids.sort();
        Ok(MergeOutcome {
            request_id: request_id.to_string(),
            data_account: target_account,
            astation_ids,
        })
    }

    async fn complete_available_requests(
        &self,
        request_ids: Vec<String>,
        now: i64,
    ) -> Result<Vec<MergeOutcome>, AccountError> {
        let mut outcomes = Vec::new();
        for id in request_ids {
            match self.complete_request(&id, None, now).await {
                Ok(outcome) => outcomes.push(outcome),
                // Another task may cancel or expire a request after the due
                // list is captured. Keep processing the independent entries.
                Err(AccountError::InvalidRequest | AccountError::RequestExpired) => {}
                Err(error) => return Err(error),
            }
        }
        Ok(outcomes)
    }
}

impl Default for InMemoryAccountStore {
    fn default() -> Self {
        Self::new(
            Arc::new(crate::knowledge_store::InMemoryKnowledgeStore::new()),
            Arc::new(crate::vault_store::InMemoryVaultStore::new()),
        )
    }
}

fn choose_group(target: &str, requester: &str) -> String {
    if target.starts_with("group-") {
        target.to_string()
    } else if requester.starts_with("group-") {
        requester.to_string()
    } else {
        format!("group-{}", Uuid::new_v4())
    }
}

fn dedup_strings(mut values: Vec<String>) -> Vec<String> {
    values.sort();
    values.dedup();
    values
}

fn new_request(
    requester: &str,
    target: &str,
    mode: MergeMode,
    now: i64,
) -> MergeRequest {
    let (ready_at, expires_at) = match mode {
        MergeMode::Online => (None, now + ONLINE_REQUEST_TTL_SECS),
        MergeMode::Delayed => (
            Some(now + DELAYED_MERGE_WAIT_SECS),
            now + DELAYED_MERGE_EXPIRY_SECS,
        ),
    };
    MergeRequest {
        request_id: Uuid::new_v4().to_string(),
        requester_astation_id: requester.to_string(),
        target_astation_id: target.to_string(),
        mode: mode.as_str().to_string(),
        created_at: now,
        ready_at,
        expires_at,
    }
}

#[async_trait]
impl AccountStore for InMemoryAccountStore {
    fn backend_name(&self) -> &'static str {
        "memory"
    }

    async fn verify_access_token(
        &self,
        access_token: &str,
    ) -> Result<VerifiedAgoraAccount, VerifyError> {
        self.verifier.verify(access_token).await
    }

    async fn resolve_data_account(&self, astation_id: &str) -> Result<String, AccountError> {
        let state = self.state.lock().await;
        Ok(state
            .accounts
            .get(astation_id)
            .map(|account| account.data_account.clone())
            .unwrap_or_else(|| astation_id.to_string()))
    }

    async fn subject_for_astation(
        &self,
        astation_id: &str,
    ) -> Result<Option<String>, AccountError> {
        Ok(self
            .state
            .lock()
            .await
            .accounts
            .get(astation_id)
            .map(|account| account.agora_user.clone()))
    }

    async fn register(
        &self,
        astation_id: &str,
        agora_user: &str,
        label: &str,
        now: i64,
    ) -> Result<(), AccountError> {
        let mut state = self.state.lock().await;
        if let Some(existing) = state.accounts.get(astation_id) {
            let account_changed = existing.agora_user != agora_user;
            let data_account = existing.data_account.clone();
            if account_changed
                && data_account.starts_with("group-")
                && state
                    .accounts
                    .values()
                    .filter(|candidate| candidate.data_account == data_account)
                    .count()
                    == 1
            {
                return Err(AccountError::WouldOrphanGroup);
            }
            let account = state.accounts.get_mut(astation_id).expect("account checked above");
            if account_changed {
                account.data_account = astation_id.to_string();
                account.registered_at = now;
            }
            account.agora_user = agora_user.to_string();
            account.label = label.to_string();
            account.last_seen_at = now;
        } else {
            state.accounts.insert(
                astation_id.to_string(),
                AccountRec {
                    agora_user: agora_user.to_string(),
                    label: label.to_string(),
                    data_account: astation_id.to_string(),
                    registered_at: now,
                    last_seen_at: now,
                },
            );
        }
        Ok(())
    }

    async fn touch(&self, astation_id: &str, now: i64) -> Result<(), AccountError> {
        if let Some(account) = self.state.lock().await.accounts.get_mut(astation_id) {
            account.last_seen_at = now;
        }
        Ok(())
    }

    async fn list_for_astation(
        &self,
        astation_id: &str,
    ) -> Result<(Vec<AccountDevice>, Vec<MergeRequest>), AccountError> {
        let state = self.state.lock().await;
        let user = &state
            .accounts
            .get(astation_id)
            .ok_or(AccountError::NotRegistered)?
            .agora_user;
        let mut devices: Vec<AccountDevice> = state
            .accounts
            .iter()
            .filter(|(_, account)| &account.agora_user == user)
            .map(|(id, account)| AccountDevice {
                astation_id: id.clone(),
                label: account.label.clone(),
                data_account: account.data_account.clone(),
                registered_at: account.registered_at,
                last_seen_at: account.last_seen_at,
            })
            .collect();
        devices.sort_by_key(|device| (device.registered_at, device.astation_id.clone()));
        let mut requests: Vec<MergeRequest> = state
            .requests
            .values()
            .filter(|request| request.agora_user == *user && request.status == "pending")
            .map(|request| request.request.clone())
            .collect();
        requests.sort_by_key(|request| request.created_at);
        Ok((devices, requests))
    }

    async fn start_merge(
        &self,
        requester: &str,
        target: &str,
        mode: MergeMode,
        now: i64,
    ) -> Result<MergeRequest, AccountError> {
        let mut state = self.state.lock().await;
        let requester_account = state.accounts.get(requester).ok_or(AccountError::NotRegistered)?;
        let target_account = state.accounts.get(target).ok_or(AccountError::NotRegistered)?;
        if requester_account.agora_user != target_account.agora_user {
            return Err(AccountError::NotSameUser);
        }
        if requester_account.data_account == target_account.data_account {
            return Err(AccountError::AlreadyGrouped);
        }
        let user = requester_account.agora_user.clone();
        let request = new_request(requester, target, mode, now);
        state.requests.insert(
            request.request_id.clone(),
            RequestRec {
                request: request.clone(),
                agora_user: user,
                status: "pending",
            },
        );
        Ok(request)
    }

    async fn approve_merge(
        &self,
        approver: &str,
        request_id: &str,
        now: i64,
    ) -> Result<MergeOutcome, AccountError> {
        self.complete_request(request_id, Some(approver), now).await
    }

    async fn cancel_merge(
        &self,
        astation_id: &str,
        request_id: &str,
    ) -> Result<(), AccountError> {
        let mut state = self.state.lock().await;
        let user = state
            .accounts
            .get(astation_id)
            .ok_or(AccountError::NotRegistered)?
            .agora_user
            .clone();
        let request = state.requests.get_mut(request_id).ok_or(AccountError::InvalidRequest)?;
        if request.agora_user != user || request.status != "pending" {
            return Err(AccountError::InvalidRequest);
        }
        request.status = "cancelled";
        Ok(())
    }

    async fn complete_due_merges(&self, now: i64) -> Result<Vec<MergeOutcome>, AccountError> {
        let mut ids: Vec<String> = {
            let mut state = self.state.lock().await;
            for request in state.requests.values_mut() {
                if request.status == "pending" && now >= request.request.expires_at {
                    request.status = "expired";
                }
            }
            state
                .requests
                .values()
                .filter(|request| {
                    request.status == "pending"
                        && request.request.mode == "delayed"
                        && request.request.ready_at.is_some_and(|ready| now >= ready)
                })
                .map(|request| request.request.request_id.clone())
                .collect()
        };
        ids.sort();
        self.complete_available_requests(ids, now).await
    }

    async fn leave_group(&self, astation_id: &str) -> Result<(), AccountError> {
        let mut state = self.state.lock().await;
        let data_account = state
            .accounts
            .get(astation_id)
            .ok_or(AccountError::NotRegistered)?
            .data_account
            .clone();
        if data_account.starts_with("group-")
            && state
                .accounts
                .values()
                .filter(|account| account.data_account == data_account)
                .count()
                == 1
        {
            return Err(AccountError::WouldOrphanGroup);
        }
        let account = state.accounts.get_mut(astation_id).expect("account checked above");
        account.data_account = astation_id.to_string();
        Ok(())
    }

    async fn remove_astation(
        &self,
        requester: &str,
        target: &str,
        _now: i64,
    ) -> Result<(), AccountError> {
        if requester == target {
            return Err(AccountError::InvalidRequest);
        }
        let mut state = self.state.lock().await;
        let requester_user = state
            .accounts
            .get(requester)
            .ok_or(AccountError::NotRegistered)?
            .agora_user
            .clone();
        let target_user = state
            .accounts
            .get(target)
            .ok_or(AccountError::NotRegistered)?
            .agora_user
            .clone();
        if requester_user != target_user {
            return Err(AccountError::NotSameUser);
        }
        let target_data_account = &state
            .accounts
            .get(target)
            .expect("target checked above")
            .data_account;
        if target_data_account.starts_with("group-")
            && state
                .accounts
                .values()
                .filter(|account| &account.data_account == target_data_account)
                .count()
                == 1
        {
            return Err(AccountError::WouldOrphanGroup);
        }
        state.accounts.remove(target);
        state.requests.retain(|_, request| {
            request.request.requester_astation_id != target
                && request.request.target_astation_id != target
        });
        Ok(())
    }
}

pub struct PgAccountStore {
    pool: sqlx::PgPool,
    verifier: Arc<dyn AccountIdentityVerifier>,
}

impl PgAccountStore {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self {
            pool,
            verifier: HttpAccountIdentityVerifier::from_env(),
        }
    }

    async fn complete_request(
        &self,
        request_id: &str,
        approver: Option<&str>,
        now: i64,
    ) -> Result<MergeOutcome, AccountError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        let request: PgMergeRequest = sqlx::query_as(
            "SELECT request_id, agora_user, requester_astation_id, target_astation_id, mode, \
             status, created_at, ready_at, expires_at FROM account_merge_requests \
             WHERE request_id = $1 FOR UPDATE",
        )
        .bind(request_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_err)?
        .ok_or(AccountError::InvalidRequest)?;
        if request.status != "pending" {
            return Err(AccountError::InvalidRequest);
        }
        if now >= request.expires_at {
            sqlx::query("UPDATE account_merge_requests SET status = 'expired' WHERE request_id = $1")
                .bind(request_id)
                .execute(&mut *tx)
                .await
                .map_err(db_err)?;
            tx.commit().await.map_err(db_err)?;
            return Err(AccountError::RequestExpired);
        }
        if approver.is_none()
            && (request.mode != "delayed" || request.ready_at.is_none_or(|ready| now < ready))
        {
            return Err(AccountError::InvalidRequest);
        }

        // Every mapping mutation for one Agora user takes this lock before
        // row locks. This prevents reverse-order merge/remove requests from
        // deadlocking while they touch overlapping Astation rows.
        lock_agora_user(&mut tx, &request.agora_user).await?;
        let requester: PgAccount = load_account(&mut tx, &request.requester_astation_id).await?;
        let target: PgAccount = load_account(&mut tx, &request.target_astation_id).await?;
        if requester.agora_user != target.agora_user || requester.agora_user != request.agora_user {
            return Err(AccountError::NotSameUser);
        }
        if let Some(approver) = approver {
            let approving = load_account(&mut tx, approver).await?;
            if request.mode != "online"
                || approving.agora_user != request.agora_user
                || approving.data_account != target.data_account
            {
                return Err(AccountError::InvalidRequest);
            }
        }

        let destination = choose_group(&target.data_account, &requester.data_account);
        let preferred_source = target.data_account.clone();
        let sources = dedup_strings(vec![requester.data_account, target.data_account]);
        for source in &sources {
            lock_data_account(&mut tx, source).await?;
        }
        merge_postgres_data(
            &mut tx,
            &sources,
            &destination,
            &preferred_source,
            now,
        )
        .await?;
        sqlx::query(
            "UPDATE astation_accounts SET data_account = $1 \
             WHERE agora_user = $2 AND data_account = ANY($3)",
        )
        .bind(&destination)
        .bind(&request.agora_user)
        .bind(&sources)
        .execute(&mut *tx)
        .await
        .map_err(db_err)?;
        sqlx::query(
            "UPDATE account_merge_requests SET status = 'completed', completed_at = $2 \
             WHERE request_id = $1",
        )
        .bind(request_id)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(db_err)?;
        let mut astation_ids: Vec<String> = sqlx::query_scalar(
            "SELECT astation_id FROM astation_accounts WHERE agora_user = $1 AND data_account = $2 \
             ORDER BY astation_id",
        )
        .bind(&request.agora_user)
        .bind(&destination)
        .fetch_all(&mut *tx)
        .await
        .map_err(db_err)?;
        astation_ids.sort();
        tx.commit().await.map_err(db_err)?;
        Ok(MergeOutcome {
            request_id: request_id.to_string(),
            data_account: destination,
            astation_ids,
        })
    }
}

fn db_err(error: sqlx::Error) -> AccountError {
    AccountError::Db(error.to_string())
}

#[derive(sqlx::FromRow)]
struct PgAccount {
    agora_user: String,
    data_account: String,
}

#[derive(sqlx::FromRow)]
struct PgMergeRequest {
    request_id: String,
    agora_user: String,
    requester_astation_id: String,
    target_astation_id: String,
    mode: String,
    status: String,
    created_at: i64,
    ready_at: Option<i64>,
    expires_at: i64,
}

impl PgMergeRequest {
    fn public(&self) -> MergeRequest {
        MergeRequest {
            request_id: self.request_id.clone(),
            requester_astation_id: self.requester_astation_id.clone(),
            target_astation_id: self.target_astation_id.clone(),
            mode: self.mode.clone(),
            created_at: self.created_at,
            ready_at: self.ready_at,
            expires_at: self.expires_at,
        }
    }
}

#[derive(sqlx::FromRow)]
struct PgSkillMergeRow {
    account_id: String,
    scope: String,
    project: String,
    name: String,
    files: String,
    content_hash: String,
    source_agent: String,
    source_machine: String,
    created_at: i64,
    deleted: bool,
    purged: bool,
}

async fn load_account(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    astation_id: &str,
) -> Result<PgAccount, AccountError> {
    sqlx::query_as(
        "SELECT agora_user, data_account FROM astation_accounts \
         WHERE astation_id = $1 FOR UPDATE",
    )
    .bind(astation_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_err)?
    .ok_or(AccountError::NotRegistered)
}

async fn read_account(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    astation_id: &str,
) -> Result<PgAccount, AccountError> {
    sqlx::query_as(
        "SELECT agora_user, data_account FROM astation_accounts WHERE astation_id = $1",
    )
    .bind(astation_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db_err)?
    .ok_or(AccountError::NotRegistered)
}

async fn lock_agora_user(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    agora_user: &str,
) -> Result<(), AccountError> {
    let key = serde_json::to_string(&["agora-user", agora_user])
        .map_err(|error| AccountError::Db(error.to_string()))?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(key)
        .execute(&mut **tx)
        .await
        .map_err(db_err)?;
    Ok(())
}

async fn lock_account_registration(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    astation_id: &str,
) -> Result<(), AccountError> {
    let key = serde_json::to_string(&["account-registration", astation_id])
        .map_err(|error| AccountError::Db(error.to_string()))?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(key)
        .execute(&mut **tx)
        .await
        .map_err(db_err)?;
    Ok(())
}

async fn lock_astation_bindings(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    astation_id: &str,
) -> Result<(), AccountError> {
    let key = serde_json::to_string(&["astation-bindings", astation_id])
        .map_err(|error| AccountError::Db(error.to_string()))?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(key)
        .execute(&mut **tx)
        .await
        .map_err(db_err)?;
    Ok(())
}

async fn ensure_group_will_remain(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    data_account: &str,
) -> Result<(), AccountError> {
    if !data_account.starts_with("group-") {
        return Ok(());
    }
    let members: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM astation_accounts WHERE data_account = $1",
    )
    .bind(data_account)
    .fetch_one(&mut **tx)
    .await
    .map_err(db_err)?;
    if members <= 1 {
        return Err(AccountError::WouldOrphanGroup);
    }
    Ok(())
}

async fn lock_data_account(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    account: &str,
) -> Result<(), AccountError> {
    let key = serde_json::to_string(&["acct", account])
        .map_err(|error| AccountError::Db(error.to_string()))?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(key)
        .execute(&mut **tx)
        .await
        .map_err(db_err)?;
    Ok(())
}

async fn merge_postgres_data(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    sources: &[String],
    destination: &str,
    preferred_source: &str,
    now: i64,
) -> Result<(), AccountError> {
    // Tombstone duplicate live facts before changing account_id, preserving
    // old ids while satisfying the live-fact uniqueness constraint.
    sqlx::query(
        "WITH ranked AS ( \
           SELECT id, row_number() OVER ( \
             PARTITION BY scope, project, machine, content_hash \
             ORDER BY created_at, id \
           ) AS duplicate_rank \
           FROM memories \
           WHERE account_id = ANY($1) AND deleted_at IS NULL AND invalid_at IS NULL \
         ) \
         UPDATE memories SET content = '', content_hash = '', deleted_at = $2, \
           seq = nextval('knowledge_seq') \
         WHERE id IN (SELECT id FROM ranked WHERE duplicate_rank > 1)",
    )
    .bind(sources)
    .bind(now)
    .execute(&mut **tx)
    .await
    .map_err(db_err)?;
    sqlx::query(
        "UPDATE memories SET account_id = $1, seq = nextval('knowledge_seq') \
         WHERE account_id = ANY($2)",
    )
    .bind(destination)
    .bind(sources)
    .execute(&mut **tx)
    .await
    .map_err(db_err)?;

    let skills: Vec<PgSkillMergeRow> = sqlx::query_as(
        "SELECT account_id, scope, project, name, files::text AS files, content_hash, \
           source_agent, source_machine, created_at, deleted, purged \
         FROM skill_versions WHERE account_id = ANY($1) \
         ORDER BY scope, project, name, \
           CASE WHEN account_id = $2 THEN 0 ELSE 1 END, version, created_at, account_id",
    )
    .bind(sources)
    .bind(preferred_source)
    .fetch_all(&mut **tx)
    .await
    .map_err(db_err)?;
    sqlx::query("DELETE FROM skill_versions WHERE account_id = ANY($1)")
        .bind(sources)
        .execute(&mut **tx)
        .await
        .map_err(db_err)?;
    let mut versions: HashMap<(String, String, String), i64> = HashMap::new();
    for skill in skills {
        let _old_account = skill.account_id;
        let key = (skill.scope.clone(), skill.project.clone(), skill.name.clone());
        let version = versions.entry(key).or_insert(0);
        *version += 1;
        sqlx::query(
            "INSERT INTO skill_versions (account_id, scope, project, name, version, files, \
               content_hash, source_agent, source_machine, created_at, deleted, purged, seq) \
             VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, $10, $11, $12, \
               nextval('knowledge_seq'))",
        )
        .bind(destination)
        .bind(skill.scope)
        .bind(skill.project)
        .bind(skill.name)
        .bind(*version)
        .bind(skill.files)
        .bind(skill.content_hash)
        .bind(skill.source_agent)
        .bind(skill.source_machine)
        .bind(skill.created_at)
        .bind(skill.deleted)
        .bind(skill.purged)
        .execute(&mut **tx)
        .await
        .map_err(db_err)?;
    }

    sqlx::query("UPDATE vaults SET work_session_id = $1 WHERE work_session_id = ANY($2)")
        .bind(destination)
        .bind(sources)
        .execute(&mut **tx)
        .await
        .map_err(db_err)?;
    Ok(())
}

#[async_trait]
impl AccountStore for PgAccountStore {
    fn backend_name(&self) -> &'static str {
        "postgres"
    }

    async fn verify_access_token(
        &self,
        access_token: &str,
    ) -> Result<VerifiedAgoraAccount, VerifyError> {
        self.verifier.verify(access_token).await
    }

    async fn resolve_data_account(&self, astation_id: &str) -> Result<String, AccountError> {
        let mapped: Option<String> = sqlx::query_scalar(
            "SELECT data_account FROM astation_accounts WHERE astation_id = $1",
        )
        .bind(astation_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_err)?;
        Ok(mapped.unwrap_or_else(|| astation_id.to_string()))
    }

    async fn subject_for_astation(
        &self,
        astation_id: &str,
    ) -> Result<Option<String>, AccountError> {
        sqlx::query_scalar("SELECT agora_user FROM astation_accounts WHERE astation_id = $1")
            .bind(astation_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(db_err)
    }

    async fn register(
        &self,
        astation_id: &str,
        agora_user: &str,
        label: &str,
        now: i64,
    ) -> Result<(), AccountError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        lock_account_registration(&mut tx, astation_id).await?;
        let existing: Option<PgAccount> = sqlx::query_as(
            "SELECT agora_user, data_account FROM astation_accounts WHERE astation_id = $1",
        )
        .bind(astation_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(db_err)?;
        if let Some(snapshot) = existing {
            lock_agora_user(&mut tx, &snapshot.agora_user).await?;
            let current = load_account(&mut tx, astation_id).await?;
            if current.agora_user != agora_user {
                ensure_group_will_remain(&mut tx, &current.data_account).await?;
                sqlx::query(
                    "UPDATE astation_accounts SET agora_user = $2, label = $3, \
                       data_account = astation_id, registered_at = $4, last_seen_at = $4 \
                     WHERE astation_id = $1",
                )
                .bind(astation_id)
                .bind(agora_user)
                .bind(label)
                .bind(now)
                .execute(&mut *tx)
                .await
                .map_err(db_err)?;
            } else {
                sqlx::query(
                    "UPDATE astation_accounts SET label = $2, last_seen_at = $3 \
                     WHERE astation_id = $1",
                )
                .bind(astation_id)
                .bind(label)
                .bind(now)
                .execute(&mut *tx)
                .await
                .map_err(db_err)?;
            }
        } else {
            sqlx::query(
                "INSERT INTO astation_accounts \
                   (astation_id, agora_user, label, data_account, registered_at, last_seen_at) \
                 VALUES ($1, $2, $3, $1, $4, $4)",
            )
            .bind(astation_id)
            .bind(agora_user)
            .bind(label)
            .bind(now)
            .execute(&mut *tx)
            .await
            .map_err(db_err)?;
        }
        tx.commit().await.map_err(db_err)?;
        Ok(())
    }

    async fn touch(&self, astation_id: &str, now: i64) -> Result<(), AccountError> {
        sqlx::query("UPDATE astation_accounts SET last_seen_at = $2 WHERE astation_id = $1")
            .bind(astation_id)
            .bind(now)
            .execute(&self.pool)
            .await
            .map_err(db_err)?;
        Ok(())
    }

    async fn list_for_astation(
        &self,
        astation_id: &str,
    ) -> Result<(Vec<AccountDevice>, Vec<MergeRequest>), AccountError> {
        let user: String = sqlx::query_scalar(
            "SELECT agora_user FROM astation_accounts WHERE astation_id = $1",
        )
        .bind(astation_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(db_err)?
        .ok_or(AccountError::NotRegistered)?;
        let devices = sqlx::query_as::<_, PgAccountDevice>(
            "SELECT astation_id, label, data_account, registered_at, last_seen_at \
             FROM astation_accounts WHERE agora_user = $1 ORDER BY registered_at, astation_id",
        )
        .bind(&user)
        .fetch_all(&self.pool)
        .await
        .map_err(db_err)?
        .into_iter()
        .map(Into::into)
        .collect();
        let requests = sqlx::query_as::<_, PgMergeRequest>(
            "SELECT request_id, agora_user, requester_astation_id, target_astation_id, mode, \
               status, created_at, ready_at, expires_at FROM account_merge_requests \
             WHERE agora_user = $1 AND status = 'pending' ORDER BY created_at",
        )
        .bind(user)
        .fetch_all(&self.pool)
        .await
        .map_err(db_err)?
        .into_iter()
        .map(|request| request.public())
        .collect();
        Ok((devices, requests))
    }

    async fn start_merge(
        &self,
        requester: &str,
        target: &str,
        mode: MergeMode,
        now: i64,
    ) -> Result<MergeRequest, AccountError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        let snapshot = read_account(&mut tx, requester).await?;
        lock_agora_user(&mut tx, &snapshot.agora_user).await?;
        let requester_account = load_account(&mut tx, requester).await?;
        let target_account = load_account(&mut tx, target).await?;
        if requester_account.agora_user != target_account.agora_user {
            return Err(AccountError::NotSameUser);
        }
        if requester_account.data_account == target_account.data_account {
            return Err(AccountError::AlreadyGrouped);
        }
        let request = new_request(requester, target, mode, now);
        sqlx::query(
            "INSERT INTO account_merge_requests \
               (request_id, agora_user, requester_astation_id, target_astation_id, mode, status, \
                created_at, ready_at, expires_at) \
             VALUES ($1, $2, $3, $4, $5, 'pending', $6, $7, $8)",
        )
        .bind(&request.request_id)
        .bind(requester_account.agora_user)
        .bind(requester)
        .bind(target)
        .bind(request.mode.as_str())
        .bind(request.created_at)
        .bind(request.ready_at)
        .bind(request.expires_at)
        .execute(&mut *tx)
        .await
        .map_err(db_err)?;
        tx.commit().await.map_err(db_err)?;
        Ok(request)
    }

    async fn approve_merge(
        &self,
        approver: &str,
        request_id: &str,
        now: i64,
    ) -> Result<MergeOutcome, AccountError> {
        self.complete_request(request_id, Some(approver), now).await
    }

    async fn cancel_merge(
        &self,
        astation_id: &str,
        request_id: &str,
    ) -> Result<(), AccountError> {
        let result = sqlx::query(
            "UPDATE account_merge_requests SET status = 'cancelled' \
             WHERE request_id = $1 AND status = 'pending' AND agora_user = \
               (SELECT agora_user FROM astation_accounts WHERE astation_id = $2)",
        )
        .bind(request_id)
        .bind(astation_id)
        .execute(&self.pool)
        .await
        .map_err(db_err)?;
        if result.rows_affected() == 0 {
            return Err(AccountError::InvalidRequest);
        }
        Ok(())
    }

    async fn complete_due_merges(&self, now: i64) -> Result<Vec<MergeOutcome>, AccountError> {
        sqlx::query(
            "UPDATE account_merge_requests SET status = 'expired' \
             WHERE status = 'pending' AND expires_at <= $1",
        )
        .bind(now)
        .execute(&self.pool)
        .await
        .map_err(db_err)?;
        let ids: Vec<String> = sqlx::query_scalar(
            "SELECT request_id FROM account_merge_requests \
             WHERE status = 'pending' AND mode = 'delayed' AND ready_at <= $1 \
             ORDER BY ready_at, request_id",
        )
        .bind(now)
        .fetch_all(&self.pool)
        .await
        .map_err(db_err)?;
        let mut outcomes = Vec::new();
        for id in ids {
            match self.complete_request(&id, None, now).await {
                Ok(outcome) => outcomes.push(outcome),
                Err(AccountError::InvalidRequest | AccountError::RequestExpired) => {}
                Err(error) => return Err(error),
            }
        }
        Ok(outcomes)
    }

    async fn leave_group(&self, astation_id: &str) -> Result<(), AccountError> {
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        let snapshot = read_account(&mut tx, astation_id).await?;
        lock_agora_user(&mut tx, &snapshot.agora_user).await?;
        let account = load_account(&mut tx, astation_id).await?;
        ensure_group_will_remain(&mut tx, &account.data_account).await?;
        sqlx::query(
            "UPDATE astation_accounts SET data_account = astation_id WHERE astation_id = $1",
        )
        .bind(astation_id)
        .execute(&mut *tx)
        .await
        .map_err(db_err)?;
        tx.commit().await.map_err(db_err)?;
        Ok(())
    }

    async fn remove_astation(
        &self,
        requester: &str,
        target: &str,
        now: i64,
    ) -> Result<(), AccountError> {
        if requester == target {
            return Err(AccountError::InvalidRequest);
        }
        let mut tx = self.pool.begin().await.map_err(db_err)?;
        let snapshot = read_account(&mut tx, requester).await?;
        lock_agora_user(&mut tx, &snapshot.agora_user).await?;
        let requester_account = load_account(&mut tx, requester).await?;
        let target_account = load_account(&mut tx, target).await?;
        if requester_account.agora_user != target_account.agora_user {
            return Err(AccountError::NotSameUser);
        }
        ensure_group_will_remain(&mut tx, &target_account.data_account).await?;
        lock_astation_bindings(&mut tx, target).await?;
        sqlx::query(
            "DELETE FROM account_merge_requests \
             WHERE requester_astation_id = $1 OR target_astation_id = $1",
        )
        .bind(target)
        .execute(&mut *tx)
        .await
        .map_err(db_err)?;
        sqlx::query("DELETE FROM session_bindings WHERE astation_id = $1")
            .bind(target)
            .execute(&mut *tx)
            .await
            .map_err(db_err)?;
        sqlx::query("DELETE FROM astation_accounts WHERE astation_id = $1")
            .bind(target)
            .execute(&mut *tx)
            .await
            .map_err(db_err)?;
        sqlx::query(
            "INSERT INTO astation_keys \
               (astation_id, public_key, registered_at, last_verified_at) \
             VALUES ($1, $2, $3, $3) \
             ON CONFLICT (astation_id) DO UPDATE SET \
               public_key = EXCLUDED.public_key, last_verified_at = EXCLUDED.last_verified_at",
        )
            .bind(target)
            .bind(REVOKED_PUBLIC_KEY)
            .bind(now)
            .execute(&mut *tx)
            .await
            .map_err(db_err)?;
        tx.commit().await.map_err(db_err)?;
        Ok(())
    }
}

#[derive(sqlx::FromRow)]
struct PgAccountDevice {
    astation_id: String,
    label: String,
    data_account: String,
    registered_at: i64,
    last_seen_at: i64,
}

impl From<PgAccountDevice> for AccountDevice {
    fn from(device: PgAccountDevice) -> Self {
        Self {
            astation_id: device.astation_id,
            label: device.label,
            data_account: device.data_account,
            registered_at: device.registered_at,
            last_seen_at: device.last_seen_at,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::knowledge_store::{InMemoryKnowledgeStore, KnowledgeStore, MemoryRow};
    use crate::vault_store::{InMemoryVaultStore, VaultStore};

    fn stores() -> (
        Arc<InMemoryKnowledgeStore>,
        Arc<InMemoryVaultStore>,
        InMemoryAccountStore,
    ) {
        let knowledge = Arc::new(InMemoryKnowledgeStore::new());
        let vault = Arc::new(InMemoryVaultStore::new());
        let accounts = InMemoryAccountStore::new(knowledge.clone(), vault.clone());
        (knowledge, vault, accounts)
    }

    fn memory(id: &str, content: &str) -> MemoryRow {
        MemoryRow {
            id: id.to_string(),
            scope: "global".to_string(),
            project: String::new(),
            machine: String::new(),
            content: content.to_string(),
            content_hash: format!("hash:{content}"),
            confidence: "medium".to_string(),
            source_agent: "test".to_string(),
            source_machine: "mac".to_string(),
            created_at: 1,
            deleted: false,
            deleted_at: None,
            valid_at: None,
            invalid_at: None,
            superseded_by: None,
            seq: 0,
        }
    }

    #[tokio::test]
    async fn unregistered_astation_resolves_to_itself() {
        let (_, _, store) = stores();
        assert_eq!(
            store.resolve_data_account("astation-a").await.unwrap(),
            "astation-a"
        );
    }

    #[tokio::test]
    async fn online_merge_needs_a_member_of_the_target_group() {
        let (_, _, store) = stores();
        store.register("a", "user-1", "A", 1).await.unwrap();
        store.register("b", "user-1", "B", 1).await.unwrap();
        store.register("c", "user-1", "C", 1).await.unwrap();
        let request = store.start_merge("a", "b", MergeMode::Online, 2).await.unwrap();
        assert!(matches!(
            store.approve_merge("c", &request.request_id, 3).await,
            Err(AccountError::InvalidRequest)
        ));
        let outcome = store.approve_merge("b", &request.request_id, 3).await.unwrap();
        assert!(outcome.data_account.starts_with("group-"));
        assert_eq!(outcome.astation_ids, vec!["a", "b"]);
    }

    #[tokio::test]
    async fn merge_moves_data_and_assigns_fresh_sequences() {
        let (knowledge, vault, store) = stores();
        store.register("a", "user-1", "A", 1).await.unwrap();
        store.register("b", "user-1", "B", 1).await.unwrap();
        knowledge.add_memory("a", memory("m-a", "same")).await.unwrap();
        knowledge.add_memory("b", memory("m-b", "same")).await.unwrap();
        let vault_id = vault.create_vault("b", "writer", "summary").await.unwrap();
        let request = store.start_merge("a", "b", MergeMode::Online, 2).await.unwrap();
        let outcome = store.approve_merge("b", &request.request_id, 3).await.unwrap();
        let rows = knowledge.pull_memories(&outcome.data_account, 0, 100).await.unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows.iter().filter(|row| row.deleted_at.is_none()).count(), 1);
        assert!(rows.iter().all(|row| row.seq > 2));
        assert_eq!(vault.list_readable(&outcome.data_account).await.unwrap()[0].vault_id, vault_id);
    }

    #[tokio::test]
    async fn delayed_merge_waits_and_any_member_can_cancel() {
        let (_, _, store) = stores();
        store.register("a", "user-1", "A", 1).await.unwrap();
        store.register("b", "user-1", "B", 1).await.unwrap();
        let request = store.start_merge("a", "b", MergeMode::Delayed, 10).await.unwrap();
        assert!(store.complete_due_merges(10 + DELAYED_MERGE_WAIT_SECS - 1).await.unwrap().is_empty());
        store.cancel_merge("b", &request.request_id).await.unwrap();
        assert!(store.complete_due_merges(10 + DELAYED_MERGE_WAIT_SECS).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn an_invalid_due_request_does_not_block_the_rest_of_the_batch() {
        let (_, _, store) = stores();
        store.register("a", "user-1", "A", 1).await.unwrap();
        store.register("b", "user-1", "B", 1).await.unwrap();
        let request = store.start_merge("a", "b", MergeMode::Delayed, 10).await.unwrap();
        let outcomes = store
            .complete_available_requests(
                vec!["cancelled-between-list-and-run".to_string(), request.request_id],
                10 + DELAYED_MERGE_WAIT_SECS,
            )
            .await
            .unwrap();
        assert_eq!(outcomes.len(), 1);
        assert_eq!(outcomes[0].astation_ids, vec!["a", "b"]);
    }

    #[tokio::test]
    async fn account_change_never_carries_a_group_to_another_user() {
        let (_, _, store) = stores();
        store.register("a", "user-1", "A", 1).await.unwrap();
        store.register("b", "user-1", "B", 1).await.unwrap();
        let request = store.start_merge("a", "b", MergeMode::Online, 2).await.unwrap();
        store.approve_merge("b", &request.request_id, 3).await.unwrap();
        store.register("a", "user-2", "A", 4).await.unwrap();
        assert_eq!(store.resolve_data_account("a").await.unwrap(), "a");
        assert!(matches!(
            store.list_for_astation("a").await.unwrap().0.as_slice(),
            [AccountDevice { astation_id, .. }] if astation_id == "a"
        ));
    }

    #[tokio::test]
    async fn a_shared_group_always_keeps_at_least_one_registered_member() {
        let (_, _, store) = stores();
        store.register("a", "user-1", "A", 1).await.unwrap();
        store.register("b", "user-1", "B", 1).await.unwrap();
        let request = store.start_merge("a", "b", MergeMode::Online, 2).await.unwrap();
        let group = store.approve_merge("b", &request.request_id, 3).await.unwrap().data_account;

        store.leave_group("a").await.unwrap();
        assert_eq!(store.resolve_data_account("a").await.unwrap(), "a");
        assert_eq!(store.resolve_data_account("b").await.unwrap(), group);
        assert!(matches!(
            store.leave_group("b").await,
            Err(AccountError::WouldOrphanGroup)
        ));
        assert!(matches!(
            store.remove_astation("a", "b", 4).await,
            Err(AccountError::WouldOrphanGroup)
        ));
        assert!(matches!(
            store.register("b", "user-2", "B", 4).await,
            Err(AccountError::WouldOrphanGroup)
        ));

        let request = store.start_merge("a", "b", MergeMode::Online, 5).await.unwrap();
        store.approve_merge("b", &request.request_id, 6).await.unwrap();
        store.remove_astation("a", "b", 7).await.unwrap();
        assert_eq!(store.resolve_data_account("a").await.unwrap(), group);
        assert!(matches!(
            store.list_for_astation("a").await.unwrap().0.as_slice(),
            [AccountDevice { astation_id, .. }] if astation_id == "a"
        ));
    }

    fn is_local_db_url(url: &str) -> bool {
        let rest = match url.split_once("://") {
            Some((scheme, rest)) if scheme == "postgres" || scheme == "postgresql" => rest,
            _ => return false,
        };
        let authority = rest.split(['/', '?']).next().unwrap_or("");
        let hostport = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
        let host = if let Some(stripped) = hostport.strip_prefix('[') {
            stripped.split(']').next().unwrap_or("")
        } else {
            hostport.split(':').next().unwrap_or("")
        };
        matches!(host, "localhost" | "127.0.0.1" | "::1")
    }

    /// Exercises the transactional path that cannot be represented by the
    /// separate in-memory knowledge and vault stores.
    #[tokio::test]
    #[ignore]
    async fn postgres_merge_moves_all_data_atomically() {
        let url = std::env::var("ACCOUNT_TEST_DATABASE_URL")
            .expect("set ACCOUNT_TEST_DATABASE_URL to run the Postgres account test");
        assert!(
            is_local_db_url(&url),
            "ACCOUNT_TEST_DATABASE_URL must point at localhost; the test empties tables"
        );
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(4)
            .connect(&url)
            .await
            .expect("connect ACCOUNT_TEST_DATABASE_URL");
        for statement in [
            "DROP TABLE IF EXISTS account_merge_requests",
            "DROP TABLE IF EXISTS astation_accounts",
            "DROP TABLE IF EXISTS session_bindings",
            "DROP TABLE IF EXISTS astation_keys",
            "DROP TABLE IF EXISTS vault_entries",
            "DROP TABLE IF EXISTS vaults",
            "DROP TABLE IF EXISTS memories",
            "DROP TABLE IF EXISTS skill_versions",
            "DROP SEQUENCE IF EXISTS knowledge_seq",
            "DROP TABLE IF EXISTS _sqlx_migrations",
        ] {
            sqlx::query(statement).execute(&pool).await.unwrap();
        }
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();

        let store = PgAccountStore::new(pool.clone());
        store.register("a", "user-1", "Mac A", 1).await.unwrap();
        store.register("b", "user-1", "Mac B", 1).await.unwrap();

        // Reverse requests used to take requester/target row locks in the
        // opposite order. The per-user advisory lock serializes them before
        // either transaction locks account rows.
        store.register("c", "user-deadlock", "Mac C", 1).await.unwrap();
        store.register("d", "user-deadlock", "Mac D", 1).await.unwrap();
        let cd = store.start_merge("c", "d", MergeMode::Online, 2).await.unwrap();
        let dc = store.start_merge("d", "c", MergeMode::Online, 2).await.unwrap();
        let left = PgAccountStore::new(pool.clone());
        let right = PgAccountStore::new(pool.clone());
        let (left_result, right_result) = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            async {
                tokio::join!(
                    left.approve_merge("d", &cd.request_id, 3),
                    right.approve_merge("c", &dc.request_id, 3),
                )
            },
        )
        .await
        .expect("reverse merge requests deadlocked");
        left_result.unwrap();
        right_result.unwrap();

        for (id, account, content) in [("m-a", "a", "first"), ("m-b", "b", "second")] {
            sqlx::query(
                "INSERT INTO memories (id, account_id, scope, project, machine, content, \
                   content_hash, confidence, source_agent, source_machine, created_at) \
                 VALUES ($1, $2, 'project', 'repo', '', $3, 'same-hash', 'medium', 'test', 'mac', 2)",
            )
            .bind(id)
            .bind(account)
            .bind(content)
            .execute(&pool)
            .await
            .unwrap();
        }
        for (account, version, content_hash, created_at) in
            [("a", 1_i64, "ha1", 1_i64), ("a", 2, "ha2", 2), ("b", 1, "hb1", 3)]
        {
            sqlx::query(
                "INSERT INTO skill_versions (account_id, scope, project, name, version, files, \
                   content_hash, source_agent, source_machine, created_at) \
                 VALUES ($1, 'project', 'repo', 'review', $2, '{}'::jsonb, $3, 'test', 'mac', $4)",
            )
            .bind(account)
            .bind(version)
            .bind(content_hash)
            .bind(created_at)
            .execute(&pool)
            .await
            .unwrap();
        }
        sqlx::query(
            "INSERT INTO vaults (vault_id, summary, work_session_id, created_by) \
             VALUES ('v-test', 'summary', 'b', 'atem')",
        )
        .execute(&pool)
        .await
        .unwrap();
        let pre_merge_seq: i64 = sqlx::query_scalar(
            "SELECT greatest( \
               COALESCE((SELECT max(seq) FROM memories), 0), \
               COALESCE((SELECT max(seq) FROM skill_versions), 0))",
        )
        .fetch_one(&pool)
        .await
        .unwrap();

        let request = store.start_merge("a", "b", MergeMode::Online, 10).await.unwrap();
        let outcome = store.approve_merge("b", &request.request_id, 11).await.unwrap();

        let memories: Vec<(String, String, Option<i64>, i64)> = sqlx::query_as(
            "SELECT account_id, content, deleted_at, seq FROM memories ORDER BY id",
        )
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(memories.len(), 2);
        assert!(memories.iter().all(|row| row.0 == outcome.data_account));
        assert_eq!(memories.iter().filter(|row| row.2.is_none()).count(), 1);
        assert!(memories.iter().all(|row| row.3 > pre_merge_seq));

        let skills: Vec<(String, i64, String, i64)> = sqlx::query_as(
            "SELECT account_id, version, content_hash, seq FROM skill_versions ORDER BY version",
        )
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(skills.iter().map(|row| row.1).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert!(skills.iter().all(|row| row.0 == outcome.data_account));
        assert_eq!(
            skills.iter().map(|row| row.2.as_str()).collect::<Vec<_>>(),
            vec!["hb1", "ha1", "ha2"]
        );
        assert!(skills.iter().all(|row| row.3 > pre_merge_seq));

        let vault_account: String =
            sqlx::query_scalar("SELECT work_session_id FROM vaults WHERE vault_id = 'v-test'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(vault_account, outcome.data_account);
        let mappings: Vec<String> = sqlx::query_scalar(
            "SELECT data_account FROM astation_accounts \
             WHERE agora_user = 'user-1' ORDER BY astation_id",
        )
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(
            mappings,
            vec![outcome.data_account.clone(), outcome.data_account.clone()]
        );
        let status: String = sqlx::query_scalar(
            "SELECT status FROM account_merge_requests WHERE request_id = $1",
        )
        .bind(request.request_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(status, "completed");

        // A client that had already synced either source sees the complete,
        // renumbered skill history because every moved row has a fresh seq.
        let changed_skill_hashes: Vec<String> = sqlx::query_scalar(
            "SELECT content_hash FROM skill_versions \
             WHERE account_id = $1 AND seq > $2 ORDER BY version",
        )
        .bind(&outcome.data_account)
        .bind(pre_merge_seq)
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(changed_skill_hashes, vec!["hb1", "ha1", "ha2"]);

        // Leaving/removal may reduce a group to one member, but that final
        // member cannot orphan the group's data. Rejoining restores the
        // normal removal path.
        store.leave_group("a").await.unwrap();
        assert!(matches!(
            store.leave_group("b").await,
            Err(AccountError::WouldOrphanGroup)
        ));
        assert!(matches!(
            store.remove_astation("a", "b", 20).await,
            Err(AccountError::WouldOrphanGroup)
        ));
        assert!(matches!(
            store.register("b", "user-2", "Mac B", 20).await,
            Err(AccountError::WouldOrphanGroup)
        ));
        let regroup = store.start_merge("a", "b", MergeMode::Online, 21).await.unwrap();
        store.approve_merge("b", &regroup.request_id, 22).await.unwrap();

        sqlx::query(
            "INSERT INTO astation_keys \
               (astation_id, public_key, registered_at, last_verified_at) \
             VALUES ('b', '04bb', 1, 1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO session_bindings (session_id, astation_id, created_at, last_used_at) \
             VALUES ('session-b', 'b', 1, 1)",
        )
        .execute(&pool)
        .await
        .unwrap();
        store.remove_astation("a", "b", 23).await.unwrap();
        let binding_count: i64 =
            sqlx::query_scalar("SELECT count(*) FROM session_bindings WHERE astation_id = 'b'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(binding_count, 0);
        let stored_key: String =
            sqlx::query_scalar("SELECT public_key FROM astation_keys WHERE astation_id = 'b'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(stored_key, REVOKED_PUBLIC_KEY);
        assert_eq!(store.resolve_data_account("a").await.unwrap(), outcome.data_account);
    }
}
