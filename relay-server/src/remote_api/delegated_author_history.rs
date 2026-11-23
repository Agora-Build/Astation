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
