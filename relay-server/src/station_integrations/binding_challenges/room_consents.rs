//! Keep the room review private to Station and bind each owner's consent to the manager's nonce.
use super::*;
use crate::integration_feed::PolicyCheckpoint;
use crate::remote_api::recovery::delegated_recovery::binding_rooms;
use std::collections::BTreeSet;

pub(super) struct Review {
    pub digest: Vec<u8>,
    pub owners: BTreeSet<String>,
}

pub(super) async fn review(
    db: &mut PgConnection,
    station: &FeedBinding,
    policy: &PolicyCheckpoint,
    genesis: &str,
    subject: &str,
) -> Result<Option<Review>, sqlx::Error> {
    let Some(rooms) = binding_rooms(db, station, genesis).await? else {
        return Ok(None);
    };
    let owners: BTreeSet<_> = rooms
        .rooms
        .values()
        .flatten()
        .chain(rooms.proved_root_owner.iter())
        .filter(|owner| owner.as_str() != subject)
        .cloned()
        .collect();
    if owners
        .iter()
        .any(|owner| !policy.allows_delegated_release(owner))
    {
        return Ok(None);
    }
    let accounts: Vec<_> = owners.iter().map(String::as_str).collect();
    let behind: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM station_delegated_availability_fences WHERE issuer=$1 AND
         portal_origin=$2 AND station_origin=$3 AND account=ANY($4) AND minimum_cursor>$5)",
    )
    .bind(&station.issuer)
    .bind(&station.portal_origin)
    .bind(&station.station_origin)
    .bind(accounts)
    .bind(policy.cursor as i64)
    .fetch_one(db)
    .await?;
    if behind {
        return Ok(None);
    }
    // BTreeMap gives the same room-to-owner bytes on every replica.
    let bytes = serde_json::to_vec(&rooms).map_err(|e| sqlx::Error::Protocol(e.to_string()))?;
    let digest = ring::digest::digest(&ring::digest::SHA256, &bytes)
        .as_ref()
        .to_vec();
    Ok(Some(Review { digest, owners }))
}

pub(super) async fn record(
    db: &mut PgConnection,
    station: &FeedBinding,
    nonce: &str,
    subject: &str,
    auth_time: i64,
    expires: i64,
    now: i64,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO station_binding_room_consents AS c
        (issuer,station_origin,nonce,owner_subject,auth_time,expires_at) VALUES ($1,$2,$3,$4,$5,$6)
        ON CONFLICT (issuer,station_origin,nonce,owner_subject) DO UPDATE
        SET auth_time=EXCLUDED.auth_time,expires_at=EXCLUDED.expires_at WHERE c.expires_at <= $7",
    )
    .bind(&station.issuer)
    .bind(&station.station_origin)
    .bind(nonce)
    .bind(subject)
    .bind(auth_time)
    .bind(expires)
    .bind(now)
    .execute(db)
    .await?;
    Ok(())
}

pub(super) async fn deadline(
    db: &mut PgConnection,
    station: &FeedBinding,
    nonce: &str,
    owners: &BTreeSet<String>,
) -> Result<i64, sqlx::Error> {
    if owners.is_empty() {
        return Ok(i64::MAX);
    }
    let accounts: Vec<_> = owners.iter().map(String::as_str).collect();
    sqlx::query_scalar("SELECT CASE WHEN count(*)=cardinality($4::text[]) THEN min(expires_at) ELSE 0 END
        FROM station_binding_room_consents WHERE issuer=$1 AND station_origin=$2 AND nonce=$3 AND owner_subject=ANY($4)")
        .bind(&station.issuer).bind(&station.station_origin).bind(nonce).bind(accounts).fetch_one(db).await
}
