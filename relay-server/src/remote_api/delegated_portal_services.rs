//! Per-device-list observations from the report client's recovery-generation checkpoint.
use super::super::super::delegated::ServiceDesired;
use super::{invalid, Binding};
use crate::integration_checkpoint::CheckpointIntegration;
use crate::integration_feed::{FeedBinding, PolicyCheckpoint};
use crate::service_keys::ServiceKeyContext;
use crate::service_signing_ceilings::Reservation;
use atem_client::membership::{
    service_key_fingerprint, Action, MemberKind, MemberStatus, Membership,
};
use serde_json::{json, Value};
use sqlx::PgConnection;
use std::collections::{BTreeMap, BTreeSet};

pub(super) async fn observe(
    connection: &mut PgConnection,
    fence: &Binding,
    portal: &FeedBinding,
    subject: &str,
    log: &Membership,
    registrations: Option<&[Reservation]>,
    review: &Value,
) -> Result<Value, sqlx::Error> {
    if portal.station_origin != fence.origin {
        return Err(invalid());
    }
    let saved: Option<String> = sqlx::query_scalar(
        "SELECT checkpoint FROM station_integration_policy WHERE binding=$1 AND recovery_generation=$2
         AND recovery_revision=(checkpoint::jsonb->>'revision')::numeric FOR SHARE NOWAIT",
    )
    .bind(portal.storage_key().map_err(|_| invalid())?)
    .bind(fence.generation)
    .fetch_optional(&mut *connection).await?;
    let Some(saved) = saved else {
        return Ok(json!({"status":"awaiting_checkpoint"}));
    };
    let policy: PolicyCheckpoint = serde_json::from_str(&saved).map_err(|_| invalid())?;
    if policy.binding != *portal || policy.portal_snapshot_revision != Some(policy.revision) {
        return Err(invalid());
    }
    let snapshot = policy.portal_snapshot.as_ref().ok_or_else(invalid)?;
    snapshot.validate_for(portal).map_err(|_| invalid())?;
    if policy.denied {
        return Ok(json!({"status":"reporting_denied"}));
    }
    let owners: Vec<String> = sqlx::query_scalar(
        "SELECT subject FROM account_identities WHERE issuer=$1 AND principal=$2 LIMIT 2",
    )
    .bind(&portal.issuer)
    .bind(subject)
    .fetch_all(&mut *connection)
    .await?;
    let [owner] = owners.as_slice() else {
        return Ok(json!({"status":"account_unresolved"}));
    };
    if !crate::integration_checkpoint::account_id(owner) {
        return Err(invalid());
    }

    let genesis = log.genesis_hash().to_hex();
    let can_release = snapshot
        .accounts
        .as_ref()
        .is_none_or(|accounts| accounts.enabled(owner))
        && policy.allows_list_release(owner, log.account_id(), &genesis);
    let policy = |id: &str, key: &str| {
        id.strip_prefix("svc-")
            .and_then(|id| snapshot.integrations.get(id))
            .filter(|row| {
                row.policy.owner_account == *owner && row.policy.r9_svc.as_deref() == Some(key)
            })
    };
    let observation = |id: &str, key: &str| match policy(id, key) {
        Some(row) => {
            json!({"state":row.policy.state, "interrupt_running":row.policy.interrupt_running,
            "revoked_at":row.revoked_at, "expires_at":row.policy.expires_at})
        }
        None => json!({"status":"unresolved"}),
    };

    let mut services = BTreeMap::new();
    for entry in log.entries() {
        let member = match &entry.action {
            Action::Add { member }
            | Action::RecoveryAdd { member }
            | Action::Genesis { member, .. }
                if matches!(member.kind, MemberKind::Service { .. }) =>
            {
                member
            }
            _ => continue,
        };
        let key = service_key_fingerprint(&member.auth_key).map_err(|_| invalid())?;
        let active = log.member(&member.device_id).is_some_and(|current| {
            current.status == MemberStatus::Active && current.member.auth_key == member.auth_key
        });
        services.insert((member.device_id.clone(), key), active);
    }
    // A restore may predate every membership entry for a service the Portal
    // still reports. The owner can have more than one R9 genesis.
    let portal_keys: BTreeSet<_> = snapshot
        .integrations
        .iter()
        .filter(|(_, row)| row.policy.owner_account == *owner)
        .filter_map(|(id, row)| Some((format!("svc-{id}"), row.policy.r9_svc.clone()?)))
        .collect();
    // A key may have been provisioned before either membership or Portal
    // learned its fingerprint. Enumerate this list independently of both.
    let scope = json!({"issuer":portal.issuer,"station_origin":fence.origin,"owner":owner,"genesis":genesis});
    let provisions: Vec<(String, String, Option<String>)> = sqlx::query_as(
        "SELECT CASE WHEN octet_length(integration_id)=28 THEN integration_id END,
                CASE WHEN octet_length(context)<=4096 THEN context END,
                CASE WHEN octet_length(fingerprint)>64 THEN '' ELSE fingerprint END
         FROM station_integration_provisioning
         WHERE binding=$1 AND context::jsonb @> $2 ORDER BY integration_id LIMIT 4097",
    )
    .bind(portal.storage_key().map_err(|_| invalid())?)
    .bind(scope)
    .fetch_all(&mut *connection)
    .await?;
    if provisions.len() > 4096 {
        return Err(invalid());
    }
    let mut managed_keys = BTreeSet::new();
    let mut pending = Vec::new();
    for (id, stored, key) in provisions {
        let context: ServiceKeyContext = serde_json::from_str(&stored).map_err(|_| invalid())?;
        if !crate::integration_feed::client_id(&id, "i-")
            || context.integration_id != id
            || context.service_id != format!("svc-{id}")
        {
            return Err(invalid());
        }
        match key {
            Some(key) if super::super::canonical_genesis(&key) => {
                managed_keys.insert((context.service_id, key));
            }
            None => pending.push(context.service_id),
            _ => return Err(invalid()),
        }
    }
    let mut attributed_keys: BTreeSet<_> = services.keys().chain(&managed_keys).cloned().collect();
    let stops = ServiceStops::from_review(review)?;
    let mut rows = Vec::with_capacity(services.len());
    for (identity @ (id, key), active) in &services {
        let known = stops.get(id.as_str()).copied().unwrap_or_default();
        let reconstruction = known.reconstruct(
            *active,
            managed_keys.contains(identity),
            policy(id, key),
            can_release,
        );
        rows.push(
            json!({"service_id":id,"key_fingerprint":key,"observation":observation(id,key),
            "snapshot_review":reconstruction}),
        );
    }

    // A registration may outlive an enrollment or its failed provisioning transaction.
    // Keep such keys outside signed membership, including unused registrations.
    if let Some(rows) = registrations {
        attributed_keys.extend(
            rows.iter()
                .map(|r| (r.service_id.clone(), r.key_hash.clone())),
        );
    }
    let unmatched = registrations.map(|rows| rows.iter().filter(|row|
        !services.contains_key(&(row.service_id.clone(), row.key_hash.clone())))
        .map(|row| json!({"service_id":row.service_id,"key_fingerprint":row.key_hash,
            "highest_reserved_ms":row.highest_ms,"portal_observation":observation(&row.service_id,&row.key_hash)}))
        .collect::<Vec<_>>());
    // A retained membership may be the last evidence of a service key when
    // both its current enrollment and its independent registration are missing.
    let mut historical = Vec::new();
    for row in review["known_history"]["observed_service_keys"]
        .as_array()
        .ok_or_else(invalid)?
    {
        let id = row["service_id"].as_str().ok_or_else(invalid)?;
        let key = row["key_fingerprint"].as_str().ok_or_else(invalid)?;
        let identity = (id.to_owned(), key.to_owned());
        attributed_keys.insert(identity.clone());
        if !services.contains_key(&identity) {
            historical.push(json!({"service_id":id,"key_fingerprint":key,
                "highest_signed_ms":row["highest_signed_ms"],"portal_observation":observation(id,key)}));
        }
    }
    let provisioned: Vec<_> = managed_keys
        .iter()
        .filter(|identity| !services.contains_key(*identity))
        .map(|(id, key)| {
            json!({"service_id":id,"key_fingerprint":key,
            "portal_observation":observation(id,key)})
        })
        .collect();
    // Portal identifies the Agora.Build owner but does not identify an R9
    // genesis for a service. Keep these out of this list's signing inputs.
    let unattributed: Vec<_> = portal_keys
        .difference(&attributed_keys)
        .map(|(id, key)| {
            json!({"service_id":id,"key_fingerprint":key,
            "portal_observation":observation(id,key)})
        })
        .collect();
    let mut evidence = json!({"status":"observed","binding":portal,"cursor":snapshot.cursor,"at":snapshot.at,
        "generation":fence.generation.to_string(),"account_id":log.account_id(),"genesis_hash":genesis,
        "membership_head":log.head().to_json(),"registrations_without_membership":unmatched,
        "prior_membership_keys":historical,"provisioned_without_membership":provisioned,
        "provisioning_without_fingerprint":pending,
        "portal_keys_without_attribution":unattributed,"services":rows});
    if let (Some(bindings), Some(accounts)) = (&snapshot.bindings, &snapshot.accounts) {
        // A binding can advance without a feed event. Only commit this
        // owner's record for the exact R9 account and genesis to the review.
        let binding = bindings.iter().find(|row| {
            row.account_id == log.account_id()
                && row.genesis_hash == genesis
                && row.account == *owner
        });
        evidence["owner_binding"] = binding.map_or_else(
            || json!({"status":"unresolved"}),
            |row| json!({"status":"observed","binding_id":row.binding_id,"version":row.version,"state":row.binding_state}),
        );
        evidence["owner_availability"] = if accounts.disabled.contains(owner) {
            "disabled"
        } else if accounts.enabled(owner) {
            "enabled"
        } else {
            "unknown"
        }
        .into();
    }
    Ok(evidence)
}

