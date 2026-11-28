//! Authenticated Portal policy. Unsigned nudges never advance this checkpoint.
use serde::{Deserialize, Serialize};
use crate::integration_checkpoint::PendingRelease;
use std::collections::{BTreeMap, BTreeSet};

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
pub(crate) const PAGE_LIMIT: usize = 500;
pub(crate) const MAX_POLICY_AGE_SECS: i64 = 120;

#[path = "integration_availability.rs"]
mod availability;
#[path = "integration_binding_releases.rs"]
mod binding_releases;
use availability::Availability;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct FeedBinding {
    pub issuer: String,
    pub portal_origin: String,
    pub station_origin: String,
    pub report_client_id: String,
}

impl FeedBinding {
    pub fn validate(&self) -> Result<(), ()> {
        for origin in [&self.issuer, &self.portal_origin, &self.station_origin] {
            if !crate::account_identity::station_origin(origin) {
                return Err(());
            }
        }
        if !crate::account_identity::integration_station_origin(&self.station_origin)
            || !client_id(&self.report_client_id, "s-")
        {
            return Err(());
        }
        Ok(())
    }
    pub(crate) fn from_reporting_env() -> Result<Option<Self>, ()> {
        let get = |key| std::env::var(key).map_err(|_| ());
        if std::env::var_os("STATION_REPORT_CLIENT_ID").is_none() {
            return Ok(None);
        }
        let public_origin = std::env::var("PUBLIC_BASE_URL").ok();
        let station_origin = crate::account_identity::configured_integration_origin(
            public_origin.as_deref(), &get("ACCOUNT_OIDC_AUDIENCE")?,
        )?;
        let binding = Self {
            issuer: get("ACCOUNT_OIDC_ISSUER")?,
            portal_origin: get("STATION_PORTAL_ORIGIN")?,
            station_origin,
            report_client_id: get("STATION_REPORT_CLIENT_ID")?,
        };
        binding.validate()?;
        Ok(Some(binding))
    }

    pub(crate) fn storage_key(&self) -> Result<String, ()> {
        self.validate()?;
        serde_json::to_string(self).map_err(|_| ())
    }

    pub(crate) fn report_control_binding(&self) -> String {
        serde_json::json!([self.issuer, self.portal_origin, self.station_origin]).to_string()
    }
}

