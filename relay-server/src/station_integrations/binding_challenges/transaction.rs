//! Consume a reviewed manager proof and retain the exact receipt across replicas.
use super::*;
use atem_client::{canonical::jcs, station_binding::verify_station_binding};

/// The exact proof identifies its durable receipt. A renewed login for the same
/// account may inspect a receipt, but only the original auth_time may change ownership.
pub(super) async fn submit(
    db: &mut PgConnection,
    station: &FeedBinding,
    token: &VerifiedAccessToken,
    genesis: Hash32,
    bytes: &[u8],
    inspect_only: bool,
) -> Result<Submission, sqlx::Error> {
    let Ok(proof) = StrictValue::parse(bytes, 16_384) else {
        return Ok(Submission::Refused);
    };
    let Ok(challenge) =
        StationBindingChallenge::parse(proof.value()["body"].to_string().as_bytes())
    else {
        return Ok(Submission::Refused);
    };
    if genesis != challenge.genesis_hash()
        || challenge.origin() != station.station_origin
        || token.identity.issuer != station.issuer
        || challenge.issuer() != station.issuer
        || challenge.subject() != token.identity.subject
        || (!inspect_only && token.identity.authenticated_at != Some(challenge.auth_time() as i64))
    {
        return Ok(Submission::Refused);
    }
    let Ok(canonical) = jcs(proof.value()) else {
        return Ok(Submission::Refused);
    };
    let proof_hash = ring::digest::digest(&ring::digest::SHA256, canonical.as_bytes());
    let nonce = atem_client::encoding::b64u(challenge.nonce());
    let genesis_hex = genesis.to_hex();
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,38))")
        .bind(json!([station.issuer, station.station_origin, genesis_hex]).to_string())
        .execute(&mut *db)
        .await?;
    let replay: Option<(Vec<u8>, Value)> = sqlx::query_as(
        "SELECT proof_hash,report - 'reportId' - 'state' FROM station_native_binding_transitions
         WHERE issuer=$1 AND portal_origin=$2 AND station_origin=$3 AND nonce=$4",
    )
    .bind(&station.issuer)
    .bind(&station.portal_origin)
    .bind(&station.station_origin)
    .bind(&nonce)
    .fetch_optional(&mut *db)
    .await?;
    let now = binding_clock_ms(db).await?;
    if now < 0 || token.expires_at.saturating_mul(1000) <= now {
        return Ok(Submission::Refused);
    }
    if let Some((hash, receipt)) = replay {
        return Ok(if hash.as_slice() == proof_hash.as_ref() {
            Submission::Confirmed(receipt)
        } else {
            Submission::Refused
        });
    }
    if inspect_only {
        return Ok(if now as u64 >= challenge.expires_at() {
            // A negative receipt stays final across a subsequent clock correction.
            sqlx::query(
                "DELETE FROM station_binding_challenges WHERE issuer=$1 AND station_origin=$2
                AND nonce=$3 AND subject=$4 AND challenge=$5 AND expires_at<=$6",
            )
            .bind(&station.issuer)
            .bind(&station.station_origin)
            .bind(&nonce)
            .bind(challenge.subject())
            .bind(challenge.jcs())
            .bind(now)
            .execute(&mut *db)
            .await?;
            Submission::Expired
        } else {
            Submission::Outstanding
        });
    }
    Ok(
        match apply(
            db,
            station,
            token,
            genesis,
            bytes,
            &challenge,
            &nonce,
            proof_hash.as_ref(),
        )
        .await?
        {
            Some(receipt) => Submission::Confirmed(receipt),
            None => Submission::Refused,
        },
    )
}

pub(super) enum Submission {
    Confirmed(Value),
    Outstanding,
    Expired,
    Refused,
}