#[derive(Clone, Copy, Default)]
struct ServiceStops {
    unresolved: bool,
    revoked: bool,
    own_revoke: bool,
    own_interrupt: bool,
}

impl ServiceStops {
    fn from_review(review: &Value) -> Result<BTreeMap<&str, Self>, sqlx::Error> {
        let mut replaced = BTreeSet::new();
        for row in review["recovery_signatures"]["known_native_obligations"]
            .as_array()
            .ok_or_else(invalid)?
        {
            if row["requirement"] == "signed_copy_retained" {
                replaced.insert(row["original"]["record_id"].as_str().ok_or_else(invalid)?);
            }
        }
        let mut stops = BTreeMap::<&str, Self>::new();
        for record in review["known_history"]["records"]
            .as_array()
            .ok_or_else(invalid)?
        {
            let principal = record["principal"].as_str().ok_or_else(invalid)?;
            let Some(service) = principal.strip_prefix("service:") else {
                continue;
            };
            let revoke = record["action"] == "revoke";
            if !revoke && record["action"] != "interrupt_running" {
                continue;
            }
            let facts = stops.entry(service).or_default();
            if record["verification"] != "valid"
                && !(record["verification"] == "removed_manager"
                    && replaced.contains(record["record_id"].as_str().ok_or_else(invalid)?))
            {
                facts.unresolved = true;
                continue;
            }
            facts.revoked |= revoke;
            if record["signer"] == principal {
                facts.own_revoke |= revoke;
                facts.own_interrupt |= record["interrupt_running"] == true;
            }
        }
        Ok(stops)
    }

