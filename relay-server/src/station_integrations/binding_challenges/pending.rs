//! Account-private discovery of the next ownership request that still needs this owner's consent.
use super::*;
use atem_client::station_binding::verify_station_binding;

pub(in crate::station_integrations) async fn next(
    State(IntegrationState(runtime)): State<IntegrationState>,
    headers: HeaderMap,
) -> Response {
    let Some(runtime) = runtime else {
        return unavailable();
    };
    let Some(fence) = runtime.app.recovery.active_delegated_binding() else {
        return unavailable();
    };
    if !PortalCheckpoint::built_in(&runtime.binding)
        || fence.origin != runtime.binding.station_origin
    {
        return unavailable();
    }
    let _permit = match runtime.requests.try_acquire() {
        Ok(permit) => permit,
        Err(_) => return error(StatusCode::TOO_MANY_REQUESTS, "binding_busy"),
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let token = match tokio::time::timeout_at(deadline, runtime.native(&headers)).await {
        Ok(Ok(token)) => token,
        Ok(Err(reply)) => return reply,
        Err(_) => return unavailable(),
    };
    let result = tokio::time::timeout_at(deadline, async {
        let mut tx = runtime.policies.0.begin().await?;
        sqlx::query("SET LOCAL statement_timeout='3s'")
            .execute(&mut *tx)
            .await?;
        fence.lock(&mut tx).await?;
        let request = find(&mut tx, &runtime.binding, &token).await?;
        tx.commit().await?;
        Ok::<_, sqlx::Error>(request)
    })
    .await;
    match result {
        Ok(Ok(request)) => Json(json!({"request":request})).into_response(),
        _ => unavailable(),
    }
}

async fn find(
    db: &mut PgConnection,
    station: &FeedBinding,
    token: &VerifiedAccessToken,
) -> Result<Option<Value>, sqlx::Error> {
    let owner = &token.identity.subject;
    let Some(auth_time) = token.identity.authenticated_at else {
        return Ok(None);
    };
    if token.identity.issuer != station.issuer {
        return Ok(None);
    }
    // Expiration and the Station-wide issuance quota bound this scan.
    // Filter again under the challenge and policy locks before returning its contents.
    let candidates: Vec<String> = sqlx::query_scalar("SELECT nonce FROM station_binding_challenges c
        WHERE issuer=$1 AND station_origin=$2 AND consent_proof IS NOT NULL AND consent_owners @> ARRAY[$3::text]
          AND expires_at > floor(extract(epoch FROM statement_timestamp())*1000)
          AND COALESCE(consent_expires_at,0) <= floor(extract(epoch FROM statement_timestamp())*1000)
          AND NOT EXISTS (SELECT 1 FROM station_binding_room_consents r
            WHERE (r.issuer,r.station_origin,r.nonce,r.owner_subject)=(c.issuer,c.station_origin,c.nonce,$3)
            AND r.expires_at > floor(extract(epoch FROM statement_timestamp())*1000))
        ORDER BY expires_at,nonce LIMIT 4096")
        .bind(&station.issuer).bind(&station.station_origin).bind(owner).fetch_all(&mut *db).await?;
    for nonce in candidates {
        let saved: Option<String> = sqlx::query_scalar(
            "SELECT challenge FROM station_binding_challenges
            WHERE issuer=$1 AND station_origin=$2 AND nonce=$3",
        )
        .bind(&station.issuer)
        .bind(&station.station_origin)
        .bind(&nonce)
        .fetch_optional(&mut *db)
        .await?;
        let Some(saved) = saved else { continue };

        let challenge = StationBindingChallenge::parse(saved.as_bytes())
            .map_err(|_| sqlx::Error::Protocol("invalid stored binding challenge".into()))?;
        if !eligible_owner(&challenge, owner)
            || challenge.origin() != station.station_origin
            || challenge.issuer() != station.issuer
        {
            continue;
        }
        let intent = Intent::from_challenge(&challenge);
        let Some(ReviewedIntent {
            mut log,
            policy,
            rooms,
        }) = review_intent(
            db,
            station,
            challenge.genesis_hash(),
            &intent,
            challenge.subject(),
        )
        .await?
        else {
            continue;
        };
        // All writers review the policy and rooms before locking the challenge.
        let Some((proof, digest)) = outstanding_proof(db, station, &nonce, owner).await? else {
            continue;
        };
        if rooms.is_some_and(|r| {
            digest.as_deref() != Some(r.digest.as_slice()) || !r.owners.contains(owner)
        }) {
            continue;
        }
        let now = binding_clock_ms(db).await?;
        if now < 0
            || auth_time < 0
            || auth_time > now / 1000
            || token.expires_at.saturating_mul(1000) <= now
        {
            return Ok(None);
        }
        let mut clock = crate::remote_api::recovery::now();
        clock.wall_ms = now as u64;
        log.advance(&clock);
        if policy.recent_d27_read(now)
            && challenge.issued_at() <= clock.wall_ms
            && verify_station_binding(&log, proof.as_bytes(), &challenge, clock.wall_ms)
                .is_ok_and(|p| p.at_head)
        {
            return Ok(Some(challenge.to_json()));
        }
    }
    Ok(None)
}

// Discovery and consent may run on different replicas. Read consent in a fresh
// statement after acquiring the lock used by both consent writers.
pub(super) async fn outstanding_proof(
    db: &mut PgConnection,
    station: &FeedBinding,
    nonce: &str,
    owner: &str,
) -> Result<Option<(String, Option<Vec<u8>>)>, sqlx::Error> {
    let locked = sqlx::query_scalar::<_, String>(
        "SELECT nonce FROM station_binding_challenges WHERE issuer=$1 AND station_origin=$2
         AND nonce=$3 AND consent_owners @> ARRAY[$4::text] FOR SHARE NOWAIT",
    )
    .bind(&station.issuer)
    .bind(&station.station_origin)
    .bind(nonce)
    .bind(owner)
    .fetch_optional(&mut *db)
    .await?;
    if locked.is_none() {
        return Ok(None);
    }
    sqlx::query_as(
        "SELECT consent_proof,room_digest FROM station_binding_challenges c
         WHERE issuer=$1 AND station_origin=$2 AND nonce=$3 AND consent_proof IS NOT NULL
           AND COALESCE(consent_expires_at,0) <= floor(extract(epoch FROM statement_timestamp())*1000)
           AND NOT EXISTS (SELECT 1 FROM station_binding_room_consents r
             WHERE (r.issuer,r.station_origin,r.nonce,r.owner_subject)=(c.issuer,c.station_origin,c.nonce,$4)
             AND r.expires_at > floor(extract(epoch FROM statement_timestamp())*1000))",
    )
    .bind(&station.issuer).bind(&station.station_origin).bind(nonce).bind(owner)
    .fetch_optional(db).await
}
