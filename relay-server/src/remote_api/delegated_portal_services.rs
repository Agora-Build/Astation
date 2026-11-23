//! Per-device-list observations from the report client's recovery-generation checkpoint.
use super::{invalid, Binding};
use crate::integration_feed::{FeedBinding, PolicyCheckpoint};
use crate::service_signing_ceilings::Reservation;
use atem_client::membership::{service_key_fingerprint, Action, MemberKind, Membership};
use serde_json::{json, Value};
use sqlx::PgConnection;
use std::collections::BTreeMap;

pub(super) async fn observe(
    connection: &mut PgConnection,
    fence: &Binding,
    portal: &FeedBinding,
    subject: &str,
    log: &Membership,
    registrations: Option<&[Reservation]>,
) -> Result<Value, sqlx::Error> {
    if portal.station_origin != fence.origin {
        return Err(invalid());
    }
    let saved: Option<String> = sqlx::query_scalar(
        "SELECT checkpoint FROM station_integration_policy WHERE binding=$1 AND recovery_generation=$2
         AND recovery_revision=(checkpoint::jsonb->>'revision')::numeric",
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
    let snapshot = policy.portal_snapshot.ok_or_else(invalid)?;
    snapshot.validate_for(portal).map_err(|_| invalid())?;
    if policy.denied {
        return Ok(json!({"status":"reporting_denied"}));
    }
    let owners: Vec<String> = sqlx::query_scalar(
        "SELECT subject FROM account_identities WHERE issuer=$1 AND principal=$2 LIMIT 2",
    )
    .bind(&portal.issuer)
    .bind(subject)
    .fetch_all(connection)
    .await?;
    let [owner] = owners.as_slice() else {
        return Ok(json!({"status":"account_unresolved"}));
    };
    if !crate::integration_checkpoint::account_id(owner) {
        return Err(invalid());
    }

    let observation = |id: &str, fingerprint: &str| {
        let policy = id
            .strip_prefix("svc-")
            .and_then(|id| snapshot.integrations.get(id))
            .filter(|row| {
                row.policy.owner_account == *owner
                    && row.policy.r9_svc.as_deref() == Some(fingerprint)
            });
        match policy {
            Some(row) => json!({
                "state":row.policy.state,"interrupt_running":row.policy.interrupt_running,
                "revoked_at":row.revoked_at,"expires_at":row.policy.expires_at
            }),
            None => json!({"status":"unresolved"}),
        }
    };
    let mut services = BTreeMap::new();
    for entry in log.entries() {
        let member = match &entry.action {
            Action::Add { member } | Action::RecoveryAdd { member }
                if matches!(member.kind, MemberKind::Service { .. }) =>
            {
                member
            }
            _ => continue,
        };
        let fingerprint = service_key_fingerprint(&member.auth_key).map_err(|_| invalid())?;
        let observed = observation(&member.device_id, &fingerprint);
        services.insert((member.device_id.clone(), fingerprint), observed);
    }
    // A registration may outlive an enrollment or its failed provisioning transaction.
    // Keep such keys outside signed membership, including unused registrations.
    let unmatched = registrations.map(|rows| rows.iter().filter(|row|
        !services.contains_key(&(row.service_id.clone(), row.key_hash.clone())))
        .map(|row| json!({"service_id":row.service_id,"key_fingerprint":row.key_hash,
            "highest_reserved_ms":row.highest_ms,"portal_observation":observation(&row.service_id,&row.key_hash)}))
        .collect::<Vec<_>>());
    Ok(
        json!({"status":"observed","binding":portal,"cursor":snapshot.cursor,"at":snapshot.at,
        "generation":fence.generation.to_string(),"account_id":log.account_id(),"genesis_hash":log.genesis_hash().to_hex(),
        "membership_head":log.head().to_json(),"registrations_without_membership":unmatched,
        "services":services.into_iter().map(|((id,key),observation)| json!({
            "service_id":id,"key_fingerprint":key,"observation":observation
        })).collect::<Vec<_>>()}),
    )
}