    fn reconstruct(
        self,
        active: bool,
        provisioned: bool,
        row: Option<&CheckpointIntegration>,
        can_release: bool,
    ) -> Value {
        if !provisioned {
            return json!({"status":"provisioning_unresolved"});
        }
        let Some(row) = row else {
            return json!({"status":"policy_unresolved"});
        };
        if self.unresolved {
            return json!({"status":"stop_authority_review"});
        }
        let desired = ServiceDesired::from_policy(&row.policy);
        if self.revoked || matches!(desired, Some(ServiceDesired::Revoked { .. })) {
            // A terminal stop applies even after membership removal. Neither
            // that stop nor the provisioned key decides current coverage.
            let stops = match desired {
                Some(ServiceDesired::Revoked { interrupt_running }) if !self.own_revoke => {
                    json!([{"action":"revoke","interrupt_running":interrupt_running}])
                }
                Some(ServiceDesired::Revoked {
                    interrupt_running: true,
                }) if !self.own_interrupt => {
                    json!([{"action":"interrupt_running"}])
                }
                _ => json!([]),
            };
            return json!({"status":"coverage_unresolved","fresh_stop_actions":stops});
        }
        if !active {
            return json!({"status":"membership_inactive"});
        }
        let actions = match desired {
            Some(ServiceDesired::Held) => json!([{"action":"cover"},{"action":"hold"}]),
            Some(ServiceDesired::Active) => {
                if !can_release {
                    return json!({"status":"owner_availability_unresolved"});
                }
                json!([{"action":"cover"},{"action":"release"}])
            }
            // Expiry can mask a pre-existing pause, and never authorizes a release.
            None if row.policy.state == "expired" => {
                return json!({"status":"pre_expiry_state_unresolved"})
            }
            _ => return json!({"status":"coverage_unresolved"}),
        };
        json!({"status":"reviewed","fresh_actions":actions})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn portal_resume_does_not_release_a_retained_or_replaced_manager_revoke() {
        let mut review = json!({
            "known_history":{"records":[{"principal":"service:svc-a","record_id":"original",
                "verification":"valid","signer":"member:manager","action":"revoke","interrupt_running":false}]},
            "recovery_signatures":{"known_native_obligations":[]}
        });
        let mut row: CheckpointIntegration = serde_json::from_value(json!({"policy":{
            "ownerAccount":"ab01234567890123456789012345","state":"ready","scopes":["agent.view"],
            "r9Svc":"a".repeat(64),"expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10},
            "revoked_at":null}))
        .unwrap();
        let actions = |review: &Value, row: &CheckpointIntegration| {
            ServiceStops::from_review(review).unwrap()["svc-a"].reconstruct(
                true,
                true,
                Some(row),
                true,
            )
        };
        assert_eq!(actions(&review, &row)["fresh_stop_actions"], json!([]));
        review["known_history"]["records"][0]["verification"] = "removed_manager".into();
        assert_eq!(actions(&review, &row)["status"], "stop_authority_review");
        review["recovery_signatures"]["known_native_obligations"] =
            json!([{"original":{"record_id":"original"},"requirement":"signed_copy_retained"}]);
        assert_eq!(actions(&review, &row)["fresh_stop_actions"], json!([]));

        row.policy.state = "revoked".into();
        row.policy.interrupt_running = Some(true);
        assert_eq!(
            actions(&review, &row)["fresh_stop_actions"],
            json!([{"action":"revoke","interrupt_running":true}])
        );
        let original = &mut review["known_history"]["records"][0];
        original["signer"] = "service:svc-a".into();
        original["verification"] = "valid".into();
        assert_eq!(
            actions(&review, &row)["fresh_stop_actions"],
            json!([{"action":"interrupt_running"}])
        );
        review["known_history"]["records"][0]["interrupt_running"] = true.into();
        assert_eq!(actions(&review, &row)["fresh_stop_actions"], json!([]));

        assert_eq!(actions(&review, &row)["status"], "coverage_unresolved");
        assert!(actions(&review, &row).get("fresh_actions").is_none());

        row.policy.state = "ready".into();
        assert_eq!(
            ServiceStops::default().reconstruct(true, true, Some(&row), false)["status"],
            "owner_availability_unresolved"
        );
    }
}
