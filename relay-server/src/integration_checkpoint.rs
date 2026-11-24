//! One authenticated Portal snapshot. A feed cursor alone does not version bindings.
use crate::integration_feed::{client_id, FeedBinding, IntegrationPolicy};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const MAX_CHECKPOINT_BYTES: usize = 4_194_304;
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CheckpointIntegration {
    pub policy: IntegrationPolicy,
    // None on a stopped integration preserves an unknown legacy revocation time.
    pub revoked_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Accounts {
    pub complete: bool,
    pub disabled: Vec<String>,
}

impl Accounts {
    pub(crate) fn enabled(&self, account: &str) -> bool {
        self.complete && account_id(account) && !self.disabled.iter().any(|id| id == account)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Binding {
    pub account: String,
    pub account_id: String,
    pub genesis_hash: String,
    pub binding_id: String,
    pub version: u64,
    pub binding_state: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PortalCheckpoint {
    pub binding: FeedBinding,
    pub cursor: u64,
    pub at: String,
    pub integrations: BTreeMap<String, CheckpointIntegration>,
    pub accounts: Option<Accounts>,
    pub bindings: Option<Vec<Binding>>,
}

pub(crate) fn account_id(value: &str) -> bool {
    value.len() == 28
        && value.starts_with("ab")
        && value.as_bytes()[2..]
            .iter()
            .all(|byte| b"0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(byte))
}

fn opaque(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

fn timestamp(value: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(value)
        .is_ok_and(|date| date.to_rfc3339_opts(chrono::SecondsFormat::Millis, true) == value)
}

fn exact_keys(value: &Value, keys: &[&str]) -> Result<(), ()> {
    let object = value.as_object().ok_or(())?;
    if object.len() != keys.len() || keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(());
    }
    Ok(())
}

impl PortalCheckpoint {
    pub(crate) fn built_in(binding: &FeedBinding) -> bool {
        matches!(
            binding.station_origin.as_str(),
            "https://station.agora.build" | "https://station-dev.agora.build"
        )
    }

    /// Call only for bytes fetched with this exact Station's report credential.
    pub(crate) fn parse(bytes: &[u8], binding: &FeedBinding) -> Result<Self, ()> {
        binding.validate()?;
        let strict = atem_client::canonical::StrictValue::parse(bytes, MAX_CHECKPOINT_BYTES)
            .map_err(|_| ())?;
        let value = strict.value();
        exact_keys(value, &["changes", "cursor", "checkpoint"])?;
        if value["changes"].as_array().ok_or(())?.len() != 0 {
            return Err(());
        }
        let cursor = value["cursor"]
            .as_u64()
            .filter(|cursor| *cursor <= MAX_SAFE_INTEGER)
            .ok_or(())?;
        let source = &value["checkpoint"];
        let built_in = Self::built_in(binding);
        exact_keys(
            source,
            if built_in {
                &["at", "integrations", "accounts", "bindings"]
            } else {
                &["at", "integrations"]
            },
        )?;
        let mut integrations = BTreeMap::new();
        for row in source["integrations"].as_array().ok_or(())? {
            let fields = row.as_object().ok_or(())?;
            if fields.keys().any(|key| {
                ![
                    "id",
                    "ownerAccount",
                    "state",
                    "scopes",
                    "r9Svc",
                    "expiresAt",
                    "quotaPerSecond",
                    "interruptRunning",
                    "revokedAt",
                ]
                .contains(&key.as_str())
            }) {
                return Err(());
            }
            let id = row["id"]
                .as_str()
                .filter(|id| client_id(id, "i-"))
                .ok_or(())?;
            let policy: IntegrationPolicy = serde_json::from_value(row.clone()).map_err(|_| ())?;
            policy.validate()?;
            let stopped = matches!(policy.state.as_str(), "revoking" | "revoked");
            if stopped && (!fields.contains_key("revokedAt") || policy.interrupt_running.is_none())
            {
                return Err(());
            }
            if !stopped && fields.contains_key("revokedAt") {
                return Err(());
            }
            let revoked_at = match fields.get("revokedAt") {
                None | Some(Value::Null) => None,
                Some(Value::String(at)) if timestamp(at) => Some(at.clone()),
                _ => return Err(()),
            };
            if integrations
                .insert(id.into(), CheckpointIntegration { policy, revoked_at })
                .is_some()
            {
                return Err(());
            }
        }
        let result = Self {
            binding: binding.clone(),
            cursor,
            at: source["at"].as_str().ok_or(())?.into(),
            integrations,
            accounts: if built_in {
                Some(serde_json::from_value(source["accounts"].clone()).map_err(|_| ())?)
            } else {
                None
            },
            bindings: if built_in {
                Some(serde_json::from_value(source["bindings"].clone()).map_err(|_| ())?)
            } else {
                None
            },
        };
        result.validate_for(binding)?;
        Ok(result)
    }

    /// Also validate a retained checkpoint before using any of its source fields.
    pub(crate) fn validate_for(&self, binding: &FeedBinding) -> Result<(), ()> {
        binding.validate()?;
        if self.binding != *binding
            || self.cursor > MAX_SAFE_INTEGER
            || !timestamp(&self.at)
            || self.accounts.is_some() != Self::built_in(binding)
            || self.bindings.is_some() != Self::built_in(binding)
        {
            return Err(());
        }
        for (id, row) in &self.integrations {
            if !client_id(id, "i-") {
                return Err(());
            }
            row.policy.validate()?;
            let stopped = matches!(row.policy.state.as_str(), "revoking" | "revoked");
            if (stopped && row.policy.interrupt_running.is_none())
                || row
                    .revoked_at
                    .as_ref()
                    .is_some_and(|at| !stopped || !timestamp(at))
            {
                return Err(());
            }
        }
        if let Some(accounts) = &self.accounts {
            if !accounts.disabled.iter().all(|id| account_id(id))
                || !accounts.disabled.windows(2).all(|pair| pair[0] < pair[1])
            {
                return Err(());
            }
        }
        if let Some(bindings) = &self.bindings {
            let mut seen = BTreeSet::new();
            for row in bindings {
                if !account_id(&row.account)
                    || !opaque(&row.account_id)
                    || !opaque(&row.binding_id)
                    || row.genesis_hash.len() != 64
                    || !row
                        .genesis_hash
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                    || row.version == 0
                    || row.version > MAX_SAFE_INTEGER
                    || !matches!(row.binding_state.as_str(), "bound" | "unbound" | "released")
                    || !seen.insert((&row.account_id, &row.genesis_hash))
                {
                    return Err(());
                }
            }
            if !bindings.windows(2).all(|pair| {
                (&pair[0].account_id, &pair[0].genesis_hash)
                    < (&pair[1].account_id, &pair[1].genesis_hash)
            }) {
                return Err(());
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;
