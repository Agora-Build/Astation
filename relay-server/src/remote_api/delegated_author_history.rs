//! Manager authority established by the signed list, including prior managers.
use atem_client::membership::{Action, MemberStatus, Membership, RecoveryState, Role, RolesChange};
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub(super) fn first_manage(log: &Membership) -> BTreeMap<&str, u64> {
    let mut authors = BTreeMap::new();
    for entry in log.entries() {
        let id = match &entry.action {
            Action::Genesis { member, .. } | Action::Add { member } if member.is_manager() => {
                &member.device_id
            }
            Action::RecoveryAdd { member }
                if member.is_manager()
                    && log
                        .record(&entry.hash())
                        .is_some_and(|r| r.state() == RecoveryState::Active) =>
            {
                &member.device_id
            }
            Action::SetRoles {
                device_id,
                change: RolesChange::Native(roles),
            } if roles.contains(&Role::Manage) => device_id,
            _ => continue,
        };
        authors.entry(id.as_str()).or_insert(entry.seq);
    }
    authors
}

pub(super) fn inventory(log: &Membership) -> BTreeMap<String, Value> {
    first_manage(log)
        .into_iter()
        .map(|(id, first)| {
            let status = if log.current_manager_key(id).is_some() {
                "manager"
            } else if log
                .member(id)
                .is_some_and(|m| m.status == MemberStatus::Active)
            {
                "demoted"
            } else {
                "removed"
            };
            (
                format!("member:{id}"),
                json!({"first_manage_seq":first, "member_status":status, "reports":[]}),
            )
        })
        .collect()
}

/// A journal ID survives an SDK process restart. Compare its signed creation
/// sequence and revision across plans without treating observations as a roster.
#[derive(Default)]
pub(super) struct JournalHistory {
    journals: BTreeMap<(String, [u8; 16]), JournalObservations>,
}

struct JournalObservations {
    first_since: u64,
    since_changed: bool,
    prior_revision: Option<u64>,
    current_revision: Option<u64>,
}

impl JournalHistory {
    pub(super) fn observe(
        &mut self,
        member: &str,
        id: [u8; 16],
        since: u64,
        revision: u64,
        current: bool,
    ) {
        let row = self
            .journals
            .entry((member.to_owned(), id))
            .or_insert(JournalObservations {
                first_since: since,
                since_changed: false,
                prior_revision: None,
                current_revision: None,
            });
        row.since_changed |= since != row.first_since;
        let highest = if current {
            &mut row.current_revision
        } else {
            &mut row.prior_revision
        };
        *highest = Some(highest.unwrap_or(0).max(revision));
    }

    pub(super) fn gaps(self) -> Vec<Value> {
        self.journals.into_iter().filter_map(|((member, id), row)| {
            let mut reasons = Vec::new();
            if row.since_changed { reasons.push("creation_sequence_changed"); }
            if let Some(prior) = row.prior_revision {
                match row.current_revision {
                    None => reasons.push("missing_current_report"),
                    Some(current) if current < prior => reasons.push("revision_below_prior_plan"),
                    _ => {}
                }
            }
            (!reasons.is_empty()).then(|| json!({
                "signer": member, "journal_id": atem_client::encoding::b64u(&id), "reasons": reasons,
                "highest_prior_revision": row.prior_revision, "highest_current_revision": row.current_revision
            }))
        }).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn journal_gaps_preserve_prior_revisions_and_distinguish_members_and_replaced_journals() {
        let mut history = JournalHistory::default();
        history.observe("member:a", [1; 16], 2, 11, false);
        history.observe("member:a", [1; 16], 2, 8, false);
        history.observe("member:a", [1; 16], 3, 10, true);
        history.observe("member:a", [2; 16], 2, 12, true);
        history.observe("member:b", [1; 16], 2, 0, false);
        history.observe("member:c", [3; 16], 1, 6, false);
        history.observe("member:c", [3; 16], 1, 6, true);
        let gaps = history.gaps();
        assert_eq!(gaps.len(), 2);
        assert_eq!(
            gaps[0]["reasons"],
            json!(["creation_sequence_changed", "revision_below_prior_plan"])
        );
        assert_eq!(gaps[0]["highest_prior_revision"], 11);
        assert_eq!(gaps[1]["signer"], "member:b");
        assert_eq!(gaps[1]["reasons"], json!(["missing_current_report"]));
        assert!(gaps[1]["highest_current_revision"].is_null());
    }
}
