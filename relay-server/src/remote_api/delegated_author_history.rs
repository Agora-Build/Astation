//! Manager authority established by the signed list, including prior managers.
use atem_client::member_report::{JournalSummary, VerifiedSignerReport};
use atem_client::membership::{Action, Head, MemberStatus, Membership, RecoveryState, Role, RolesChange};
use atem_client::Hash32;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

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

#[derive(Default)]
pub(super) struct AuthorRound {
    // Reports arrive here in challenge order. A successor may report the
    // same exclusive journal, so keep its latest head and round per journal.
    signers: BTreeMap<String, BTreeMap<[u8; 16], Option<(Head, Hash32)>>>,
}

impl AuthorRound {
    pub(super) fn require(&mut self, signer: &str) {
        self.signers.entry(signer.to_owned()).or_default();
    }

    pub(super) fn observe(&mut self, report: &VerifiedSignerReport, current_plan: bool) {
        let journals = self.signers.entry(report.signer.clone()).or_default();
        let latest = journals.entry(report.journal.id).or_default();
        if current_plan {
            *latest = Some((report.head, report.recovery.evidence_hash()));
        }
    }

    pub(super) fn pending(&self, head: Head, base: Hash32) -> Vec<Value> {
        let mut pending = Vec::new();
        for (signer, journals) in &self.signers {
            if journals.is_empty() {
                pending.push(json!({"signer":signer,"journal_id":null,"reason":"no_report"}));
            }
            for (id, latest) in journals {
                let reason = match latest {
                    None => "missing_current_report",
                    Some((signed, _)) if *signed != head => "membership_changed",
                    Some((_, signed)) if *signed != base => "evidence_changed",
                    Some(_) => continue,
                };
                pending.push(json!({"signer":signer,"journal_id":atem_client::encoding::b64u(id),"reason":reason}));
            }
        }
        pending
    }
}

