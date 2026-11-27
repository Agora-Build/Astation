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

impl super::PolicyCheckpoint {
    /// None means that the local baseline cannot establish this account's state.
    pub(crate) fn route_account_disabled(&self, owner: Option<&str>) -> Option<bool> {
        let view = self.availability.as_ref()?;
        if !view.current_at(self.cursor) || owner.is_some_and(|id| !account_id(id)) {
            return None;
        }
        Some(owner.is_some_and(|id| view.disabled.contains(id)))
    }
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
        self.current_at(cursor)
            && account_id(owner)
            && !self.disabled.contains(owner)
    }

    fn current_at(&self, cursor: u64) -> bool {
        self.cursor == cursor && self.caught_up && self.complete
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
            if change.integration_id != Some(None)
                || change.integration.is_some()
                || change.reason.as_ref().and_then(Value::as_str) != Some("agora_build")
                || change.state.as_ref() != Some(&Value::Null)
            {
                return Err(());
            }
            let account = change.account.as_ref().ok_or(())?;
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

/// Keep a credential-independent lower bound on the Portal cut used to release
/// work. A complete view can catch up to a peer's feed cursor. A known disable
/// or incomplete baseline requires a strictly later view.
pub(super) async fn retain_observation(
    tx: &mut sqlx::PgConnection,
    binding: &FeedBinding,
    feed_cursor: u64,
    view: Option<&Availability>,
) -> Result<(), ()> {
    let mut accounts: Vec<&str> = vec![""];
    let mut floors = vec![feed_cursor as i64];
    if let Some(view) = view {
        floors[0] = floors[0].max(view.cursor as i64 + i64::from(!view.complete));
        accounts.extend(view.disabled.iter().map(String::as_str));
        floors.resize(accounts.len(), view.cursor as i64 + 1);
    }
    sqlx::query(
        "INSERT INTO station_delegated_availability_fences AS f
         (issuer, portal_origin, station_origin, account, minimum_cursor)
         SELECT $1,$2,$3,account,floor FROM unnest($4::text[], $5::bigint[]) AS d(account,floor)
         ON CONFLICT (issuer,portal_origin,station_origin,account) DO UPDATE
         SET minimum_cursor=EXCLUDED.minimum_cursor WHERE f.minimum_cursor < EXCLUDED.minimum_cursor",
    )
    .bind(&binding.issuer).bind(&binding.portal_origin).bind(&binding.station_origin)
    .bind(accounts).bind(floors).execute(tx).await.map_err(|_| ())?;
    Ok(())
}
