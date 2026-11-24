//! Inspect the durable sources for built-in Station room migration.
use super::{invalid_root, Membership, Root};
use crate::integration_checkpoint::account_id;
use crate::integration_feed::{FeedBinding, PolicyStore};
use serde_json::{json, Value};
use sqlx::PgConnection;
use std::collections::{BTreeMap, BTreeSet};

pub(super) async fn inspect(
    connection: &mut PgConnection,
    root: &Root,
    log: &Membership,
    principal: &str,
    portal: &FeedBinding,
) -> Result<Value, sqlx::Error> {
    let owner: Option<String> = sqlx::query_scalar(
        "SELECT subject FROM account_identities WHERE issuer=$1 AND principal=$2",
    )
    .bind(&portal.issuer)
    .bind(principal)
    .fetch_optional(&mut *connection)
    .await?;
    let owner = owner.as_deref().filter(|s| account_id(s));
    let policy = PolicyStore::load_in(connection, portal)
        .await
        .map_err(|_| invalid_root())?;
    let genesis = log.genesis_hash().to_hex();
    let binding = policy
        .portal_snapshot
        .as_ref()
        .and_then(|s| s.bindings.as_ref())
        .and_then(|rows| {
            rows.iter()
                .find(|r| r.account_id == root.account && r.genesis_hash == genesis)
        });
    let binding_state = match binding {
        Some(row) => row.binding_state.as_str(),
        None if policy.portal_snapshot.is_some() => "no_binding_in_checkpoint",
        None => "unobserved",
    };

    let mut rows = Vec::new();
    let mut rooms = BTreeSet::new();
    for (carrier, routes) in [("relay", &root.routes), ("proxy", &root.proxies)] {
        for (host, route) in routes {
            let proved = log.frozen().is_none()
                && route.host == *host
                && log
                    .host(host)
                    .is_some_and(|h| h.host_trust_gen == route.host_trust_gen)
                && route.proxy.is_some() == (carrier == "proxy")
                && route.valid(log);
            if proved {
                rooms.insert(route.room.as_str());
            }
            rows.push((carrier, host, route, proved));
        }
    }

    let registrations: BTreeMap<String, Option<String>> = sqlx::query_as(
        "SELECT a.astation_id,i.subject FROM astation_accounts a LEFT JOIN account_identities i
         ON i.principal=a.agora_user AND i.issuer=$1 WHERE a.astation_id=ANY($2)",
    )
    .bind(&portal.issuer)
    .bind(rooms.into_iter().collect::<Vec<_>>())
    .fetch_all(connection)
    .await?
    .into_iter()
    .collect();

    let mut hosts = Vec::with_capacity(rows.len());
    for (carrier, host, route, proved) in rows {
        if !proved {
            hosts.push(json!({"host_id":host,"carrier":carrier,"proof":"stale","owner_source":"unresolved"}));
            continue;
        }
        // A root owner and a registered room owner are independent evidence.
        // In particular, a migration cannot silently claim another owner's room.
        let room_owner = match registrations.get(&route.room) {
            None => "unregistered",
            Some(Some(room)) if account_id(room) => match owner {
                Some(root) if root == room => "matches_root",
                Some(_) => "differs_from_root",
                None => "registered",
            },
            Some(_) => "unresolved",
        };
        let source = match binding_state {
            "bound" => "portal_binding",
            "released" | "unbound" => "no_bound_owner",
            "no_binding_in_checkpoint"
                if owner.is_some() && matches!(room_owner, "matches_root" | "unregistered") =>
            {
                "recovery_root"
            }
            _ => "unresolved",
        };
        hosts.push(json!({"host_id":host,"carrier":carrier,"proof":"verified",
            "registered_room_owner":room_owner,"owner_source":source}));
    }
    Ok(
        json!({"root_owner_mapped":owner.is_some(),"last_observed_binding":binding_state,
        "binding_matches_root_owner":binding.and_then(|b|owner.map(|o|o == b.account)),
        "binding_version":binding.map(|row|row.version),"retained_routes":hosts}),
    )
}
