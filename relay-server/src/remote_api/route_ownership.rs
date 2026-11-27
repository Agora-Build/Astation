//! Ownership evidence for proved routes on the built-in Station.
use super::super::{HostBinding, RouteService};
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
pub(in crate::remote_api::recovery) async fn observe(
    connection: &mut PgConnection,
    origin: &str,
    issuer: &str,
    genesis: &str,
    rooms: &[&str],
) -> Result<(), sqlx::Error> {
    if rooms.is_empty() {
        return Ok(());
    }
    let sessions: Vec<_> = rooms.iter().map(|room| session_id_for_room(room)).collect();
    sqlx::query(
        "INSERT INTO station_proved_room_owners AS retained
           (station_origin,issuer,genesis_hash,room,account_subject,conflicted)
         SELECT $1,$2,$3,r.room,i.subject,
                direct.astation_id IS NOT NULL AND direct.agora_user <> a.agora_user
         FROM unnest($4::text[], $5::text[]) AS r(room, session)
         LEFT JOIN session_bindings s ON s.session_id=r.session
           AND s.last_used_at > floor(extract(epoch FROM statement_timestamp()))::bigint - $6
         JOIN astation_accounts a ON a.astation_id=CASE WHEN r.session IS NULL THEN r.room ELSE s.astation_id END
         JOIN account_identities i ON i.principal=a.agora_user AND i.issuer=$2
         LEFT JOIN astation_accounts direct ON direct.astation_id=r.room
         WHERE i.subject ~ '^ab[0-9A-HJKMNP-TV-Z]{26}$'
         ON CONFLICT (station_origin,issuer,genesis_hash,room)
         DO UPDATE SET conflicted=TRUE WHERE NOT retained.conflicted AND
             (retained.account_subject <> EXCLUDED.account_subject OR EXCLUDED.conflicted)",
    )
    .bind(origin)
    .bind(issuer)
    .bind(genesis)
    .bind(rooms)
    .bind(sessions)
    .bind(BINDING_TTL_SECS)
    .execute(connection)
    .await?;
    Ok(())
}

// Serialize proof publication and a registration that can supply its owner.
// Both take room locks before root locks, including when the proof is new.
pub(in crate::remote_api::recovery) async fn lock_rooms(
    connection: &mut PgConnection,
    rooms: &[&str],
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "SELECT pg_advisory_xact_lock(hashtextextended(room, 739185))
         FROM unnest($1::text[]) AS r(room) ORDER BY room COLLATE \"C\"",
    )
    .bind(rooms)
    .execute(connection)
    .await?;
    Ok(())
}

pub(in crate::remote_api::recovery) async fn index_proof(
    connection: &mut PgConnection,
    origin: &str,
    issuer: &str,
    route: &HostBinding,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO station_room_proofs (station_origin,issuer,genesis_hash,host_id,carrier,room,nonce)
         VALUES ($1,$2,$3,$4,$5,$6,$7)
         ON CONFLICT (station_origin,issuer,genesis_hash,host_id,carrier)
         DO UPDATE SET room=EXCLUDED.room, nonce=EXCLUDED.nonce",
    )
    .bind(origin).bind(issuer).bind(&route.genesis).bind(&route.host)
    .bind(if route.proxy.is_some() { "proxy" } else { "relay" })
    .bind(&route.room).bind(route.nonce.as_slice()).execute(connection).await?;
    Ok(())
}

pub(crate) async fn observe_registration(
    connection: &mut PgConnection,
    origin: &str,
    issuer: &str,
    astation: &str,
) -> Result<(), sqlx::Error> {
    let sessions: Vec<String> = sqlx::query_scalar(
        "SELECT session_id FROM session_bindings WHERE astation_id=$1
         AND last_used_at > floor(extract(epoch FROM statement_timestamp()))::bigint - $2",
    )
    .bind(astation)
    .bind(BINDING_TTL_SECS)
    .fetch_all(&mut *connection)
    .await?;
    let mut rooms = BTreeSet::from([astation.to_owned()]);
    for session in sessions {
        let room = format!("{}{session}", crate::auth::SESSION_ROOM_PREFIX);
        if session_id_for_room(&room).is_some() {
            rooms.insert(room);
        }
    }
    observe_rooms(connection, origin, issuer, &rooms).await
}

