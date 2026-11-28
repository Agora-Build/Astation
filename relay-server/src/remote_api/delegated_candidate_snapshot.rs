//! Reconstruct a candidate for operator review while the recovery fence is locked.
//! The participant check and atomic publication consume separate evidence.
use super::{invalid, service_components, snapshot_stops::StopSources, Prepared};
use crate::service_signing_ceilings::SigningMark;
use atem_client::{
    control::{ControlAction, ControlBody, ControlPrincipal, ControlRecord},
    membership::Membership,
};
use serde_json::Value;
use sqlx::PgConnection;
use std::collections::BTreeMap;

fn provisioned_keys(services: &Value) -> Result<Option<BTreeMap<String, String>>, sqlx::Error> {
    for field in [
        "prior_membership_keys",
        "registrations_without_membership",
        "portal_keys_without_attribution",
        "provisioning_without_fingerprint",
        "provisioned_without_membership",
    ] {
        if !services[field].as_array().ok_or_else(invalid)?.is_empty() {
            return Ok(None);
        }
    }
    for field in [
        "envelopes_without_provisioning",
        "prior_signing_registrations",
    ] {
        if let Some(value) = services.get(field) {
            if !value.as_array().ok_or_else(invalid)?.is_empty() {
                return Ok(None);
            }
        }
    }
    let mut provisioned = BTreeMap::new();
    for row in services["protected_service_keys"]
        .as_array()
        .ok_or_else(invalid)?
    {
        let id = row["service_id"].as_str().ok_or_else(invalid)?;
        let Some(key) = row["provisioning_fingerprint"].as_str() else {
            return Ok(None);
        };
        if !super::super::canonical_genesis(key) {
            return Err(invalid());
        }
        if provisioned.insert(id.into(), key.to_owned()).is_some() || row["status"] == "mismatch" {
            return Ok(None);
        }
    }
    Ok(Some(provisioned))
}

fn stop(record: &ControlRecord) -> bool {
    matches!(
        record.action(),
        ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. }
    )
}

/// Compare the issued signatures with today's required actions. Independent
/// reservations must still end exactly where this batch finished for each key.
fn matches_draft(
    records: &[ControlRecord],
    expected: &[ControlBody],
    review: &Value,
    provisioned: &BTreeMap<String, String>,
) -> Result<bool, sqlx::Error> {
    if records.len() != expected.len() {
        return Ok(false);
    }
    let mut last = BTreeMap::new();
    for (record, body) in records.iter().zip(expected) {
        let mut signed = record.body().clone();
        signed.record_id.clone_from(&body.record_id);
        signed.issued_at = body.issued_at;
        if &signed != body {
            return Ok(false);
        }
        let ControlPrincipal::Service(id) = record.principal() else {
            return Err(invalid());
        };
        let key = record.principal_key().ok_or_else(invalid)?.to_hex();
        if provisioned.get(id) != Some(&key) {
            return Ok(false);
        }
        last.insert(record.principal().name(), (key, record.issued_at()));
    }
    for (principal, (key, ms)) in last {
        let value = &review["service_clock_evidence"]["snapshot_signing_marks"][&principal];
        if value.is_null() {
            return Ok(false);
        }
        let mark: SigningMark = serde_json::from_value(value.clone()).map_err(|_| invalid())?;
        if mark.key_fingerprint != key || mark.highest_reserved_ms != ms || mark.sign_above_ms != ms
        {
            return Ok(false);
        }
    }
    Ok(true)
}

pub(super) enum Candidate {
    Waiting(&'static str),
    Assembled(Vec<ControlRecord>),
}

pub(super) async fn assemble(
    db: &mut PgConnection,
    plan: &Prepared,
    log: &Membership,
    origin: &str,
    review: &Value,
    sources: &StopSources,
) -> Result<Candidate, sqlx::Error> {
    let draft = &review["service_drafts"];
    if draft["status"] != "prepared" {
        return Ok(Candidate::Waiting("awaiting_service_review"));
    }
    let Some(provisioned) = provisioned_keys(&review["portal_service_evidence"])? else {
        return Ok(Candidate::Waiting("provisioning_unresolved"));
    };
    let expected = draft["unsigned_bodies"]
        .as_array()
        .ok_or_else(invalid)?
        .iter()
        .map(|body| ControlBody::from_json(body).map_err(|_| invalid()))
        .collect::<Result<Vec<_>, _>>()?;
    let mut fresh = Vec::new();
    let mut marks = BTreeMap::new();
    if !expected.is_empty() {
        let mut authors = super::reconstruction_inputs(review);
        authors
            .as_object_mut()
            .ok_or_else(invalid)?
            .remove("candidate_service_components_hash");
        for row in service_components::at_current_head(db, plan, log).await? {
            let cut = row.signing_cut.as_ref().ok_or_else(invalid)?;
            let portal = &review["portal_service_evidence"];
            let previous = &cut["portal_service_evidence"];
            if previous["binding"] != portal["binding"]
                || previous["policy_revision"] != portal["policy_revision"]
            {
                continue;
            }
            let mut original = cut["reconstruction"].clone();
            original
                .as_object_mut()
                .ok_or_else(invalid)?
                .remove("candidate_service_components_hash");
            if original != authors {
                continue;
            }
            // Every signed stop in storage participates independently as retained
            // history. Only a still-required fresh action belongs in this prefix.
            let records: Vec<_> = row
                .verify(plan, origin, log)?
                .into_iter()
                .filter(|record| {
                    !stop(record)
                        || expected.iter().any(|b| {
                            &b.principal == record.principal() && b.action == record.action()
                        })
                })
                .collect();
            if !matches_draft(&records, &expected, review, &provisioned)? {
                continue;
            }
            if !fresh.is_empty() {
                return Err(invalid());
            }
            for record in &records {
                let principal = record.principal().name();
                let mark: SigningMark = serde_json::from_value(
                    cut["service_clock_evidence"]["snapshot_signing_marks"][&principal].clone(),
                )
                .map_err(|_| invalid())?;
                marks.insert(principal, mark.sign_above_ms);
            }
            fresh = records;
        }
        if fresh.is_empty() {
            return Ok(Candidate::Waiting("awaiting_service_signatures"));
        }
    }
    let Some(records) = sources.with_services(log, origin, plan, &fresh, &provisioned, &marks)?
    else {
        return Ok(Candidate::Waiting("awaiting_stop_evidence"));
    };
    Ok(Candidate::Assembled(records))
}
