//! Read-only comparison of the Mac's protected process list and retained author reports.
use super::{checkpoint, invalid, review_evidence, Binding};
use atem_client::{
    canonical::StrictValue,
    encoding::b64u_decode_array,
    membership::{Head, Membership},
    session::wire::is_opaque_id,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::PgPool;
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const INPUT_LIMIT: usize = 4 * 1024 * 1024;

#[derive(Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Slot {
    member: String,
    slot: String,
    process: String,
    review_head: Value,
    selected: bool,
}

#[derive(Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Export {
    version: u8,
    account_id: String,
    genesis_hash: String,
    origin: String,
    generation: String,
    plan_id: String,
    candidate_feed_id: String,
    source_hash: String,
    evidence_hash: String,
    reconstruction_hash: String,
    membership_head: Value,
    slots: Vec<Slot>,
}

fn combine(inputs: &[Vec<u8>]) -> Result<Export, sqlx::Error> {
    let mut remaining = INPUT_LIMIT;
    let mut scope = None;
    let mut members = BTreeMap::<String, Vec<Slot>>::new();
    for bytes in inputs {
        remaining = remaining.checked_sub(bytes.len()).ok_or_else(invalid)?;
        let strict = StrictValue::parse(bytes, INPUT_LIMIT).map_err(|_| invalid())?;
        let mut export: Export =
            serde_json::from_value(strict.into_value()).map_err(|_| invalid())?;
        let mut reviewed = BTreeMap::<String, Vec<Slot>>::new();
        for row in std::mem::take(&mut export.slots) {
            reviewed.entry(row.member.clone()).or_default().push(row);
        }
        if scope.as_ref().is_some_and(|prior| prior != &export) {
            return Err(invalid());
        }
        scope = Some(export);
        for (member, mut slots) in reviewed {
            slots.sort_by(|a, b| {
                (&a.slot, &a.process, a.selected).cmp(&(&b.slot, &b.process, b.selected))
            });
            // Two views of one member must agree before either can represent
            // it in a combined review. Duplicate rows within a file remain
            // visible to the normal slot validator.
            if let Some(other) = members.get(&member) {
                if other != &slots {
                    return Err(sqlx::Error::Protocol(
                        "conflicting recovery process lists for the same member".into(),
                    ));
                }
            } else {
                members.insert(member, slots);
            }
        }
    }
    let mut export = scope.ok_or_else(invalid)?;
    export.slots = members.into_values().flatten().collect();
    Ok(export)
}

pub(crate) async fn compare(
    pool: &PgPool,
    binding: &Binding,
    genesis: &str,
    plan: &str,
    inputs: &[Vec<u8>],
) -> Result<Value, sqlx::Error> {
    let export = combine(inputs)?;
    if export.version != 1
        || export.origin != binding.origin
        || export.genesis_hash != genesis
        || export.plan_id != plan
        || export.generation != binding.generation.to_string()
        || export.slots.len() > 8192
    {
        return Err(invalid());
    }
    let mut tx = pool.begin().await?;
    let (prepared, log, mut report) = checkpoint(&mut tx, binding, genesis, false).await?;
    if prepared.plan_id != plan
        || export.account_id != log.account_id()
        || export.membership_head != log.head().to_json()
        || export.source_hash != prepared.source_hash
        || export.candidate_feed_id != prepared.candidate_feed_id
    {
        return Err(invalid());
    }
    review_evidence(&mut tx, &prepared, &log, binding, &mut report, true).await?;
    if report["evidence_hash"] != export.evidence_hash
        || report["reconstruction_hash"] != export.reconstruction_hash
    {
        return Err(invalid());
    }
    let mut comparison = compare_members(
        &log,
        &report["known_authors"],
        &export.evidence_hash,
        export.slots,
    )?;
    comparison["origin"] = json!(binding.origin);
    comparison["genesis_hash"] = json!(genesis);
    comparison["plan_id"] = json!(plan);
    comparison["reconstruction_hash"] = json!(export.reconstruction_hash);
    tx.commit().await?;
    Ok(comparison)
}

type Process = (String, String, String);

fn observations(
    authors: &Value,
    members: &mut BTreeSet<String>,
    processes: &mut BTreeSet<Process>,
) -> Result<(), sqlx::Error> {
    for (signer, author) in authors.as_object().ok_or_else(invalid)? {
        let member = signer.strip_prefix("member:").ok_or_else(invalid)?;
        members.insert(member.to_owned());
        for report in author["reports"].as_array().ok_or_else(invalid)? {
            processes.insert((
                member.into(),
                report["slot"].as_str().ok_or_else(invalid)?.into(),
                report["process"].as_str().ok_or_else(invalid)?.into(),
            ));
        }
    }
    Ok(())
}

