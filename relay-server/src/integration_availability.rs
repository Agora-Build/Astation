//! Built-in Station account state from a trusted checkpoint and subsequent feed changes.
use super::{Change, FeedBinding};
use crate::integration_checkpoint::{account_id, Accounts, PortalCheckpoint};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Availability {
    cursor: u64,
    caught_up: bool,
    complete: bool,
    disabled: BTreeSet<String>,
}

impl Availability {
    pub(super) fn from_checkpoint(cursor: u64, source: &Accounts) -> Self {
        Self {
            cursor,
            caught_up: true,
            complete: source.complete,
            disabled: source.disabled.iter().cloned().collect(),
        }
    }

    pub(super) fn valid_for(&self, binding: &FeedBinding) -> bool {
        PortalCheckpoint::built_in(binding)
            && self.cursor <= super::MAX_SAFE_INTEGER
            && self.disabled.iter().all(|id| account_id(id))
    }

    pub(super) fn enabled_at(&self, cursor: u64, owner: &str) -> bool {
        self.cursor == cursor
            && self.caught_up
            && self.complete
            && account_id(owner)
            && !self.disabled.contains(owner)
    }

    pub(super) fn advance(&mut self, from: u64, to: u64, changes: &[Change]) -> Result<(), ()> {
        // The exact checkpoint can be ahead of the ordinary paged feed. Its
        // prefix is already represented, and a skipped suffix needs a new cut.
        if from > self.cursor {
            return Err(());
        }
        for change in changes.iter().filter(|c| c.id > self.cursor) {
            let account_change = match change.kind.as_str() {
                "account_disabled" | "account_enabled" => true,
                "accounts_incomplete" | "accounts_baseline" => false,
                _ => continue,
            };
            if change.integration_id.is_some()
                || change.integration.is_some()
                || change.metadata.get("reason").and_then(Value::as_str) != Some("agora_build")
                || change.metadata.get("state") != Some(&Value::Null)
            {
                return Err(());
            }
            let account = change.metadata.get("account").ok_or(())?;
            if account_change {
                let id = account.as_str().filter(|id| account_id(id)).ok_or(())?;
                if change.kind == "account_disabled" {
                    self.disabled.insert(id.into());
                } else {
                    self.disabled.remove(id);
                }
            } else {
                if !account.is_null() {
                    return Err(());
                }
                self.complete = change.kind == "accounts_baseline";
            }
        }
        self.caught_up = changes.len() < super::PAGE_LIMIT && to >= self.cursor;
        self.cursor = self.cursor.max(to);
        Ok(())
    }
}