#[derive(sqlx::FromRow)]
struct RoomProof {
    genesis_hash: String,
    host_id: String,
    carrier: String,
    room: String,
    nonce: Vec<u8>,
}

pub(crate) async fn observe_rooms(
    connection: &mut PgConnection,
    origin: &str,
    issuer: &str,
    rooms: &BTreeSet<String>,
) -> Result<(), sqlx::Error> {
    if rooms.is_empty() {
        return Ok(());
    }
    let rooms: Vec<_> = rooms.iter().map(String::as_str).collect();
    lock_rooms(connection, &rooms).await?;
    let candidates: Vec<RoomProof> = sqlx::query_as(
        "SELECT genesis_hash,host_id,carrier,room,nonce FROM station_room_proofs
         WHERE station_origin=$1 AND issuer=$2 AND room=ANY($3) ORDER BY genesis_hash",
    )
    .bind(origin)
    .bind(issuer)
    .bind(&rooms)
    .fetch_all(&mut *connection)
    .await?;
    for group in candidates.chunk_by(|a, b| a.genesis_hash == b.genesis_hash) {
        let genesis = &group[0].genesis_hash;
        let state = load_root(connection, genesis).await?;
        let Some((root, log)) = state.and_then(|value| validated_root(genesis, value).ok()) else {
            tracing::warn!("Skipping uninspectable proved room during account registration");
            continue;
        };
        let mut current = BTreeSet::new();
        for candidate in group {
            let routes = if candidate.carrier == "proxy" {
                &root.proxies
            } else {
                &root.routes
            };
            if routes.get(&candidate.host_id).is_some_and(|route| {
                route.room == candidate.room
                    && route.nonce.as_slice() == candidate.nonce
                    && verified(&log, &candidate.host_id, &candidate.carrier, route)
            }) {
                current.insert(candidate.room.as_str());
            }
        }
        let current: Vec<_> = current.into_iter().collect();
        observe(connection, origin, issuer, genesis, &current).await?;
    }
    Ok(())
}

async fn load_root(
    connection: &mut PgConnection,
    genesis: &str,
) -> Result<Option<Value>, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT CASE WHEN octet_length(state::text) <= $2 THEN state END
         FROM remote_recovery_roots WHERE genesis_hash=$1 FOR UPDATE",
    )
    .bind(genesis)
    .bind(super::MAX_STATE as i64)
    .fetch_optional(connection)
    .await
    .map(Option::flatten)
}

fn validated_root(genesis: &str, state: Value) -> Result<(Root, Membership), sqlx::Error> {
    let root: Root = serde_json::from_value(state).map_err(|_| invalid_root())?;
    let hash = atem_client::Hash32::from_hex(genesis).map_err(|_| invalid_root())?;
    let mut log = Membership::from_stored(&root.account, &hash, &root.membership)
        .map_err(|_| invalid_root())?;
    log.advance(&crate::remote_api::recovery::now());
    Ok((root, log))
}

fn verified(log: &Membership, host: &str, carrier: &str, route: &HostBinding) -> bool {
    log.frozen().is_none()
        && route.host == host
        && route.proxy.is_some() == (carrier == "proxy")
        && route.valid(log)
}