/// A journal ID survives an SDK process restart. Compare its signed creation
/// sequence and revision across plans without treating observations as a roster.
#[derive(Default)]
pub(super) struct JournalHistory {
    journals: BTreeMap<(String, [u8; 16]), JournalObservations>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct FrozenSets {
    records: u64,
    records_hash: Hash32,
    drafts: u64,
    drafts_hash: Hash32,
}

struct PlanObservations {
    sets: FrozenSets,
    lowest_revision: u64,
    highest_revision: u64,
}

struct JournalObservations {
    first_since: u64,
    since_changed: bool,
    prior_revision: Option<u64>,
    current_revision: Option<u64>,
    revisions: BTreeMap<u64, FrozenSets>,
    generations: BTreeMap<i64, PlanObservations>,
    first_export_generation: BTreeMap<String, i64>,
    missing_record_ids: BTreeSet<String>,
    revision_conflict: bool,
    barrier_conflict: bool,
}

impl JournalHistory {
    pub(super) fn observe<'a>(
        &mut self,
        member: &str,
        journal: &JournalSummary,
        generation: i64,
        current: bool,
        record_ids: impl IntoIterator<Item = &'a str>,
    ) {
        let revision = journal.revision;
        let sets = FrozenSets {
            records: journal.records,
            records_hash: journal.records_hash,
            drafts: journal.drafts,
            drafts_hash: journal.drafts_hash,
        };
        let row = self
            .journals
            .entry((member.to_owned(), journal.id))
            .or_insert(JournalObservations {
                first_since: journal.since,
                since_changed: false,
                prior_revision: None,
                current_revision: None,
                revisions: BTreeMap::new(),
                generations: BTreeMap::new(),
                first_export_generation: BTreeMap::new(),
                missing_record_ids: BTreeSet::new(),
                revision_conflict: false,
                barrier_conflict: false,
            });
        row.since_changed |= journal.since != row.first_since;
        // Every accepted report remains evidence. A later matching report cannot
        // erase a fork at one revision or changes to a plan's held inventory.
        row.revision_conflict |= *row.revisions.entry(revision).or_insert(sets) != sets;
        let plan = row.generations.entry(generation).or_insert(PlanObservations {
            sets, lowest_revision: revision, highest_revision: revision,
        });
        row.barrier_conflict |= plan.sets != sets;
        plan.lowest_revision = plan.lowest_revision.min(revision);
        plan.highest_revision = plan.highest_revision.max(revision);
        // Signed stops survive a plan ending. Unsigned drafts can be cancelled.
        let exported: BTreeSet<_> = record_ids.into_iter().collect();
        for (id, first) in &row.first_export_generation {
            if *first < generation && !exported.contains(id.as_str()) {
                row.missing_record_ids.insert(id.clone());
            }
        }
        for id in exported {
            if !row.first_export_generation.contains_key(id) {
                row.first_export_generation.insert(id.to_owned(), generation);
            }
        }
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
            if row.revision_conflict { reasons.push("conflicting_revision_contents"); }
            if row.barrier_conflict { reasons.push("held_inventory_changed"); }
            if !row.missing_record_ids.is_empty() { reasons.push("previous_export_missing"); }
            if row.prior_revision.is_some() && row.current_revision.is_none() {
                reasons.push("missing_current_report");
            }
            // Reports within one plan can arrive out of order. A new generation
            // follows every report in the earlier generations of this journal.
            let mut earlier_highest = 0;
            let regression = row.generations.iter().find_map(|(generation, plan)| {
                let prior = earlier_highest;
                earlier_highest = prior.max(plan.highest_revision);
                (plan.lowest_revision < prior).then(|| json!({
                    "generation": generation, "lowest_revision": plan.lowest_revision,
                    "highest_earlier_revision": prior
                }))
            });
            if regression.is_some() { reasons.push("revision_below_prior_plan"); }
            (!reasons.is_empty()).then(|| {
                let mut gap = json!({
                    "signer": member, "journal_id": atem_client::encoding::b64u(&id), "reasons": reasons,
                    "highest_prior_revision": row.prior_revision, "highest_current_revision": row.current_revision
                });
                if !row.missing_record_ids.is_empty() {
                    gap["missing_record_ids"] = json!(row.missing_record_ids);
                }
                if let Some(regression) = regression { gap["revision_regression"] = regression; }
                gap
            })
        }).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn summary(id: u8, since: u64, revision: u64) -> JournalSummary {
        JournalSummary {
            id: [id; 16],
            since,
            revision,
            records: 0,
            records_hash: Hash32::of(b"records"),
            drafts: 0,
            drafts_hash: Hash32::of(b"drafts"),
        }
    }

    #[test]
    fn later_confirmations_cannot_clear_contradictory_signed_inventory() {
        let mut history = JournalHistory::default();
        let frozen = summary(1, 1, 3);
        let mut changed = frozen.clone();
        changed.drafts_hash = Hash32::of(b"other drafts");
        history.observe("member:a", &frozen, 1, false, []);
        history.observe("member:a", &changed, 2, true, []);
        history.observe("member:a", &frozen, 2, true, []);
        changed.revision += 1;
        history.observe("member:b", &frozen, 1, false, []);
        history.observe("member:b", &changed, 2, true, []);
        history.observe("member:c", &frozen, 1, false, []);
        history.observe("member:c", &changed, 1, false, []);
        history.observe("member:c", &changed, 2, true, []);
        let gaps = history.gaps();
        assert_eq!(gaps.len(), 2);
        assert_eq!(gaps[0]["signer"], "member:a");
        assert_eq!(
            gaps[0]["reasons"],
            json!(["conflicting_revision_contents", "held_inventory_changed"])
        );
        assert_eq!(gaps[1]["signer"], "member:c");
        assert_eq!(gaps[1]["reasons"], json!(["held_inventory_changed"]));
    }

    #[test]
    fn a_new_plan_can_add_stops_and_drop_drafts_but_cannot_erase_an_older_signed_stop() {
        let mut history = JournalHistory::default();
        let mut journal = summary(1, 1, 3);
        journal.records = 1;
        journal.drafts = 2;
        history.observe("member:a", &journal, 1, false, ["a"]);
        journal.revision = 4;
        journal.records = 2;
        journal.drafts = 0;
        history.observe("member:a", &journal, 2, false, ["a", "b"]);
        journal.revision = 5;
        // A different member and a separately identified journal have independent histories.
        history.observe("member:b", &journal, 3, true, ["x", "y"]);
        let other = JournalSummary { id: [2; 16], ..journal.clone() };
        history.observe("member:a", &other, 3, true, ["x", "y"]);
        history.observe("member:a", &journal, 3, false, ["b", "c"]);
        journal.revision = 6;
        journal.records = 3;
        history.observe("member:a", &journal, 4, true, ["a", "b", "c"]);
        let gaps = history.gaps();
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0]["reasons"], json!(["previous_export_missing"]));
        assert_eq!(gaps[0]["missing_record_ids"], json!(["a"]));
    }

    #[test]
    fn a_later_report_cannot_erase_a_revision_rollback_between_plans() {
        for last_plan in [2, 3] {
            let mut history = JournalHistory::default();
            let mut report = |plan, revision| {
                history.observe("member:a", &summary(1, 1, revision), plan, plan == last_plan, []);
            };
            // Concurrent reports from one plan can arrive in either order.
            report(1, 8);
            report(1, 6);
            report(2, 12);
            report(2, 7);
            if last_plan == 3 { report(3, 14); }
            let gaps = history.gaps();
            assert_eq!(gaps.len(), 1);
            assert_eq!(gaps[0]["reasons"], json!(["revision_below_prior_plan"]));
            assert_eq!(gaps[0]["revision_regression"], json!({
                "generation": 2, "lowest_revision": 7, "highest_earlier_revision": 8
            }));
        }
        let mut in_order = JournalHistory::default();
        for (plan, revision) in [(1, 8), (1, 6), (2, 12), (2, 8)] {
            in_order.observe("member:a", &summary(1, 1, revision), plan, plan == 2, []);
        }
        assert!(in_order.gaps().is_empty());
    }

    #[test]
    fn journal_gaps_preserve_prior_revisions_and_distinguish_members_and_replaced_journals() {
        let mut history = JournalHistory::default();
        history.observe("member:a", &summary(1, 2, 11), 1, false, []);
        history.observe("member:a", &summary(1, 2, 8), 1, false, []);
        history.observe("member:a", &summary(1, 3, 10), 2, true, []);
        history.observe("member:a", &summary(2, 2, 12), 2, true, []);
        history.observe("member:b", &summary(1, 2, 0), 1, false, []);
        history.observe("member:c", &summary(3, 1, 6), 1, false, []);
        history.observe("member:c", &summary(3, 1, 6), 2, true, []);
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