async fn apply(
    db: &mut PgConnection,
    station: &FeedBinding,
    token: &VerifiedAccessToken,
    genesis: Hash32,
    bytes: &[u8],
    challenge: &StationBindingChallenge,
    nonce: &str,
    proof_hash: &[u8],
) -> Result<Option<Value>, sqlx::Error> {
    let genesis_hex = genesis.to_hex();
    let intent = Intent {
        action: challenge.action(),
        account: challenge.account_id().to_owned(),
        head: challenge.head(),
        signer: challenge.signer().to_owned(),
        expected: challenge.expected_binding().clone(),
    };
    // Route writers lock the root before the policy. Keep the same order and
    // retain only the exact connections that a replica must retire.
    let retired: Option<Value> = sqlx::query_scalar(
        "SELECT (SELECT COALESCE(jsonb_agg(connection ORDER BY connection), '[]'::jsonb)
           FROM (SELECT value->'connection' AS connection FROM jsonb_each(state->'routes')
                 UNION SELECT value->'connection' FROM jsonb_each(state->'proxies')) links)
         FROM remote_recovery_roots WHERE genesis_hash=$1 AND state->>'account'=$2 FOR UPDATE",
    )
    .bind(&genesis_hex)
    .bind(challenge.account_id())
    .fetch_optional(&mut *db)
    .await?;
    let Some(retired) = retired else {
        return Ok(None);
    };
    let Some((mut log, policy)) =
        review_intent(db, station, genesis, &intent, challenge.subject()).await?
    else {
        return Ok(None);
    };
    if matches!(challenge.expected_binding(), ExpectedBinding::NeverBound)
        && first_bind_requires_room_consent(db, station, &genesis_hex, challenge.subject()).await?
    {
        return Ok(None);
    }
    let stored: Option<(String, Option<i64>)> = sqlx::query_as(
        "SELECT challenge,consent_expires_at FROM station_binding_challenges
        WHERE issuer=$1 AND station_origin=$2 AND nonce=$3 AND subject=$4 FOR UPDATE",
    )
    .bind(&station.issuer)
    .bind(&station.station_origin)
    .bind(nonce)
    .bind(challenge.subject())
    .fetch_optional(&mut *db)
    .await?;
    let Some((stored, consent_until)) = stored else {
        return Ok(None);
    };
    let saved = StationBindingChallenge::parse(stored.as_bytes())
        .map_err(|_| sqlx::Error::Protocol("invalid stored binding challenge".into()))?;
    let now_ms = binding_clock_ms(db).await?;
    let mut now = crate::remote_api::recovery::now();
    now.wall_ms = now_ms.max(0) as u64;
    log.advance(&now);
    if now_ms < 0
        || token.expires_at.saturating_mul(1000) <= now_ms
        || !policy.recent_d27_read(now_ms)
        || saved.issued_at() > now.wall_ms
        || (challenge.action() == BindingAction::Transfer
            && !consent_until.is_some_and(|t| t > now_ms))
        || !verify_station_binding(&log, bytes, &saved, now.wall_ms)
            .is_ok_and(|proof| proof.at_head)
    {
        return Ok(None);
    }
    let previous = challenge.expected_binding().record();
    let version = previous.map_or(1, |r| r.version + 1);
    if version > 9_007_199_254_740_991 {
        return Ok(None);
    }
    let id = previous
        .map(|r| r.binding_id.clone())
        .unwrap_or_else(|| format!("bind-{}", uuid::Uuid::new_v4()));
    let state = if challenge.action() == BindingAction::Unbind {
        "unbound"
    } else {
        "bound"
    };
    let receipt = json!({"account":challenge.subject(),"accountId":challenge.account_id(),"genesisHash":genesis_hex,
        "bindingId":id,"version":version,"bindingState":state});

    sqlx::query("INSERT INTO station_native_binding_transitions
        (issuer,portal_origin,station_origin,account_id,genesis,version,nonce,proof_hash,report,retired_routes)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb || jsonb_build_object('state','binding_changed',
        'reportId','binding_changed:' || encode(sha256(convert_to(jsonb_build_array($4::text,$5::text,$6::bigint)::text,'UTF8')),'hex')),$10)")
        .bind(&station.issuer).bind(&station.portal_origin).bind(&station.station_origin).bind(challenge.account_id())
        .bind(&genesis_hex).bind(version as i64).bind(nonce).bind(proof_hash).bind(&receipt).bind(&retired)
        .execute(&mut *db).await?;
    sqlx::query(
        "UPDATE remote_recovery_roots SET state=state || '{\"routes\":{},\"proxies\":{}}'::jsonb,
        updated_at=now() WHERE genesis_hash=$1",
    )
    .bind(&genesis_hex)
    .execute(&mut *db)
    .await?;
    sqlx::query(
        "DELETE FROM station_binding_challenges WHERE issuer=$1 AND station_origin=$2 AND nonce=$3",
    )
    .bind(&station.issuer)
    .bind(&station.station_origin)
    .bind(nonce)
    .execute(db)
    .await?;
    Ok(Some(receipt))
}

// Foreign room ownership needs its own authenticated consent. Never infer it
// from the R9 manager proof or the identity of the new owner.
async fn first_bind_requires_room_consent(
    db: &mut PgConnection,
    station: &FeedBinding,
    genesis: &str,
    subject: &str,
) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar("SELECT EXISTS(
        SELECT 1 FROM station_proved_room_owners WHERE issuer=$1 AND station_origin=$2 AND genesis_hash=$3
            AND (conflicted OR account_subject<>$4)
        ) OR EXISTS (
        SELECT 1 FROM remote_recovery_roots r JOIN account_identities i ON i.principal=r.account_subject AND i.issuer=$1
        WHERE r.genesis_hash=$3 AND i.subject<>$4 AND (
            COALESCE(r.state->'routes','{}'::jsonb)<>'{}'::jsonb OR COALESCE(r.state->'proxies','{}'::jsonb)<>'{}'::jsonb
            OR EXISTS (SELECT 1 FROM station_room_proofs p WHERE p.genesis_hash=$3 AND p.issuer=$1 AND p.station_origin=$2)))")
        .bind(&station.issuer).bind(&station.station_origin).bind(genesis).bind(subject).fetch_one(db).await
}

#[cfg(test)]
mod tests;