pub(crate) fn client_id(value: &str, prefix: &str) -> bool {
    value.len() == 28
        && value.starts_with(prefix)
        && value.as_bytes()[2..]
            .iter()
            .all(|b| b"0123456789abcdefghjkmnpqrstvwxyz".contains(b))
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IntegrationPolicy {
    pub owner_account: String,
    pub state: String,
    pub scopes: Vec<String>,
    pub r9_svc: Option<String>,
    pub expires_at: String,
    pub quota_per_second: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interrupt_running: Option<bool>,
}

impl IntegrationPolicy {
    pub(crate) fn grant_unexpired(&self, now: i64) -> bool {
        self.expires_at().is_ok_and(|expiry| now < expiry)
    }

    fn permits_external_verifier(&self, now: i64) -> bool {
        self.r9_svc.is_some()
            && matches!(self.state.as_str(), "provisioning" | "ready" | "waiting_for_host")
            && self.grant_unexpired(now)
    }

    fn same_verifier(&self, prior: &Self) -> bool {
        self.r9_svc == prior.r9_svc && self.owner_account == prior.owner_account
    }

    fn preserves_observed_lifecycle(&self, prior: &Self) -> bool {
        if self.owner_account != prior.owner_account {
            return false;
        }
        let stopped = match prior.state.as_str() {
            "revoked" => self.state == "revoked",
            "revoking" => matches!(self.state.as_str(), "revoking" | "revoked"),
            _ => return true,
        };
        stopped && (prior.interrupt_running != Some(true) || self.interrupt_running == Some(true))
    }

    pub(crate) fn validate(&self) -> Result<(), ()> {
        if self.owner_account.len() != 28
            || !self.owner_account.starts_with("ab")
            || !self.owner_account.as_bytes()[2..]
                .iter()
                .all(|b| b"0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(b))
            || !matches!(
                self.state.as_str(),
                "awaiting_approval"
                    | "provisioning"
                    | "waiting_for_host"
                    | "ready"
                    | "paused"
                    | "expired"
                    | "revoking"
                    | "revoked"
            )
            || self.scopes.is_empty()
            || self.scopes.len() > if cfg!(feature = "host-work-api") { 8 } else { 5 }
            || self.scopes.iter().any(|s| {
                !(matches!(
                    s.as_str(),
                    "agent.view"
                        | "agent.prompt"
                        | "agent.approve"
                        | "agent.interrupt"
                        | "agent.terminal"
                ) || (cfg!(feature = "host-work-api")
                    && matches!(s.as_str(), "agent.launch" | "agent.message" | "agent.notify")))
            })
            || self.scopes.iter().collect::<BTreeSet<_>>().len() != self.scopes.len()
            || !self.scopes.iter().any(|s| s == "agent.view")
            || (self.scopes.iter().any(|s| s == "agent.notify")
                && (!self.scopes.iter().any(|s| s == "agent.message")
                    || !self.scopes.iter().any(|s| s == "agent.prompt")))
            || !(1..=10_000).contains(&self.quota_per_second)
            || self.r9_svc.as_ref().is_some_and(|s| {
                s.len() != 64
                    || !s
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
            || chrono::DateTime::parse_from_rfc3339(&self.expires_at).is_err()
        {
            return Err(());
        }
        Ok(())
    }
    pub fn expires_at(&self) -> Result<i64, ()> {
        chrono::DateTime::parse_from_rfc3339(&self.expires_at)
            .map(|d| d.timestamp())
            .map_err(|_| ())
    }
}

#[derive(Deserialize)]
pub(crate) struct InitialIntegration {
    pub id: String,
    #[serde(flatten)]
    pub policy: IntegrationPolicy,
}

// Account events distinguish required JSON nulls from omitted fields. Other
// event kinds can carry new metadata without changing their interpretation.
fn present<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Change {
    pub id: u64,
    #[serde(default, deserialize_with = "present")]
    integration_id: Option<Option<String>>,
    pub kind: String,
    at: Option<serde_json::Value>,
    release_id: Option<serde_json::Value>,
    binding: Option<serde_json::Value>,
    // The event's historical state is deliberately not used as current policy.
    pub integration: Option<IntegrationPolicy>,
    #[serde(default, deserialize_with = "present")]
    account: Option<serde_json::Value>,
    #[serde(default, deserialize_with = "present")]
    reason: Option<serde_json::Value>,
    #[serde(default, deserialize_with = "present")]
    state: Option<serde_json::Value>,
}

impl Change {
    fn binding_release(&self) -> Result<PendingRelease, ()> {
        let target = self.binding.as_ref().and_then(|b| b.as_object()).ok_or(())?;
        if self.integration_id != Some(None) || self.integration.is_some()
            || self.reason.as_ref().and_then(|v| v.as_str()) != Some("agora_build")
            || self.state.as_ref() != Some(&serde_json::Value::Null) || target.len() != 4
        {
            return Err(());
        }
        let text = |name: &str| target.get(name).and_then(|v| v.as_str()).map(str::to_owned).ok_or(());
        let release = PendingRelease {
            release_id: self.release_id.as_ref().and_then(|v| v.as_str()).ok_or(())?.into(),
            account: self.account.as_ref().and_then(|v| v.as_str()).ok_or(())?.into(),
            account_id: text("accountId")?, genesis_hash: text("genesisHash")?, binding_id: text("bindingId")?,
            version: target.get("version").and_then(|v| v.as_u64()).ok_or(())?,
            requested_at: self.at.as_ref().and_then(|v| v.as_str()).ok_or(())?.into(),
        };
        release.validate()?;
        Ok(release)
    }

    pub(crate) fn integration_id(&self) -> Option<&str> {
        self.integration_id.as_ref().and_then(Option::as_deref)
    }
}

#[derive(Deserialize)]
pub(crate) struct FeedPage {
    pub changes: Vec<Change>,
    pub cursor: u64,
    pub integrations: Option<Vec<InitialIntegration>>,
}

impl FeedPage {
    pub(crate) fn parse(bytes: &[u8]) -> Result<Self, ()> {
        let value = atem_client::canonical::StrictValue::parse(
            bytes, crate::integration_checkpoint::MAX_CHECKPOINT_BYTES,
        ).map_err(|_| ())?;
        serde_json::from_value(value.value().clone()).map_err(|_| ())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PolicyCheckpoint {
    pub binding: FeedBinding,
    pub cursor: u64,
    pub revision: u64,
    pub received_at: i64,
    // Beginning of a completed ordinary feed read. Slow HTTP responses cannot
    // extend binding-based admission by their transit time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    feed_read_started_ms: Option<i64>,
    // Revision at which each external verifier's uninterrupted grant began.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    verifier_grants: BTreeMap<String, u64>,
    pub denied: bool,
    pub integrations: BTreeMap<String, IntegrationPolicy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub portal_snapshot: Option<crate::integration_checkpoint::PortalCheckpoint>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub portal_snapshot_revision: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    availability: Option<Availability>,
    // Last ordinary page only. The shared journal retains every release at commit.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    binding_releases: Vec<PendingRelease>,
}

impl PolicyCheckpoint {
    pub fn empty(binding: FeedBinding) -> Result<Self, ()> {
        binding.validate()?;
        Ok(Self {
            binding,
            cursor: 0,
            revision: 0,
            received_at: 0,
            feed_read_started_ms: None,
            verifier_grants: BTreeMap::new(),
            denied: true,
            integrations: BTreeMap::new(),
            portal_snapshot: None,
            portal_snapshot_revision: None,
            availability: None,
            binding_releases: Vec::new(),
        })
    }

    /// Run only on a response fetched with this Station's report credential.
    /// A full snapshot reconciles removals; service keys and native consent are
    /// independent records and are never replaced by this reducer.
    pub fn apply(&self, requested_cursor: u64, page: FeedPage, now: i64) -> Result<Self, ()> {
        if now < 0
            || requested_cursor > MAX_SAFE_INTEGER
            || page.cursor > MAX_SAFE_INTEGER
            || (requested_cursor != 0 && requested_cursor != self.cursor)
            || page.changes.len() > PAGE_LIMIT
            || (requested_cursor == 0) != page.integrations.is_some()
            || page.cursor < requested_cursor
        {
            return Err(());
        }
        let mut next = self.clone();
        if self.denied || (requested_cursor == 0 && self.cursor != 0) {
            next.verifier_grants.clear();
        }
        // An ordinary feed response cannot refresh the independently changing bindings.
        next.feed_read_started_ms = None;
        next.portal_snapshot_revision = None;
        next.binding_releases.clear();
        if let Some(snapshot) = page.integrations {
            next.integrations.clear();
            for row in snapshot {
                if !client_id(&row.id, "i-") || next.integrations.contains_key(&row.id) {
                    return Err(());
                }
                row.policy.validate()?;
                if self
                    .integrations
                    .get(&row.id)
                    .is_some_and(|old| old.owner_account != row.policy.owner_account)
                {
                    return Err(());
                }
                next.integrations.insert(row.id, row.policy);
            }
        }
        let mut previous = requested_cursor;
        for change in &page.changes {
            // Event IDs are global: gaps between this Station's events are valid.
            if change.id <= previous
                || change.id > page.cursor
                || change.kind.is_empty()
                || change.kind.len() > 128
            {
                return Err(());
            }
            previous = change.id;
            // A page can contain both pause and resume while both event rows
            // contain the same latest integration projection.
            match change.kind.as_str() {
                "account_disabled" => {
                    if let Some(owner) = change.account.as_ref().and_then(serde_json::Value::as_str) {
                        next.verifier_grants.retain(|id, _| next.integrations.get(id)
                            .is_some_and(|row| row.owner_account != owner));
                    } else {
                        next.verifier_grants.clear();
                    }
                }
                "accounts_incomplete" => next.verifier_grants.clear(),
                _ => {}
            }
            if change.kind == "binding_released" {
                if !crate::integration_checkpoint::PortalCheckpoint::built_in(&self.binding) {
                    return Err(());
                }
                next.binding_releases.push(change.binding_release()?);
            }
            if let Some(id) = change.integration_id() {
                if !client_id(id, "i-") {
                    return Err(());
                }
                let continuous = change.integration.as_ref().zip(next.integrations.get(id))
                    .is_some_and(|(new, old)| new.same_verifier(old) && new.permits_external_verifier(now));
                if !continuous || matches!(change.kind.as_str(), "integration_paused" | "integration_revoked" | "integration_reconciled")
                    || change.state.as_ref().and_then(serde_json::Value::as_str)
                        .is_some_and(|state| matches!(state, "paused" | "expired" | "revoking" | "revoked"))
                {
                    next.verifier_grants.remove(id);
                }
                match &change.integration {
                    Some(policy) => {
                        policy.validate()?;
                        if self
                            .integrations
                            .get(id)
                            .is_some_and(|old| old.owner_account != policy.owner_account)
                        {
                            return Err(());
                        }
                        next.integrations.insert(id.to_owned(), policy.clone());
                    }
                    None => {
                        next.integrations.remove(id);
                    }
                }
            } else if change.integration.is_some() {
                return Err(());
            }
        }
        if page.cursor != previous {
            return Err(());
        }
        // A reset or malformed availability change needs another exact checkpoint.
        // Ordinary integration polling can still advance independently.
        if self.denied || (requested_cursor == 0 && self.cursor != 0) ||
            next.availability.as_mut().is_some_and(|state|
                state.advance(requested_cursor, page.cursor, &page.changes).is_err()) {
            next.availability = None;
        }
        next.cursor = page.cursor;
        next.revision = next.revision.checked_add(1).ok_or(())?;
        next.verifier_grants.retain(|id, _| next.integrations.get(id).is_some_and(|row|
            self.integrations.get(id).is_some_and(|old| row.same_verifier(old)
                && old.grant_unexpired(now))));
        for (id, row) in &next.integrations {
            if cfg!(feature = "delegated-host-work") && row.permits_external_verifier(now) {
                next.verifier_grants.entry(id.clone()).or_insert(next.revision);
            } else {
                next.verifier_grants.remove(id);
            }
        }
        next.received_at = now;
        next.denied = false;
        Ok(next)
    }

    /// Retain the exact source with a new CAS revision even when its cursor is unchanged.
    /// This is collection, not complete recovery evidence or permission to reopen.
    pub(crate) fn apply_checkpoint(
        &self,
        snapshot: crate::integration_checkpoint::PortalCheckpoint,
        now: i64,
    ) -> Result<Self, ()> {
        snapshot.validate_for(&self.binding)?;
        if now < 0 || (snapshot.cursor < self.cursor && !self.denied) {
            return Err(());
        }
        for (id, old) in &self.integrations {
            match snapshot.integrations.get(id) {
                Some(row) if !row.policy.preserves_observed_lifecycle(old) => return Err(()),
                None if matches!(old.state.as_str(), "revoking" | "revoked") => return Err(()),
                _ => {}
            }
        }
        if let Some(previous) = &self.portal_snapshot {
            for (id, old) in &previous.integrations {
                let next = snapshot.integrations.get(id).ok_or(())?;
                if !next.policy.preserves_observed_lifecycle(&old.policy)
                    || old.revoked_at.is_some() && old.revoked_at != next.revoked_at
                {
                    return Err(());
                }
            }
        }
        if self.portal_snapshot.as_ref().is_some_and(|old| snapshot.cursor < old.cursor) {
            return Err(());
        }
        if let Some(previous) = self.portal_snapshot.as_ref().and_then(|source| source.bindings.as_ref()) {
            let current = snapshot.bindings.as_ref().ok_or(())?.iter()
                .map(|row| ((&row.account_id, &row.genesis_hash), row)).collect::<BTreeMap<_, _>>();
            for old in previous {
                let row = *current.get(&(&old.account_id, &old.genesis_hash)).ok_or(())?;
                if row.version < old.version || (row.version == old.version && row != old) {
                    return Err(());
                }
            }
        }
        let mut next = self.clone();
        if snapshot.cursor != self.cursor {
            next.feed_read_started_ms = None;
        }
        // A checkpoint can reveal a disable or changed key before ordinary polling catches up.
        if snapshot.cursor >= self.cursor {
            next.verifier_grants.retain(|id, _| snapshot.integrations.get(id).is_some_and(|row|
                row.policy.permits_external_verifier(now)
                    && self.integrations.get(id).is_some_and(|old| row.policy.same_verifier(old))
                    && snapshot.accounts.as_ref().is_none_or(|accounts| accounts.enabled(&row.policy.owner_account))));
        }
        next.revision = self.revision.checked_add(1).ok_or(())?;
        // Collection cannot replace live policy, refresh its lease or clear a denial.
        next.availability = snapshot.accounts.as_ref().map(|a| Availability::from_checkpoint(snapshot.cursor, a));
        next.portal_snapshot = Some(snapshot);
        next.portal_snapshot_revision = Some(next.revision);
        Ok(next)
    }

    pub(crate) fn record_completed_read(&mut self, started_ms: i64, ended_ms: i64) {
        if started_ms >= 0 && ended_ms >= started_ms && !self.denied
            && self.portal_snapshot.as_ref().is_none_or(|snapshot| snapshot.cursor <= self.cursor)
            && ((cfg!(feature = "delegated-host-work") && !crate::integration_checkpoint::PortalCheckpoint::built_in(&self.binding))
                || self.portal_snapshot.as_ref().is_some_and(|s| s.pending_releases.is_some()))
        {
            self.feed_read_started_ms = Some(started_ms);
        }
    }

    pub(crate) fn binding_feed_current(&self, account: &str, genesis: &str, now_ms: i64) -> bool {
        if !crate::integration_checkpoint::PortalCheckpoint::built_in(&self.binding) {
            return true;
        }
        let Some(snapshot) = &self.portal_snapshot else { return false };
        let Some(bindings) = &snapshot.bindings else { return false };
        if !bindings.iter().any(|r| r.account_id == account && r.genesis_hash == genesis) {
            return true;
        }
        self.recent_d27_read(now_ms)
    }

    pub(crate) fn recent_d27_read(&self, now_ms: i64) -> bool {
        !self.denied && self.portal_snapshot.as_ref().is_some_and(|s|
            s.pending_releases.is_some() && s.cursor <= self.cursor)
            && self.feed_read_started_ms.and_then(|start| now_ms.checked_sub(start))
                .is_some_and(|age| (0..60_000).contains(&age))
    }

    pub(crate) fn external_verifier_grant(&self, id: &str, owner: &str, fingerprint: &str, now_ms: i64) -> Option<u64> {
        let row = self.current(id, owner, now_ms / 1000).ok()?;
        let age = now_ms.checked_sub(self.feed_read_started_ms?)?;
        if !(0..60_000).contains(&age) || row.r9_svc.as_deref() != Some(fingerprint)
            || !row.permits_external_verifier(now_ms / 1000)
            || (crate::integration_checkpoint::PortalCheckpoint::built_in(&self.binding) && !self.recent_d27_read(now_ms))
        {
            return None;
        }
        if let Some(cut) = self.portal_snapshot.as_ref().filter(|cut| cut.cursor == self.cursor) {
            let observed = &cut.integrations.get(id)?.policy;
            if !observed.same_verifier(row) || !observed.permits_external_verifier(now_ms / 1000) {
                return None;
            }
        }
        self.verifier_grants.get(id).copied()
    }

    pub(crate) fn allows_delegated_release(&self, owner: &str) -> bool {
        !crate::integration_checkpoint::PortalCheckpoint::built_in(&self.binding)
            || (!self.denied && self.availability.as_ref().is_some_and(|s| s.enabled_at(self.cursor, owner)))
    }

    /// Call inside the signing or recovery transaction. Report credentials rotate
    /// independently of the ownership version for a Station and device list.
    pub(crate) async fn allows_list_release_in(
        &self, tx: &mut sqlx::PgConnection, owner: &str, account_id: &str, genesis: &str,
    ) -> Result<bool, ()> {
        if !crate::integration_checkpoint::PortalCheckpoint::built_in(&self.binding) {
            return Ok(true);
        }
        if !self.allows_delegated_release(owner) {
            return Ok(false);
        }
        let source = self.portal_snapshot.as_ref().ok_or(())?;
        source.validate_for(&self.binding)?;
        let current = source.bindings.as_ref().ok_or(())?.iter()
            .find(|row| row.account_id == account_id && row.genesis_hash == genesis);
        if current.is_some_and(|row| row.account != owner || row.binding_state != "bound") {
            return Ok(false);
        }
        // Keep new observations ordered with the actual release through commit.
        sqlx::query("SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 29))")
            .bind(self.binding.report_control_binding()).execute(&mut *tx).await.map_err(|_| ())?;
        let observed_denial: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM station_delegated_availability_fences
             WHERE issuer=$1 AND portal_origin=$2 AND station_origin=$3
               AND account IN ('', $4) AND minimum_cursor > $5)",
        ).bind(&self.binding.issuer).bind(&self.binding.portal_origin).bind(&self.binding.station_origin)
        .bind(owner).bind(self.cursor as i64).fetch_one(&mut *tx).await.map_err(|_| ())?;
        if observed_denial {
            return Ok(false);
        }
        Ok(!self.has_competing_binding(tx, account_id, genesis, current).await?)
    }

    /// Binding versions are shared by every report credential for this Station.
    pub(crate) async fn has_competing_binding(
        &self, tx: &mut sqlx::PgConnection, account_id: &str, genesis: &str,
        current: Option<&crate::integration_checkpoint::Binding>,
    ) -> Result<bool, ()> {
        sqlx::query_scalar(
            "SELECT EXISTS (
               SELECT 1 FROM station_binding_release_requests
               WHERE issuer=$6 AND portal_origin=$7 AND station_origin=$8
                 AND account_id=$2 AND genesis=$3
                 AND ($5::bigint IS NULL OR version > $5 OR (version=$5
                      AND binding_id=$4::jsonb->>'bindingId' AND account=$4::jsonb->>'account'))
             ) OR EXISTS (
               SELECT 1 FROM station_native_binding_transitions n
               WHERE (n.issuer,n.portal_origin,n.station_origin,n.account_id,n.genesis)=($6,$7,$8,$2,$3)
                 AND ($5::bigint IS NULL OR n.version > $5 OR (n.version=$5 AND
                    (n.report - 'state' - 'reportId') <> $4::jsonb))
             ) OR EXISTS (
               SELECT 1 FROM station_applied_binding_releases a
               WHERE (a.issuer,a.portal_origin,a.station_origin)=($6,$7,$8)
                 AND (a.account_id,a.genesis)=($2,$3) AND ($5::bigint IS NULL OR a.version > $5
                   OR (a.version=$5 AND ($4::jsonb->>'bindingState' <> 'released'
                     OR a.report->>'account' <> $4::jsonb->>'account'
                     OR a.report->>'bindingId' <> $4::jsonb->>'bindingId')))
             ) OR EXISTS (
               SELECT 1 FROM station_integration_policy p
               CROSS JOIN LATERAL jsonb_array_elements(
                 p.checkpoint::jsonb->'portal_snapshot'->'bindings') AS observation(value)
               WHERE p.binding <> $1
                 AND p.binding::jsonb - 'report_client_id' = $1::text::jsonb - 'report_client_id'
                 AND value->>'accountId'=$2 AND value->>'genesisHash'=$3
                 AND ($4::jsonb IS NULL OR (value->>'version')::bigint > $5
                      OR ((value->>'version')::bigint = $5 AND value <> $4::jsonb)))",
        )
        .bind(self.binding.storage_key()?).bind(account_id).bind(genesis)
        .bind(current.map(sqlx::types::Json)).bind(current.map(|row| row.version as i64))
        .bind(&self.binding.issuer).bind(&self.binding.portal_origin).bind(&self.binding.station_origin)
        .fetch_one(tx).await.map_err(|_| ())
    }

    pub(crate) fn policy_current(&self, now: i64) -> bool {
        !self.denied && self.revision != 0
            && now.checked_sub(self.received_at).is_some_and(|age| (0..MAX_POLICY_AGE_SECS).contains(&age))
    }

    pub(crate) fn owned(&self, id: &str, owner: &str, now: i64) -> Result<&IntegrationPolicy, ()> {
        if !self.policy_current(now) {
            return Err(());
        }
        let policy = self.integrations.get(id).ok_or(())?;
        policy.validate()?;
        if policy.owner_account != owner {
            return Err(());
        }
        Ok(policy)
    }

    pub fn current(&self, id: &str, owner: &str, now: i64) -> Result<&IntegrationPolicy, ()> {
        let policy = self.owned(id, owner, now)?;
        if !policy.grant_unexpired(now) { return Err(()); }
        Ok(policy)
    }

    /// Cleanup needs fresh authenticated policy, including after grant expiry.
    /// This does not authorize execution or signing a membership removal.
    pub fn revoking(&self, id: &str, owner: &str, now: i64) -> Result<&IntegrationPolicy, ()> {
        let policy = self.owned(id, owner, now)?;
        if policy.state != "revoking" { return Err(()); }
        Ok(policy)
    }
}

pub(crate) struct PolicyStore(pub sqlx::PgPool);

impl PolicyStore {
    /// Global pacing across replicas; nudges carry no authority and cannot
    /// consume the Portal's per-Station quota faster than once per second.
    pub async fn claim_poll(&self, binding: &FeedBinding) -> Result<bool, ()> {
        let result = sqlx::query("INSERT INTO station_integration_feed_poll(binding,not_before) VALUES ($1,clock_timestamp()+interval '1 second') ON CONFLICT(binding) DO UPDATE SET not_before=EXCLUDED.not_before WHERE station_integration_feed_poll.not_before <= clock_timestamp()")
            .bind(binding.storage_key()?).execute(&self.0).await.map_err(|_| ())?;
        Ok(result.rows_affected() == 1)
    }

    /// The ordinary feed gets up to 60 claims/minute. All replicas share one
    /// additional checkpoint read/minute within Portal's 120 reads/minute.
    pub(crate) async fn claim_checkpoint_poll(&self, binding: &FeedBinding) -> Result<bool, ()> {
        let result = sqlx::query(
            "UPDATE station_integration_feed_poll SET checkpoint_not_before=clock_timestamp()+interval '1 minute' \
             WHERE binding=$1 AND (checkpoint_not_before IS NULL OR checkpoint_not_before<=clock_timestamp())",
        )
        .bind(binding.storage_key()?)
        .execute(&self.0)
        .await
        .map_err(|_| ())?;
        Ok(result.rows_affected() == 1)
    }
    pub async fn load(&self, binding: &FeedBinding) -> Result<PolicyCheckpoint, ()> {
        let mut connection = self.0.acquire().await.map_err(|_| ())?;
        Self::load_in(&mut connection, binding).await
    }

    pub(crate) async fn load_in(connection: &mut sqlx::PgConnection, binding: &FeedBinding) -> Result<PolicyCheckpoint, ()> {
        let key = binding.storage_key()?;
        let saved: Option<String> = sqlx::query_scalar(
            "SELECT checkpoint FROM station_integration_policy WHERE binding=$1",
        )
        .bind(key)
        .fetch_optional(connection)
        .await
        .map_err(|_| ())?;
        Self::decode_checkpoint(binding, saved)
    }

    pub(crate) async fn lock_for_binding(
        db: &mut sqlx::PgConnection,
        binding: &FeedBinding,
    ) -> Result<PolicyCheckpoint, ()> {
        let saved: Option<String> = sqlx::query_scalar(
            "SELECT checkpoint FROM station_integration_policy WHERE binding=$1 FOR SHARE NOWAIT",
        )
        .bind(binding.storage_key()?)
        .fetch_optional(&mut *db)
        .await
        .map_err(|_| ())?;
        sqlx::query("SELECT pg_advisory_xact_lock_shared(hashtextextended($1,29))")
            .bind(binding.report_control_binding())
            .execute(db)
            .await
            .map_err(|_| ())?;
        Self::decode_checkpoint(binding, saved)
    }

    pub(crate) fn decode_checkpoint(binding: &FeedBinding, saved: Option<String>) -> Result<PolicyCheckpoint, ()> {
        match saved {
            None => PolicyCheckpoint::empty(binding.clone()),
            Some(saved) => {
                let checkpoint: PolicyCheckpoint = serde_json::from_str(&saved).map_err(|_| ())?;
                if checkpoint.binding != *binding
                    || checkpoint.cursor > MAX_SAFE_INTEGER
                    || checkpoint.availability.as_ref().is_some_and(|s| !s.valid_for(binding))
                    || checkpoint.received_at < 0
                {
                    return Err(());
                }
                for (id, policy) in &checkpoint.integrations {
                    if !client_id(id, "i-") {
                        return Err(());
                    }
                    policy.validate()?;
                }
                if let Some(snapshot) = &checkpoint.portal_snapshot {
                    snapshot.validate_for(binding)?;
                    if let Some(revision) = checkpoint.portal_snapshot_revision {
                        if revision != checkpoint.revision { return Err(()); }
                    }
                } else if checkpoint.portal_snapshot_revision.is_some() { return Err(()); }
                Ok(checkpoint)
            }
        }
    }

    pub async fn deny(&self, binding: &FeedBinding) -> Result<(), ()> {
        let key = binding.storage_key()?;
        let empty =
            serde_json::to_string(&PolicyCheckpoint::empty(binding.clone())?).map_err(|_| ())?;
        let mut tx = self.0.begin().await.map_err(|_| ())?;
        sqlx::query("INSERT INTO station_integration_policy(binding,checkpoint) VALUES ($1,$2) ON CONFLICT DO NOTHING")
            .bind(&key).bind(empty).execute(&mut *tx).await.map_err(|_| ())?;
        let saved: String = sqlx::query_scalar(
            "SELECT checkpoint FROM station_integration_policy WHERE binding=$1 FOR UPDATE",
        )
        .bind(&key)
        .fetch_one(&mut *tx)
        .await
        .map_err(|_| ())?;
        let mut checkpoint: PolicyCheckpoint = serde_json::from_str(&saved).map_err(|_| ())?;
        if checkpoint.binding != *binding {
            return Err(());
        }
        checkpoint.denied = true;
        checkpoint.feed_read_started_ms = None;
        checkpoint.availability = None;
        checkpoint.portal_snapshot_revision = None;
        checkpoint.revision = checkpoint.revision.checked_add(1).ok_or(())?;
        sqlx::query("UPDATE station_integration_policy SET checkpoint=$1,recovery_generation=NULL,recovery_revision=NULL WHERE binding=$2")
            .bind(serde_json::to_string(&checkpoint).map_err(|_| ())?)
            .bind(key)
            .execute(&mut *tx)
            .await
            .map_err(|_| ())?;
        tx.commit().await.map_err(|_| ())
    }

    /// Compare the complete prior checkpoint, so parallel replicas or an old
    /// response cannot overwrite a newer pause/revocation or advance its cursor.
    pub async fn commit(
        &self,
        previous: &PolicyCheckpoint,
        next: &PolicyCheckpoint,
    ) -> Result<(), ()> {
        self.commit_for_recovery(previous, next, None).await
    }

    pub(crate) async fn commit_for_recovery(
        &self, previous: &PolicyCheckpoint, next: &PolicyCheckpoint,
        recovery: Option<&crate::remote_api::recovery::delegated_recovery::Binding>,
    ) -> Result<(), ()> {
        if next.binding != previous.binding
            || next.revision != previous.revision.checked_add(1).ok_or(())?
        {
            return Err(());
        }
        let key = previous.binding.storage_key()?;
        let old = serde_json::to_string(previous).map_err(|_| ())?;
        let new = serde_json::to_string(next).map_err(|_| ())?;
        let mut tx = self.0.begin().await.map_err(|_| ())?;
        if let Some(fence) = recovery {
            if fence.origin != next.binding.station_origin || next.portal_snapshot_revision != Some(next.revision) {
                return Err(());
            }
            fence.lock_mode(&mut tx, false).await.map_err(|_| ())?;
        }
        sqlx::query("INSERT INTO station_integration_policy(binding,checkpoint) VALUES ($1,$2) ON CONFLICT DO NOTHING")
            .bind(&key).bind(serde_json::to_string(&PolicyCheckpoint::empty(previous.binding.clone())?).map_err(|_| ())?)
            .execute(&mut *tx).await.map_err(|_| ())?;
        let result = sqlx::query("UPDATE station_integration_policy SET checkpoint=$1,
            recovery_generation=$4,recovery_revision=CASE WHEN $4::bigint IS NULL THEN NULL ELSE ($1::jsonb->>'revision')::numeric END
            WHERE binding=$2 AND checkpoint=$3")
            .bind(new).bind(key).bind(old).bind(recovery.map(|f| f.generation)).execute(&mut *tx).await.map_err(|_| ())?;
        if result.rows_affected() != 1 {
            return Err(());
        }
        let changed_availability = next.availability != previous.availability || next.cursor != previous.cursor;
        let observed_checkpoint = next.portal_snapshot_revision == Some(next.revision);
        let changed_feed = observed_checkpoint || changed_availability || !next.binding_releases.is_empty();
        let built_in = crate::integration_checkpoint::PortalCheckpoint::built_in(&next.binding);
        if changed_feed && (built_in || cfg!(feature = "delegated-host-work")) {
            // A verifier can use a different report credential on another
            // replica. Order its challenge delivery with this observation.
            sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 29))")
                .bind(next.binding.report_control_binding()).execute(&mut *tx).await.map_err(|_| ())?;
        }
        if changed_feed && built_in {
            let releases = if observed_checkpoint {
                next.portal_snapshot.as_ref().and_then(|s| s.pending_releases.as_deref()).unwrap_or_default()
            } else {
                &next.binding_releases
            };
            PendingRelease::retain(&mut tx, &next.binding, releases).await?;
            if observed_checkpoint {
                Self::confirm_binding_releases(&mut tx, next.portal_snapshot.as_ref().ok_or(())?).await?;
            }
            if changed_availability {
                availability::retain_observation(&mut tx, &next.binding, next.cursor, next.availability.as_ref()).await?;
            }
        }
        tx.commit().await.map_err(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    const ID: &str = "i-01234567890123456789012345";
    const OWNER: &str = "ab01234567890123456789012345";
    fn binding() -> FeedBinding {
        FeedBinding {
            issuer: "https://auth.example".into(),
            portal_origin: "https://portal.example".into(),
            station_origin: "https://custom.example".into(),
            report_client_id: "s-01234567890123456789012345".into(),
        }
    }
    fn policy(state: &str) -> Value {
        json!({"ownerAccount":OWNER,"state":state,"scopes":["agent.view"],"r9Svc":"a".repeat(64),
            "expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":1})
    }
    fn initial() -> FeedPage {
        let mut row = policy("ready");
        row["id"] = json!(ID);
        serde_json::from_value(json!({"changes":[],"cursor":0,"integrations":[row]})).unwrap()
    }
    fn page(id: u64, state: &str) -> FeedPage {
        serde_json::from_value(json!({"changes":[{"id":id,"integrationId":ID,
            "kind":"future_kind","state":"ready","integration":policy(state)}],"cursor":id}))
        .unwrap()
    }
    #[cfg(feature = "delegated-host-work")]
    #[test]
    fn external_verifier_keeps_its_nonce_across_an_unrelated_integrations_pause() {
        let before = PolicyCheckpoint::empty(binding()).unwrap().apply(0, initial(), 1).unwrap();
        let revision = before.verifier_grants[ID];
        let mut own = policy("ready");
        own["id"] = json!(ID);
        let peer = "i-11234567890123456789012345";
        let mut paused = policy("paused");
        paused["id"] = json!(peer);
        let changes = json!({"cursor":1, "integrations":[own, paused], "changes":[{
            "id":1, "integrationId":peer, "kind":"integration_paused",
            "state":"paused", "integration":paused
        }]});
        let after = before.apply(0, serde_json::from_value(changes).unwrap(), 2).unwrap();
        assert_eq!(after.verifier_grants.get(ID), Some(&revision));
        assert!(!after.verifier_grants.contains_key(peer));
    }
    #[test]
    fn host_work_scopes_require_view_and_notify_prerequisites() {
        for scopes in [
            vec!["agent.view", "agent.launch"],
            vec!["agent.view", "agent.message"],
            vec!["agent.view", "agent.prompt", "agent.message", "agent.notify"],
        ] {
            let mut value = policy("ready");
            value["scopes"] = json!(scopes);
            let row: IntegrationPolicy = serde_json::from_value(value).unwrap();
            assert_eq!(row.validate().is_ok(), cfg!(feature = "host-work-api"));
        }
        for scopes in [
            vec!["agent.launch"],
            vec!["agent.view", "agent.notify"],
            vec!["agent.view", "agent.prompt", "agent.notify"],
            vec!["agent.view", "agent.message", "agent.notify"],
        ] {
            let mut value = policy("ready");
            value["scopes"] = json!(scopes);
            let row: IntegrationPolicy = serde_json::from_value(value).unwrap();
            assert!(row.validate().is_err());
        }
    }

    #[test]
    fn revocation_cleanup_requires_fresh_owner_policy_but_not_unexpired_execution() {
        let mut saved = PolicyCheckpoint::empty(binding()).unwrap().apply(0, initial(), 100).unwrap();
        assert!(saved.revoking(ID, OWNER, 100).is_err());
        let policy = saved.integrations.get_mut(ID).unwrap();
        policy.state = "revoking".into();
        policy.expires_at = "1970-01-01T00:00:01Z".into();
        assert!(saved.current(ID, OWNER, 100).is_err());
        assert!(saved.revoking(ID, OWNER, 100).is_ok());
        assert!(saved.revoking(ID, OWNER, 99).is_err());
        assert!(saved.revoking(ID, OWNER, 220).is_err());
        assert!(saved.revoking(ID, "ab11234567890123456789012345", 100).is_err());
        saved.denied = true;
        assert!(saved.revoking(ID, OWNER, 100).is_err());
    }

    #[test]
    fn current_snapshots_override_historical_events_and_global_id_gaps_are_valid() {
        let saved = PolicyCheckpoint::empty(binding())
            .unwrap()
            .apply(0, initial(), 100)
            .unwrap();
        let saved = saved
            .apply(
                0,
                {
                    let mut p = page(42, "paused");
                    p.integrations = Some(vec![]);
                    p
                },
                101,
            )
            .unwrap();
        assert_eq!(saved.current(ID, OWNER, 101).unwrap().state, "paused");
        let saved = saved.apply(42, page(93, "revoking"), 102).unwrap();
        assert_eq!(saved.current(ID, OWNER, 102).unwrap().state, "revoking");
        assert!(saved.apply(42, page(94, "ready"), 103).is_err());
        assert!(saved.apply(93, page(93, "ready"), 103).is_err());
    }
    #[test]
    fn owner_metadata_freshness_and_full_reconciliation_are_required() {
        let saved = PolicyCheckpoint::empty(binding())
            .unwrap()
            .apply(0, initial(), 100)
            .unwrap();
        assert!(saved.current(ID, OWNER, 219).is_ok());
        for now in [99, 220] {
            assert!(saved.current(ID, OWNER, now).is_err());
        }
        assert!(saved
            .current(ID, "ab11234567890123456789012345", 100)
            .is_err());
        let empty: FeedPage =
            serde_json::from_value(json!({"changes":[],"cursor":0,"integrations":[]})).unwrap();
        assert!(saved.apply(0, empty, 110).unwrap().integrations.is_empty());
        let mut missing = policy("ready");
        missing.as_object_mut().unwrap().remove("ownerAccount");
        assert!(serde_json::from_value::<IntegrationPolicy>(missing).is_err());
        let mut swapped = page(2, "ready");
        swapped.integrations = Some(vec![]);
        swapped.changes[0]
            .integration
            .as_mut()
            .unwrap()
            .owner_account = "ab11234567890123456789012345".into();
        assert!(saved.apply(0, swapped, 110).is_err());
        let mut swapped_snapshot = initial();
        swapped_snapshot.integrations.as_mut().unwrap()[0]
            .policy
            .owner_account = "ab11234567890123456789012345".into();
        assert!(saved.apply(0, swapped_snapshot, 110).is_err());
        let mut denied = saved;
        denied.denied = true;
        assert!(denied.current(ID, OWNER, 101).is_err());
    }
    #[test]
    fn malformed_and_ambiguous_feed_pages_never_advance_a_checkpoint() {
        let saved = PolicyCheckpoint::empty(binding()).unwrap();
        for value in [
            json!({"changes":[],"cursor":1,"integrations":[]}),
            json!({"changes":[{"id":1,"kind":"x"},{"id":1,"kind":"x"}],"cursor":1,"integrations":[]}),
            json!({"changes":[{"id":2,"kind":"x"},{"id":1,"kind":"x"}],"cursor":2,"integrations":[]}),
            json!({"changes":[],"cursor":9_007_199_254_740_992_u64,"integrations":[]}),
            json!({"changes":[],"cursor":0}),
        ] {
            assert!(saved
                .apply(0, serde_json::from_value(value).unwrap(), 100)
                .is_err());
        }
        for origin in [
            "https://station.agora.build.",
            "https://127.0.0.1",
            "https://custom.example:0",
            "https://custom.example:443",
        ] {
            let mut config = binding();
            config.station_origin = origin.into();
            assert!(config.validate().is_err(), "{origin}");
        }
    }

    #[test]
    fn default_station_with_dev_auth_keeps_an_exact_separate_binding() {
        let mut config = binding();
        config.issuer = "https://auth.dev.agora.build".into();
        config.portal_origin = "https://dev.agora.build".into();
        config.station_origin = "https://station.agora.build".into();
        let checkpoint = PolicyCheckpoint::empty(config.clone()).unwrap();
        assert!(checkpoint.denied);
        assert!(checkpoint.integrations.is_empty());
        let key = config.storage_key().unwrap();
        config.station_origin = "https://dev.agora.build".into();
        assert_ne!(key, config.storage_key().unwrap());
        config.station_origin = "https://station.agora.build:8443".into();
        assert_ne!(key, config.storage_key().unwrap());
    }

    #[test]
    fn built_in_and_custom_configuration_never_alias_another_audience() {
        use crate::account_identity::{configured_integration_origin, BUILT_IN_STATION_ORIGIN};
        assert_eq!(
            configured_integration_origin(None, BUILT_IN_STATION_ORIGIN).unwrap(),
            BUILT_IN_STATION_ORIGIN
        );
        assert_eq!(
            configured_integration_origin(Some("https://private.example"), "https://private.example")
                .unwrap(),
            "https://private.example"
        );
        for (origin, audience) in [
            (None, "https://private.example"),
            (None, "https://dev.agora.build"),
            (Some("https://private.example"), BUILT_IN_STATION_ORIGIN),
            (Some(""), BUILT_IN_STATION_ORIGIN),
            (Some("https://private.example/"), "https://private.example"),
            (Some("http://private.example"), "http://private.example"),
        ] {
            assert!(configured_integration_origin(origin, audience).is_err());
        }
    }

    #[test]
    fn built_in_feed_isolates_accounts_and_revokes_only_the_matching_integration() {
        const OTHER_ID: &str = "i-11234567890123456789012345";
        const OTHER_OWNER: &str = "ab11234567890123456789012345";
        let mut config = binding();
        config.station_origin = crate::account_identity::BUILT_IN_STATION_ORIGIN.into();
        let mut first = policy("ready");
        first["id"] = json!(ID);
        let mut other = policy("ready");
        other["id"] = json!(OTHER_ID);
        other["ownerAccount"] = json!(OTHER_OWNER);
        other["r9Svc"] = json!("b".repeat(64));
        let snapshot: FeedPage = serde_json::from_value(json!({
            "changes":[{"id":1,"kind":"checkpoint"}],"cursor":1,"integrations":[first,other]
        }))
        .unwrap();
        let saved = PolicyCheckpoint::empty(config)
            .unwrap()
            .apply(0, snapshot, 100)
            .unwrap();
        assert!(saved.current(ID, OWNER, 100).is_ok());
        assert!(saved.current(OTHER_ID, OTHER_OWNER, 100).is_ok());
        assert!(saved.current(ID, OTHER_OWNER, 100).is_err());
        assert!(saved.current(OTHER_ID, OWNER, 100).is_err());
        let revoked = saved.apply(1, page(2, "revoking"), 102).unwrap();
        assert!(revoked.revoking(ID, OWNER, 102).is_ok());
        assert_eq!(
            revoked.current(OTHER_ID, OTHER_OWNER, 102).unwrap(),
            saved.current(OTHER_ID, OTHER_OWNER, 100).unwrap()
        );
        assert!(revoked.revoking(ID, OTHER_OWNER, 102).is_err());
    }
    #[tokio::test]
    #[ignore]
    async fn postgres_integration_feed_commits_policy_and_cursor_atomically_across_replicas() {
        let db =
            crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
        let store = PolicyStore(db.pool.clone());
        let old = store.load(&binding()).await.unwrap();
        let next = old.apply(0, initial(), 100).unwrap();
        store.commit(&old, &next).await.unwrap();
        let replica = PolicyStore(db.reconnect(2).await);
        assert_eq!(replica.load(&binding()).await.unwrap(), next);
        let left = next
            .apply(
                0,
                {
                    let mut p = page(42, "paused");
                    p.integrations = Some(vec![]);
                    p
                },
                101,
            )
            .unwrap();
        store.commit(&next, &left).await.unwrap();
        let stale = next.apply(0, initial(), 101).unwrap();
        assert!(replica.commit(&next, &stale).await.is_err());
        assert_eq!(replica.load(&binding()).await.unwrap(), left);
        store.deny(&binding()).await.unwrap();
        assert!(replica.load(&binding()).await.unwrap().denied);
        assert!(replica
            .commit(&left, &left.apply(42, page(94, "ready"), 103).unwrap())
            .await
            .is_err());
        let denied = replica.load(&binding()).await.unwrap();
        sqlx::query("ALTER TABLE station_integration_policy ADD CONSTRAINT injected_write_failure CHECK (false) NOT VALID")
            .execute(&db.pool).await.unwrap();
        let right = denied.apply(42, page(93, "revoked"), 102).unwrap();
        assert!(store.commit(&denied, &right).await.is_err());
        assert_eq!(replica.load(&binding()).await.unwrap(), denied);
        replica.0.close().await;
        db.cleanup().await;
    }
}