fn routes<'a>(
    root: &'a Root,
    log: &'a Membership,
) -> impl Iterator<Item = (&'static str, &'a String, &'a HostBinding, bool)> + 'a {
    [("relay", &root.routes), ("proxy", &root.proxies)]
        .into_iter()
        .flat_map(move |(carrier, routes)| {
            routes.iter().map(move |(host, route)| {
                let proved = verified(log, host, carrier, route);
                (carrier, host, route, proved)
            })
        })
}

pub(crate) async fn migrate(
    pool: &sqlx::PgPool,
    origin: &str,
    issuer: &str,
    genesis: &str,
) -> Result<Value, sqlx::Error> {
    if !super::canonical_genesis(genesis)
        || !crate::account_identity::built_in_station(origin)
        || !crate::account_identity::station_origin(issuer)
    {
        return Err(invalid_root());
    }
    let mut tx = pool.begin().await?;
    sqlx::query("SET LOCAL statement_timeout='5s'")
        .execute(&mut *tx)
        .await?;
    // Find the room locks before taking the root lock. A route may switch
    // during discovery; retry the backfill if the new room was not locked.
    let rooms_to_lock: Vec<String> = sqlx::query_scalar(
        "SELECT DISTINCT room FROM remote_recovery_roots r
         CROSS JOIN LATERAL jsonb_array_elements_text(
             jsonb_path_query_array(r.state, '$.routes.*.room')
             || jsonb_path_query_array(r.state, '$.proxies.*.room')) AS t(room)
         WHERE genesis_hash=$1",
    )
    .bind(genesis)
    .fetch_all(&mut *tx)
    .await?;
    let locked: BTreeSet<_> = rooms_to_lock.iter().map(String::as_str).collect();
    lock_rooms(&mut tx, &locked.iter().copied().collect::<Vec<_>>()).await?;
    let state = load_root(&mut tx, genesis)
        .await?
        .ok_or_else(invalid_root)?;
    let (root, log) = validated_root(genesis, state)?;
    let mut rooms = BTreeSet::new();
    let mut stale_routes = 0;
    for (_, _, route, proved) in routes(&root, &log) {
        if proved {
            if !locked.contains(route.room.as_str()) {
                return Err(sqlx::Error::Protocol(
                    "route changed during room migration; retry".into(),
                ));
            }
            index_proof(&mut tx, origin, issuer, route).await?;
            rooms.insert(route.room.as_str());
        } else {
            stale_routes += 1;
        }
    }
    let rooms: Vec<_> = rooms.into_iter().collect();
    observe(&mut tx, origin, issuer, genesis, &rooms).await?;
    let (known, disputed): (i64, i64) = sqlx::query_as(
        "SELECT count(*) FILTER (WHERE NOT conflicted), count(*) FILTER (WHERE conflicted)
         FROM station_proved_room_owners WHERE station_origin=$1 AND issuer=$2
         AND genesis_hash=$3 AND room=ANY($4)",
    )
    .bind(origin)
    .bind(issuer)
    .bind(genesis)
    .bind(&rooms)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(
        json!({"proved_rooms":rooms.len(),"with_registration_evidence":known,
        "disputed":disputed,"without_registration_evidence":rooms.len() as i64-known-disputed,
        "stale_routes":stale_routes}),
    )
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
    let competing = policy.has_competing_binding(connection, &root.account, &genesis, binding)
        .await.map_err(|_| invalid_root())?;
    let binding_state = match binding {
        _ if competing => "superseded_or_conflicting",
        Some(row) => row.binding_state.as_str(),
        None if policy.portal_snapshot.is_some() => "no_binding_in_checkpoint",
        None => "unobserved",
    };

    let rows: Vec<_> = routes(root, log).collect();
    let rooms: BTreeSet<_> = rows
        .iter()
        .filter_map(|(_, _, route, proved)| proved.then_some(route.room.as_str()))
        .collect();

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
    .bind(session_ids)
    .bind(BINDING_TTL_SECS)
    .fetch_all(&mut *connection)
    .await?
    .into_iter()
    .map(|(id, current, subject)| (id, (current, subject)))
    .collect();
    let rooms: Vec<_> = rooms.into_iter().collect();
    let retained: BTreeMap<_, _> = sqlx::query_as::<_, (String, String, bool)>(
        "SELECT room, account_subject, conflicted FROM station_proved_room_owners
         WHERE station_origin=$1 AND issuer=$2 AND genesis_hash=$3 AND room=ANY($4)",
    )
    .bind(&portal.station_origin)
    .bind(&portal.issuer)
    .bind(&genesis)
    .bind(&rooms)
    .fetch_all(&mut *connection)
    .await?
    .into_iter()
    .map(|(room, owner, conflict)| (room, (owner, conflict)))
    .collect();
    let registrations: BTreeMap<String, Option<String>> = sqlx::query_as(
        "SELECT a.astation_id,i.subject FROM astation_accounts a LEFT JOIN account_identities i
         ON i.principal=a.agora_user AND i.issuer=$1 WHERE a.astation_id=ANY($2)",
    )
    .bind(&portal.issuer)
    .bind(&rooms)
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
        let durable = retained.get(&route.room);
        if let Some(candidate) = candidate {
            if registrations
                .get(&route.room)
                .is_some_and(|s| s.as_deref() != Some(candidate))
                || durable.is_some_and(|(owner, disputed)| *disputed || owner != candidate)
            {
                source = "unresolved";
            }
        }
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
                if session.is_some() && current_owner != Some(candidate)
                    || status != "current" && durable.is_none()
                {
                    source = "unresolved";
                } else if status != "current" && source != "unresolved" {
                    source = "retained_session";
                }
            }
        }
        row["owner_source"] = json!(source);
        hosts.push(row);
    }
    Ok(
        json!({"root_owner_mapped":owner.is_some(),"last_observed_binding":binding_state,
        "binding_matches_root_owner":binding.filter(|_| !competing).and_then(|b|owner.map(|o|o == b.account)),
        "binding_version":binding.map(|row|row.version),"retained_routes":hosts}),
    )
}

