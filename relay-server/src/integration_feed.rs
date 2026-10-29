//! Authenticated Portal policy. Unsigned nudges never advance this checkpoint.
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
pub(crate) const PAGE_LIMIT: usize = 500;
pub(crate) const MAX_POLICY_AGE_SECS: i64 = 120;

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
        if !crate::account_identity::custom_station_origin(&self.station_origin)
            || !client_id(&self.report_client_id, "s-")
        {
            return Err(());
        }
        Ok(())
    }
    fn storage_key(&self) -> Result<String, ()> {
        self.validate()?;
        serde_json::to_string(self).map_err(|_| ())
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
}

impl IntegrationPolicy {
    fn validate(&self) -> Result<(), ()> {
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
            || self.scopes.len() > 5
            || self.scopes.iter().any(|s| {
                !matches!(
                    s.as_str(),
                    "agent.view"
                        | "agent.prompt"
                        | "agent.approve"
                        | "agent.interrupt"
                        | "agent.terminal"
                )
            })
            || self.scopes.iter().collect::<BTreeSet<_>>().len() != self.scopes.len()
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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Change {
    pub id: u64,
    pub integration_id: Option<String>,
    pub kind: String,
    // The event's historical state is deliberately not used as current policy.
    pub integration: Option<IntegrationPolicy>,
}

#[derive(Deserialize)]
pub(crate) struct FeedPage {
    pub changes: Vec<Change>,
    pub cursor: u64,
    pub integrations: Option<Vec<InitialIntegration>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PolicyCheckpoint {
    pub binding: FeedBinding,
    pub cursor: u64,
    pub revision: u64,
    pub received_at: i64,
    pub denied: bool,
    pub integrations: BTreeMap<String, IntegrationPolicy>,
}

impl PolicyCheckpoint {
    pub fn empty(binding: FeedBinding) -> Result<Self, ()> {
        binding.validate()?;
        Ok(Self {
            binding,
            cursor: 0,
            revision: 0,
            received_at: 0,
            denied: true,
            integrations: BTreeMap::new(),
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
            if let Some(id) = &change.integration_id {
                if !client_id(id, "i-") {
                    return Err(());
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
                        next.integrations.insert(id.clone(), policy.clone());
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
        next.cursor = page.cursor;
        next.revision = next.revision.checked_add(1).ok_or(())?;
        next.received_at = now;
        next.denied = false;
        Ok(next)
    }

    fn owned(&self, id: &str, owner: &str, now: i64) -> Result<&IntegrationPolicy, ()> {
        if self.denied
            || self.revision == 0
            || now < self.received_at
            || now - self.received_at >= MAX_POLICY_AGE_SECS
        {
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
        if now >= policy.expires_at()? { return Err(()); }
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
    pub async fn load(&self, binding: &FeedBinding) -> Result<PolicyCheckpoint, ()> {
        let key = binding.storage_key()?;
        let saved: Option<String> = sqlx::query_scalar(
            "SELECT checkpoint FROM station_integration_policy WHERE binding=$1",
        )
        .bind(key)
        .fetch_optional(&self.0)
        .await
        .map_err(|_| ())?;
        match saved {
            None => PolicyCheckpoint::empty(binding.clone()),
            Some(saved) => {
                let checkpoint: PolicyCheckpoint = serde_json::from_str(&saved).map_err(|_| ())?;
                if checkpoint.binding != *binding
                    || checkpoint.cursor > MAX_SAFE_INTEGER
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
        checkpoint.revision = checkpoint.revision.checked_add(1).ok_or(())?;
        sqlx::query("UPDATE station_integration_policy SET checkpoint=$1 WHERE binding=$2")
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
        if next.binding != previous.binding
            || next.revision != previous.revision.checked_add(1).ok_or(())?
        {
            return Err(());
        }
        let key = previous.binding.storage_key()?;
        let old = serde_json::to_string(previous).map_err(|_| ())?;
        let new = serde_json::to_string(next).map_err(|_| ())?;
        let mut tx = self.0.begin().await.map_err(|_| ())?;
        sqlx::query("INSERT INTO station_integration_policy(binding,checkpoint) VALUES ($1,$2) ON CONFLICT DO NOTHING")
            .bind(&key).bind(serde_json::to_string(&PolicyCheckpoint::empty(previous.binding.clone())?).map_err(|_| ())?)
            .execute(&mut *tx).await.map_err(|_| ())?;
        let result = sqlx::query("UPDATE station_integration_policy SET checkpoint=$1 WHERE binding=$2 AND checkpoint=$3")
            .bind(new).bind(key).bind(old).execute(&mut *tx).await.map_err(|_| ())?;
        if result.rows_affected() != 1 {
            return Err(());
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
            "https://station.agora.build",
            "https://station.agora.build:8443",
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
