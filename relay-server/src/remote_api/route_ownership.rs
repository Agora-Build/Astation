//! Ownership evidence for proved routes on the built-in Station.
use super::{invalid_root, Membership, Root};
use crate::auth::session_id_for_room;
use crate::identity_store::BINDING_TTL_SECS;
use crate::integration_checkpoint::account_id;
use crate::integration_feed::{FeedBinding, PolicyStore};
use serde_json::{json, Value};
use sqlx::PgConnection;
use std::collections::{BTreeMap, BTreeSet};

/// Called after checking the host proof, in the transaction that publishes its
/// route. The account comes from Station registration, never from the host.
pub(in crate::remote_api::recovery) async fn observe_session(
    connection: &mut PgConnection,
    scope: &FeedBinding,
    genesis: &str,
    session: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO station_proved_session_owners AS retained
           (station_origin,issuer,genesis_hash,session_id,account_subject,conflicted)
         SELECT $1,$2,$3,s.session_id::uuid,i.subject,
                direct.astation_id IS NOT NULL AND direct.agora_user <> a.agora_user
         FROM session_bindings s
         JOIN astation_accounts a ON a.astation_id=s.astation_id
         JOIN account_identities i ON i.principal=a.agora_user AND i.issuer=$2
         LEFT JOIN astation_accounts direct ON direct.astation_id='session-' || s.session_id
         WHERE s.session_id=$4 AND i.subject ~ '^ab[0-9A-HJKMNP-TV-Z]{26}$'
           AND s.last_used_at > floor(extract(epoch FROM statement_timestamp()))::bigint - $5
         ON CONFLICT (station_origin,issuer,genesis_hash,session_id)
         DO UPDATE SET conflicted=TRUE WHERE NOT retained.conflicted AND
             (retained.account_subject <> EXCLUDED.account_subject OR EXCLUDED.conflicted)",
    )
    .bind(&scope.station_origin)
    .bind(&scope.issuer)
    .bind(genesis)
    .bind(session)
    .bind(BINDING_TTL_SECS)
    .execute(connection)
    .await?;
    Ok(())
}

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

    let session_ids: Vec<_> = rooms
        .iter()
        .filter_map(|room| session_id_for_room(room))
        .collect();
    // The normal session resolver touches last_used_at. Inspect the binding
    // at the snapshot's timestamp without extending its lifetime.
    let sessions: BTreeMap<_, _> = sqlx::query_as::<_, (String, bool, Option<String>)>(
        "SELECT s.session_id,
           s.last_used_at > floor(extract(epoch FROM transaction_timestamp()))::bigint - $3 AS current,
           i.subject FROM session_bindings s
         LEFT JOIN astation_accounts a ON a.astation_id=s.astation_id
         LEFT JOIN account_identities i ON i.principal=a.agora_user AND i.issuer=$1
         WHERE s.session_id=ANY($2)",
    )
    .bind(&portal.issuer)
    .bind(&session_ids)
    .bind(BINDING_TTL_SECS)
    .fetch_all(&mut *connection)
    .await?
    .into_iter()
    .map(|(id, current, subject)| (id, (current, subject)))
    .collect();
    let retained: BTreeMap<_, _> = sqlx::query_as::<_, (String, String, bool)>(
        "SELECT session_id::text, account_subject, conflicted FROM station_proved_session_owners
         WHERE station_origin=$1 AND issuer=$2 AND genesis_hash=$3 AND session_id=ANY($4::text[]::uuid[])",
    )
    .bind(&portal.station_origin)
    .bind(&portal.issuer)
    .bind(&genesis)
    .bind(&session_ids)
    .fetch_all(&mut *connection)
    .await?
    .into_iter()
    .map(|(id, owner, conflict)| (id, (owner, conflict)))
    .collect();
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
        let (mut source, candidate) = match binding_state {
            "bound" => ("portal_binding", binding.map(|b| b.account.as_str())),
            "released" | "unbound" => ("no_bound_owner", None),
            "no_binding_in_checkpoint"
                if owner.is_some() && matches!(room_owner, "matches_root" | "unregistered") =>
            {
                ("recovery_root", owner)
            }
            _ => ("unresolved", None),
        };
        let mut row = json!({"host_id":host,"carrier":carrier,"proof":"verified",
            "registered_room_owner":room_owner});
        if let Some(id) = session_id_for_room(&route.room) {
            let session = sessions.get(id);
            let status = match session {
                None => "missing",
                Some((false, _)) => "expired",
                Some((true, Some(s))) if account_id(s) => "current",
                Some(_) => "unresolved",
            };
            row["session_binding"] = json!(status);
            if let Some(candidate) = candidate {
                let current_owner = session.and_then(|(_, owner)| owner.as_deref());
                let durable = retained.get(id);
                let conflict = registrations
                    .get(&route.room)
                    .is_some_and(|s| s.as_deref() != Some(candidate))
                    || session.is_some() && current_owner != Some(candidate)
                    || durable.is_some_and(|(owner, disputed)| *disputed || owner != candidate);
                if conflict || (status != "current" && durable.is_none()) {
                    source = "unresolved";
                } else if status != "current" {
                    source = "retained_session";
                }
            }
        }
        row["owner_source"] = json!(source);
        hosts.push(row);
    }
    Ok(
        json!({"root_owner_mapped":owner.is_some(),"last_observed_binding":binding_state,
        "binding_matches_root_owner":binding.and_then(|b|owner.map(|o|o == b.account)),
        "binding_version":binding.map(|row|row.version),"retained_routes":hosts}),
    )
}