/// Check the signed-in service owner inside the transaction that admits the
/// proof or dispatches the frame. The caller holds the proved root lock.
pub(in crate::remote_api::recovery) async fn route_service(
    db: &mut PgConnection,
    station: &FeedBinding,
    principal: &str,
    account: &str,
    genesis: &str,
    room: &str,
) -> Result<RouteService, sqlx::Error> {
    let policy = PolicyStore::lock_for_binding(db, station)
        .await
        .map_err(|_| invalid_root())?;
    if !policy.recent_d27_read(chrono::Utc::now().timestamp_millis()) {
        return Ok(RouteService::Unavailable);
    }
    let binding = policy.effective_binding(db, account, genesis).await?;
    if policy
        .has_competing_binding(db, account, genesis, binding.as_ref())
        .await
        .map_err(|_| invalid_root())?
    {
        return Ok(RouteService::Unavailable);
    }
    let owner = match binding {
        Some(row) if row.binding_state == "bound" => Some(row.account),
        Some(_) => None,
        None => legacy_owner(db, station, genesis, room, principal).await?,
    };
    let Some(disabled) = policy.route_account_disabled(owner.as_deref()) else {
        return Ok(RouteService::Unavailable);
    };
    // Disabled observations reserve cursor + 1 for that account. A higher
    // floor, or a higher global cut, means another replica has newer evidence.
    let behind: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM station_delegated_availability_fences
         WHERE issuer=$1 AND portal_origin=$2 AND station_origin=$3
           AND ((account='' AND minimum_cursor>$5)
             OR (account=$4 AND minimum_cursor>$5+$6)))"
    )
    .bind(&station.issuer).bind(&station.portal_origin).bind(&station.station_origin)
    .bind(owner.as_deref()).bind(policy.cursor as i64).bind(i64::from(disabled))
    .fetch_one(db).await?;
    if behind || !policy.recent_d27_read(chrono::Utc::now().timestamp_millis()) {
        return Ok(RouteService::Unavailable);
    }
    Ok(match owner {
        None => RouteService::NoOwner,
        Some(_) if disabled => RouteService::Disabled,
        Some(_) => RouteService::Allowed,
    })
}