fn describe((member, slot, process): &Process) -> Value {
    json!({"member": member, "slot": slot, "process": process})
}

fn compare_members(
    log: &Membership,
    authors: &Value,
    evidence_hash: &str,
    slots: Vec<Slot>,
) -> Result<Value, sqlx::Error> {
    let mut managers = BTreeSet::new();
    let mut current = BTreeSet::new();
    observations(&authors["members"], &mut managers, &mut current)?;
    let mut observed = current.clone();
    for prior in authors["prior_plans"].as_array().ok_or_else(invalid)? {
        observations(&prior["members"], &mut managers, &mut observed)?;
    }
    let mut reviewed = BTreeSet::new();
    let mut current_rosters = BTreeSet::new();
    let mut selected_slots = BTreeSet::new();
    let mut selected_heads = BTreeMap::new();
    let mut retired_slots = BTreeSet::new();
    let mut selected_processes = BTreeSet::new();
    let mut ambiguous = BTreeSet::new();
    for slot in slots {
        let head = Head::from_json(&slot.review_head).ok_or_else(invalid)?;
        let index = usize::try_from(head.seq - 1).map_err(|_| invalid())?;
        if !log
            .entries()
            .get(index)
            .is_some_and(|entry| entry.hash() == head.hash)
            || !is_opaque_id(&slot.member)
            || !is_opaque_id(&slot.slot)
            || b64u_decode_array::<16>(&slot.process).is_err()
            || !log.member(&slot.member).is_some_and(|m| {
                matches!(
                    m.member.kind,
                    atem_client::membership::MemberKind::Native { .. }
                )
            })
        {
            return Err(invalid());
        }
        if slot.selected {
            if !selected_slots.insert((slot.member.clone(), slot.slot.clone()))
                || selected_heads
                    .insert(slot.member.clone(), head)
                    .is_some_and(|previous| previous != head)
            {
                return Err(invalid());
            }
            if !selected_processes.insert((slot.member.clone(), slot.process.clone())) {
                ambiguous.insert((slot.member.clone(), slot.process.clone()));
            }
            if head == log.head() {
                current_rosters.insert(slot.member.clone());
            }
        } else if !retired_slots.insert((
            slot.member.clone(),
            slot.slot.clone(),
            slot.process.clone(),
        )) {
            return Err(invalid());
        }
        if managers.contains(&slot.member) {
            reviewed.insert((slot.member, slot.slot, slot.process));
        }
    }
    let mut missing_early_ranges = Vec::new();
    let mut latest = BTreeMap::new();
    for (signer, member) in authors["members"].as_object().ok_or_else(invalid)? {
        let id = signer.strip_prefix("member:").ok_or_else(invalid)?;
        for report in member["reports"].as_array().ok_or_else(invalid)? {
            // Reports are read in ascending Station connection order within this plan.
            let process = (
                id.to_owned(),
                report["slot"].as_str().ok_or_else(invalid)?.to_owned(),
                report["process"].as_str().ok_or_else(invalid)?.to_owned(),
            );
            latest.insert(
                process,
                report["signed_evidence_hash"]
                    .as_str()
                    .ok_or_else(invalid)?,
            );
            if report["missing_early_range"] == true {
                missing_early_ranges.push(json!({"signer": signer, "slot": report["slot"],
                    "process": report["process"], "submission_hash": report["submission_hash"]}));
            }
        }
    }
    let confirmed: BTreeSet<_> = latest
        .into_iter()
        .filter_map(|(p, hash)| (hash == evidence_hash).then_some(p))
        .collect();
    Ok(json!({
        "reviewed_without_current_confirmation": reviewed.difference(&confirmed).map(describe).collect::<Vec<_>>(),
        "matching_evidence_confirmations": reviewed.intersection(&confirmed).map(describe).collect::<Vec<_>>(),
        "missing_current_roster": managers.difference(&current_rosters).collect::<Vec<_>>(),
        "reviewed_without_current_report": reviewed.difference(&current).map(describe).collect::<Vec<_>>(),
        "reported_outside_review": observed.difference(&reviewed).map(describe).collect::<Vec<_>>(),
        "matching_current_reports": reviewed.intersection(&current).map(describe).collect::<Vec<_>>(),
        "ambiguous_selected_processes": ambiguous.into_iter().filter(|(m,_)| managers.contains(m))
            .map(|(member,process)| json!({"member":member,"process":process})).collect::<Vec<_>>(),
        "reports_missing_early_range": missing_early_ranges,
        "journal_gaps": authors["journal_gaps"], "complete_history": false, "recovery_ready": false,
    }))
}