async fn legacy_owner(
    db: &mut PgConnection,
    station: &FeedBinding,
    genesis: &str,
    room: &str,
    principal: &str,
) -> Result<Option<String>, sqlx::Error> {
    let mut rows = room_owners(db, station, genesis, &[room], principal).await?;
    let Some(row) = rows.pop() else {
        return Err(invalid_root());
    };
    match row.owner() {
        LegacyOwner::Conflict => Err(invalid_root()),
        LegacyOwner::Account(owner) => Ok(Some(owner.to_owned())),
        LegacyOwner::Unmapped | LegacyOwner::Unknown => Ok(None),
    }
}

enum LegacyOwner<'a> {
    Account(&'a str),
    Unknown,
    Unmapped,
    Conflict,
}

#[derive(sqlx::FromRow)]
struct Lookup {
    room: String,
    retained: Option<String>,
    conflicted: bool,
    direct: Option<String>,
    registered: bool,
    session_owner: Option<String>,
    has_session: bool,
    root_owner: Option<String>,
}

impl Lookup {
    fn owner(&self) -> LegacyOwner<'_> {
        if self.conflicted {
            return LegacyOwner::Conflict;
        }
        if self.registered && self.direct.is_none()
            || self.has_session && self.session_owner.is_none()
        {
            return LegacyOwner::Unmapped;
        }
        if session_id_for_room(&self.room).is_some() && !self.has_session && self.retained.is_none()
        {
            // An expired session does not establish the room's owner.
            return if self.registered {
                LegacyOwner::Unmapped
            } else {
                LegacyOwner::Unknown
            };
        }
        let mut owners = [
            self.retained.as_deref(),
            self.direct.as_deref(),
            self.session_owner.as_deref(),
        ]
        .into_iter()
        .flatten();
        if let Some(owner) = owners.next() {
            return if account_id(owner) && owners.all(|s| s == owner) {
                LegacyOwner::Account(owner)
            } else {
                LegacyOwner::Conflict
            };
        }
        self.root_owner
            .as_deref()
            .filter(|owner| account_id(owner))
            .map_or(LegacyOwner::Unknown, LegacyOwner::Account)
    }
}

async fn room_owners(
    db: &mut PgConnection,
    station: &FeedBinding,
    genesis: &str,
    rooms: &[&str],
    principal: &str,
) -> Result<Vec<Lookup>, sqlx::Error> {
    let sessions: Vec<_> = rooms.iter().map(|room| session_id_for_room(room)).collect();
    sqlx::query_as(
        "SELECT q.room, r.account_subject AS retained, COALESCE(r.conflicted,false) AS conflicted,
            direct_id.subject AS direct, direct.astation_id IS NOT NULL AS registered,
            session_id.subject AS session_owner, s.session_id IS NOT NULL AS has_session,
            root_owner.subject AS root_owner
         FROM unnest($4::text[],$5::text[]) AS q(room,session)
         LEFT JOIN station_proved_room_owners r ON (r.issuer,r.station_origin,r.genesis_hash,r.room)=($1,$2,$3,q.room)
         LEFT JOIN astation_accounts direct ON direct.astation_id=q.room
         LEFT JOIN account_identities direct_id ON direct_id.issuer=$1 AND direct_id.principal=direct.agora_user
         LEFT JOIN session_bindings s ON s.session_id=q.session
            AND s.last_used_at>floor(extract(epoch FROM statement_timestamp()))::bigint-$7
         LEFT JOIN astation_accounts a ON a.astation_id=s.astation_id
         LEFT JOIN account_identities session_id ON session_id.issuer=$1 AND session_id.principal=a.agora_user
         LEFT JOIN account_identities root_owner ON root_owner.issuer=$1 AND root_owner.principal=$6")
        .bind(&station.issuer).bind(&station.station_origin).bind(genesis).bind(rooms).bind(sessions)
        .bind(principal).bind(BINDING_TTL_SECS).fetch_all(db).await
}

#[derive(serde::Serialize)]
pub(crate) struct BindingRooms {
    pub rooms: BTreeMap<String, Option<String>>,
    pub proved_root_owner: Option<String>,
}

/// The caller holds the root lock. A registration can already hold a room
/// lock while waiting for that root, so return a retry instead of waiting.
pub(crate) async fn binding_rooms(
    db: &mut PgConnection,
    station: &FeedBinding,
    genesis: &str,
) -> Result<Option<BindingRooms>, sqlx::Error> {
    let (principal, proved_root_owner, rooms): (String, Option<String>, Vec<String>) = sqlx::query_as(
        "SELECT account_subject, CASE WHEN COALESCE(state->'routes','{}'::jsonb)<>'{}'::jsonb
            OR COALESCE(state->'proxies','{}'::jsonb)<>'{}'::jsonb OR EXISTS
                (SELECT 1 FROM station_room_proofs WHERE (issuer,station_origin,genesis_hash)=($1,$2,$3))
            THEN (SELECT subject FROM account_identities WHERE issuer=$1 AND principal=account_subject)
            END, ARRAY(
            SELECT room FROM station_proved_room_owners WHERE (issuer,station_origin,genesis_hash)=($1,$2,$3)
            UNION SELECT room FROM station_room_proofs WHERE (issuer,station_origin,genesis_hash)=($1,$2,$3)
            UNION SELECT jsonb_array_elements_text(jsonb_path_query_array(state, '$.routes.*.room')
                                               || jsonb_path_query_array(state, '$.proxies.*.room')))
         FROM remote_recovery_roots WHERE genesis_hash=$3")
        .bind(&station.issuer).bind(&station.station_origin).bind(genesis).fetch_one(&mut *db).await?;
    let locked: bool = sqlx::query_scalar(
        "SELECT COALESCE(bool_and(pg_try_advisory_xact_lock_shared(hashtextextended(room,739185))),true)
         FROM unnest($1::text[]) AS q(room)")
        .bind(&rooms).fetch_one(&mut *db).await?;
    if !locked {
        return Ok(None);
    }
    let rooms: Vec<_> = rooms.iter().map(String::as_str).collect();
    let mut result = BTreeMap::new();
    for row in room_owners(db, station, genesis, &rooms, &principal).await? {
        let account = match row.owner() {
            LegacyOwner::Account(owner) => Some(owner.to_owned()),
            LegacyOwner::Unknown => None,
            LegacyOwner::Conflict | LegacyOwner::Unmapped => return Ok(None),
        };
        result.insert(row.room, account);
    }
    // A proved host's own durable root association and its room registration
    // may name different accounts. Preserve both ownership checks on first bind.
    Ok(Some(BindingRooms { rooms: result, proved_root_owner }))
}

impl super::super::RecoveryStore {
    pub(crate) async fn retired_binding_connections(
        &self,
        candidates: &[crate::cluster::ConnRef],
    ) -> Result<Vec<crate::cluster::ConnRef>, sqlx::Error> {
        let Some(station) = self.verifier_portal.get().filter(|station|
            self.active_delegated_binding().is_some_and(|fence| fence.origin == station.station_origin)
                && crate::account_identity::built_in_station(&station.station_origin)
        ) else { return Ok(Vec::new()) };
        let pool = self.pool.as_ref().ok_or_else(invalid_root)?;
        let retired: Vec<sqlx::types::Json<crate::cluster::ConnRef>> = sqlx::query_scalar(
            "SELECT c FROM jsonb_array_elements($4) c WHERE EXISTS (
                SELECT 1 FROM station_native_binding_transitions t
                WHERE (t.issuer,t.portal_origin,t.station_origin)=($1,$2,$3)
                  AND t.retired_routes @> jsonb_build_array(c)
                UNION ALL
                SELECT 1 FROM station_applied_binding_releases r
                WHERE (r.issuer,r.portal_origin,r.station_origin)=($1,$2,$3)
                  AND r.retired_routes @> jsonb_build_array(c))",
        )
        .bind(&station.issuer).bind(&station.portal_origin).bind(&station.station_origin)
        .bind(sqlx::types::Json(candidates)).fetch_all(pool).await?;
        Ok(retired.into_iter().map(|row| row.0).collect())
    }
}
