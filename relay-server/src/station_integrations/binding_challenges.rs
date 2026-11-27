//! Issue the native manager's challenge before its fresh confirmation.
use super::*;
use crate::integration_checkpoint::PortalCheckpoint;
use atem_client::{
    canonical::StrictValue,
    membership::Head,
    station_binding::{
        station_binding_request, AuthClaims, BindingAction, ExpectedBinding,
        StationBindingChallenge,
    },
    Hash32,
};
use sqlx::PgConnection;

struct Intent {
    action: BindingAction,
    account: String,
    head: Head,
    signer: String,
    expected: ExpectedBinding,
}

impl Intent {
    fn parse(bytes: &[u8]) -> Option<Self> {
        let strict = StrictValue::parse(bytes, 4096).ok()?;
        let value = strict.value();
        if value.as_object()?.len() != 5 {
            return None;
        }
        Some(Self {
            action: BindingAction::from_name(value.get("action")?.as_str()?)?,
            account: value.get("account_id")?.as_str()?.to_owned(),
            head: Head::from_json(value.get("head")?)?,
            signer: value.get("signer")?.as_str()?.to_owned(),
            expected: ExpectedBinding::from_json(value.get("expected_binding")?).ok()?,
        })
    }
}

pub(super) async fn mint(
    state: State<IntegrationState>,
    path: Path<String>,
    headers: HeaderMap,
    body: axum::body::Body,
) -> Response {
    handle(state, path, headers, body, Operation::Mint).await
}

pub(super) async fn consent(
    state: State<IntegrationState>,
    path: Path<String>,
    headers: HeaderMap,
    body: axum::body::Body,
) -> Response {
    handle(state, path, headers, body, Operation::Consent).await
}

enum Operation {
    Mint,
    Consent,
}

async fn handle(
    State(IntegrationState(runtime)): State<IntegrationState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
    body: axum::body::Body,
    operation: Operation,
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
    let token = match runtime.native(&headers).await {
        Ok(token) => token,
        Err(reply) => return reply,
    };
    let invalid = || error(StatusCode::BAD_REQUEST, "invalid_binding_request");
    let Ok(genesis) = Hash32::from_hex(&genesis) else {
        return invalid();
    };
    let Ok(bytes) = axum::body::to_bytes(body, 4096).await else {
        return invalid();
    };
    let Ok(mut tx) = runtime.policies.0.begin().await else {
        return unavailable();
    };
    if sqlx::query("SET LOCAL statement_timeout='3s'")
        .execute(&mut *tx)
        .await
        .is_err()
        || fence.lock(&mut tx).await.is_err()
    {
        return unavailable();
    }
    let result = match operation {
        Operation::Mint => {
            let Some(intent) = Intent::parse(&bytes) else {
                return invalid();
            };
            issue(&mut tx, &runtime.binding, &token, genesis, intent).await
        }
        Operation::Consent => {
            let Ok(challenge) = StationBindingChallenge::parse(&bytes) else {
                return invalid();
            };
            record_consent(&mut tx, &runtime.binding, &token, genesis, &challenge).await
        }
    };
    match result {
        Ok(Some(body)) => match tx.commit().await {
            Ok(()) => Json(body).into_response(),
            Err(_) => unavailable(),
        },
        Ok(None) => error(StatusCode::CONFLICT, "binding_unavailable"),
        Err(_) => unavailable(),
    }
}

async fn issue(
    db: &mut PgConnection,
    station: &FeedBinding,
    token: &VerifiedAccessToken,
    genesis: Hash32,
    intent: Intent,
) -> Result<Option<Value>, sqlx::Error> {
    let invalid = || sqlx::Error::Protocol("binding challenge storage unavailable".into());
    let Some(auth_time) = token
        .identity
        .authenticated_at
        .and_then(|v| u64::try_from(v).ok())
    else {
        return Ok(None);
    };
    let claims = AuthClaims {
        issuer: token.identity.issuer.clone(),
        subject: token.identity.subject.clone(),
        auth_time,
    };
    if claims.issuer != station.issuer || !PortalCheckpoint::built_in(station) {
        return Ok(None);
    }
    let Some((log, policy)) = review_intent(db, station, genesis, &intent, &claims.subject).await?
    else {
        return Ok(None);
    };
    // The allocation lock has exactly the same scope as both nonce quotas.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,36))")
        .bind(json!([station.issuer, station.station_origin]).to_string())
        .execute(&mut *db)
        .await?;
    let now: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint")
            .fetch_one(&mut *db)
            .await?;
    let until = token
        .expires_at
        .saturating_mul(1000)
        .min(now.saturating_add(30_000));
    if now < 0 || now >= until || !policy.recent_d27_read(now) {
        return Ok(None);
    }
    let Ok(challenge) = StationBindingChallenge::new(
        intent.action,
        &station.station_origin,
        &claims,
        &intent.account,
        genesis,
        intent.head,
        &intent.signer,
        intent.expected,
        now as u64,
        until as u64,
    ) else {
        return Ok(None);
    };
    if station_binding_request(
        &log,
        &challenge,
        &intent.signer,
        &station.station_origin,
        &claims,
        now as u64,
    )
    .is_err()
    {
        return Ok(None);
    }
    sqlx::query("DELETE FROM station_binding_challenges WHERE issuer=$1 AND station_origin=$2 AND expires_at<=$3")
        .bind(&station.issuer).bind(&station.station_origin).bind(now).execute(&mut *db).await?;
    let active: Vec<String> = sqlx::query_scalar(
        "SELECT challenge FROM station_binding_challenges WHERE issuer=$1 AND station_origin=$2 AND subject=$3 LIMIT 9")
        .bind(&station.issuer).bind(&station.station_origin).bind(&claims.subject).fetch_all(&mut *db).await?;
    for bytes in &active {
        let old = StationBindingChallenge::parse(bytes.as_bytes()).map_err(|_| invalid())?;
        if old.origin() == challenge.origin()
            && old.claims() == &claims
            && old.action() == challenge.action()
            && old.account_id() == challenge.account_id()
            && old.genesis_hash() == genesis
            && old.head() == challenge.head()
            && old.signer() == challenge.signer()
            && old.expected_binding() == challenge.expected_binding()
            && old.issued_at() <= now as u64
            && old.expires_at() <= until as u64
            && old.expires_at() > now as u64
        {
            return Ok(Some(old.to_json()));
        }
    }
    let total: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM station_binding_challenges WHERE issuer=$1 AND station_origin=$2",
    )
    .bind(&station.issuer)
    .bind(&station.station_origin)
    .fetch_one(&mut *db)
    .await?;
    if total >= 4096 || active.len() >= 8 {
        return Ok(None);
    }
    sqlx::query("INSERT INTO station_binding_challenges(issuer,station_origin,subject,nonce,challenge,expires_at)
        VALUES ($1,$2,$3,$4,$5,$6)")
        .bind(&station.issuer).bind(&station.station_origin).bind(&claims.subject)
        .bind(atem_client::encoding::b64u(challenge.nonce())).bind(challenge.jcs()).bind(until)
        .execute(db).await?;
    Ok(Some(challenge.to_json()))
}

// A consent and the later ownership change must review the same source of
// authority as the new owner's challenge, including other replicas' denials.
async fn review_intent(
    db: &mut PgConnection,
    station: &FeedBinding,
    genesis: Hash32,
    intent: &Intent,
    subject: &str,
) -> Result<Option<(Membership, crate::integration_feed::PolicyCheckpoint)>, sqlx::Error> {
    let invalid = || sqlx::Error::Protocol("binding authority unavailable".into());
    let row: Option<String> = sqlx::query_scalar(
        "SELECT checkpoint FROM station_integration_policy WHERE binding=$1 FOR SHARE",
    )
    .bind(station.storage_key().map_err(|_| invalid())?)
    .fetch_optional(&mut *db)
    .await?;
    let policy = PolicyStore::decode_checkpoint(station, row).map_err(|_| invalid())?;
    let Some(snapshot) = policy.portal_snapshot.as_ref() else {
        return Ok(None);
    };
    let Some(bindings) = &snapshot.bindings else {
        return Ok(None);
    };
    let genesis_hex = genesis.to_hex();
    let current = bindings
        .iter()
        .find(|b| b.genesis_hash == genesis_hex && b.account_id == intent.account);
    let expected = match current {
        Some(row) => {
            json!({"state":row.binding_state,"version":row.version,"binding_id":row.binding_id,"owner":row.account})
        }
        None => json!({"state":"never_bound"}),
    };
    if expected != intent.expected.to_json() || !policy.allows_delegated_release(subject) {
        return Ok(None);
    }
    // Order policy observations across credentials through the challenge commit.
    sqlx::query("SELECT pg_advisory_xact_lock_shared(hashtextextended($1,29))")
        .bind(station.report_control_binding())
        .execute(&mut *db)
        .await?;
    if policy
        .has_competing_binding(db, &intent.account, &genesis_hex, current)
        .await
        .map_err(|_| invalid())?
    {
        return Ok(None);
    }
    let mut required_accounts = vec!["", subject];
    if let Some(row) = current.filter(|row| row.binding_state != "released") {
        if !policy.allows_delegated_release(&row.account) {
            return Ok(None);
        }
        required_accounts.push(&row.account);
    }
    let denied: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM station_delegated_availability_fences WHERE
        issuer=$1 AND portal_origin=$2 AND station_origin=$3 AND account=ANY($4) AND minimum_cursor>$5)")
        .bind(&station.issuer).bind(&station.portal_origin).bind(&station.station_origin)
        .bind(&required_accounts).bind(policy.cursor as i64).fetch_one(&mut *db).await?;
    if denied {
        return Ok(None);
    }
    let membership: Option<Value> = sqlx::query_scalar(
        "SELECT state->'membership' FROM remote_recovery_roots WHERE genesis_hash=$1 AND state->>'account'=$2
        AND octet_length((state->'membership')::text)<=16777216 FOR SHARE NOWAIT")
        .bind(&genesis_hex).bind(&intent.account).fetch_optional(&mut *db).await?;
    let Some(membership) = membership else {
        return Ok(None);
    };
    let mut log =
        Membership::from_stored(&intent.account, &genesis, &membership).map_err(|_| invalid())?;
    log.advance(&crate::remote_api::recovery::now());
    if log.head() != intent.head {
        return Ok(None);
    }
    Ok(Some((log, policy)))
}

async fn record_consent(
    db: &mut PgConnection,
    station: &FeedBinding,
    token: &VerifiedAccessToken,
    genesis: Hash32,
    challenge: &StationBindingChallenge,
) -> Result<Option<Value>, sqlx::Error> {
    let ExpectedBinding::Bound(previous) = challenge.expected_binding() else {
        return Ok(None);
    };
    let Some(auth_time) = token.identity.authenticated_at else {
        return Ok(None);
    };
    if challenge.action() != BindingAction::Transfer
        || genesis != challenge.genesis_hash()
        || challenge.origin() != station.station_origin
        || challenge.issuer() != station.issuer
        || token.identity.issuer != station.issuer
        || previous.owner != token.identity.subject
    {
        return Ok(None);
    }
    let intent = Intent {
        action: challenge.action(),
        account: challenge.account_id().to_owned(),
        head: challenge.head(),
        signer: challenge.signer().to_owned(),
        expected: challenge.expected_binding().clone(),
    };
    let Some((log, policy)) =
        review_intent(db, station, genesis, &intent, challenge.subject()).await?
    else {
        return Ok(None);
    };
    let nonce = atem_client::encoding::b64u(challenge.nonce());
    let saved: Option<String> = sqlx::query_scalar(
        "SELECT challenge FROM station_binding_challenges WHERE issuer=$1 AND station_origin=$2
            AND nonce=$3 AND subject=$4 FOR UPDATE",
    )
    .bind(&station.issuer)
    .bind(&station.station_origin)
    .bind(&nonce)
    .bind(challenge.subject())
    .fetch_optional(&mut *db)
    .await?;
    if saved.as_deref() != Some(challenge.jcs()) {
        return Ok(None);
    }
    // Read time after all blocking locks. Consent ends at the earlier login or nonce deadline.
    let now: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint")
            .fetch_one(&mut *db)
            .await?;
    let expires = token
        .expires_at
        .saturating_mul(1000)
        .min(challenge.expires_at() as i64);
    if !policy.recent_d27_read(now)
        || now < 0
        || now >= expires
        || auth_time < 0
        || auth_time > now / 1000
        || station_binding_request(
            &log,
            challenge,
            challenge.signer(),
            &station.station_origin,
            challenge.claims(),
            now as u64,
        )
        .is_err()
    {
        return Ok(None);
    }
    sqlx::query(
        "UPDATE station_binding_challenges SET consent_auth_time=$4,consent_expires_at=$5
        WHERE issuer=$1 AND station_origin=$2 AND nonce=$3
            AND (consent_expires_at IS NULL OR consent_expires_at <= $6)",
    )
    .bind(&station.issuer)
    .bind(&station.station_origin)
    .bind(&nonce)
    .bind(auth_time)
    .bind(expires)
    .bind(now)
    .execute(db)
    .await?;
    Ok(Some(json!({"consented":true})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::station_integrations::tests::{fixture_at_station, ID, OWNER};
    use axum::{
        body::{to_bytes, Body},
        http::Request,
    };
    use tower::ServiceExt;

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_native_binding_challenge_is_private_durable_and_matches_the_review()
    {
        let auth = crate::account_identity::tests::Fixture::new().await;
        let origin = "https://station-dev.agora.build";
        let (db, runtime, fixture) = fixture_at_station(&auth.issuer, None, origin).await;
        let station = &runtime.binding;
        let previous = runtime.policies.load(station).await.unwrap();
        let portal = json!({"changes":[],"cursor":previous.cursor,"checkpoint":{
            "at":"2026-11-24T10:00:00.000Z","integrations":[{
                "id":ID,"ownerAccount":OWNER,"state":"awaiting_approval","scopes":["agent.view","agent.prompt","agent.approve"],
                "r9Svc":null,"expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10}],
            "accounts":{"complete":true,"disabled":[]},"bindings":[],"pendingReleases":[]}});
        let snapshot = PortalCheckpoint::parse(portal.to_string().as_bytes(), station).unwrap();
        let mut current = previous
            .apply_checkpoint(snapshot, previous.received_at)
            .unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        current.record_completed_read(now, now);
        runtime.policies.commit(&previous, &current).await.unwrap();
        let app = Router::new()
            .route(
                "/agora-build/v1/logs/:genesis/binding/challenge",
                post(mint),
            )
            .route(
                "/agora-build/v1/logs/:genesis/binding/transfer-consent",
                post(consent),
            )
            .with_state(IntegrationState(Some(runtime.clone())));
        let path = format!(
            "/agora-build/v1/logs/{}/binding/challenge",
            fixture.log.genesis_hash().to_hex()
        );
        let intent = json!({"action":"bind","account_id":fixture.log.account_id(),"signer":"member:phone",
            "head":fixture.log.head().to_json(),"expected_binding":{"state":"never_bound"}});
        let mut claims = auth.claims();
        claims["aud"] = json!(origin);
        claims["scope"] = json!("astation.remote");
        claims["auth_time"] = claims["iat"].clone();
        let consent_path = path.replace("/challenge", "/transfer-consent");
        let send = async |endpoint: &str, body: &str, claims: &Value| {
            let token = auth.token(auth.header(), claims.clone());
            let reply = app
                .clone()
                .oneshot(
                    Request::post(endpoint)
                        .header("Authorization", format!("Bearer {token}"))
                        .body(Body::from(body.to_owned()))
                        .unwrap(),
                )
                .await
                .unwrap();
            let status = reply.status();
            let bytes = to_bytes(reply.into_body(), 8192).await.unwrap();
            (status, serde_json::from_slice::<Value>(&bytes).unwrap())
        };
        let post = async |body: &str, claims: &Value| send(&path, body, claims).await;
        let approve = async |body: &str, claims: &Value| send(&consent_path, body, claims).await;
        let text = intent.to_string();
        assert_eq!(
            approve("{}", &claims).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert_eq!(
            post(&text, &claims).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        if !cfg!(feature = "delegated-host-work") {
            let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_binding_challenges")
                .fetch_one(&db.pool)
                .await
                .unwrap();
            assert_eq!(count, 0);
            db.cleanup().await;
            return;
        }
        runtime
            .app
            .recovery
            .configure_delegated(origin, 1)
            .await
            .unwrap();
        let (first, retry) = tokio::join!(post(&text, &claims), post(&text, &claims));
        assert_eq!(first.0, StatusCode::OK, "{}", first.1);
        assert_eq!(first, retry);
        let replica = db.reconnect(2).await;
        let (saved, expires): (String, i64) =
            sqlx::query_as("SELECT challenge,expires_at FROM station_binding_challenges")
                .fetch_one(&replica)
                .await
                .unwrap();
        let issued = StationBindingChallenge::parse(saved.as_bytes()).unwrap();
        assert_eq!(first.1, issued.to_json());
        assert_eq!(issued.expires_at(), expires as u64);
        assert_eq!(issued.expires_at() - issued.issued_at(), 30_000);
        assert_eq!(issued.subject(), OWNER);
        let expected = AuthClaims {
            issuer: auth.issuer.clone(),
            subject: OWNER.into(),
            auth_time: claims["auth_time"].as_u64().unwrap(),
        };
        let request = station_binding_request(
            &fixture.log,
            &issued,
            "member:phone",
            origin,
            &expected,
            issued.issued_at(),
        )
        .unwrap();
        let signed = atem_client::station_binding::sign_station_binding(
            &fixture.keys,
            &atem_client::KeyId::new("manager"),
            &request,
        )
        .unwrap();
        let verified = atem_client::station_binding::verify_station_binding(
            &fixture.log,
            signed.to_json().to_string().as_bytes(),
            &issued,
            issued.issued_at(),
        )
        .unwrap();
        assert!(verified.at_head);
        let mut stale = intent.clone();
        stale["head"]["seq"] = json!(42);
        let refusal = post(&stale.to_string(), &claims).await;
        assert_eq!(refusal.0, StatusCode::CONFLICT);
        for (key, value) in [
            ("signer", json!("member:missing")),
            ("account_id", json!("other")),
            ("action", json!("transfer")),
        ] {
            let mut wrong = intent.clone();
            wrong[key] = value;
            assert_eq!(post(&wrong.to_string(), &claims).await, refusal);
        }
        let mut unsigned = claims.clone();
        unsigned.as_object_mut().unwrap().remove("auth_time");
        assert_eq!(post(&text, &unsigned).await, refusal);
        let mut wrong = claims.clone();
        wrong["aud"] = json!("https://other.example");
        assert_eq!(post(&text, &wrong).await.0, StatusCode::UNAUTHORIZED);
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_binding_challenges")
            .fetch_one(&replica)
            .await
            .unwrap();
        assert_eq!(count, 1);
        // Change the recorded owner and version. Only an exact transfer to the
        // authenticated new owner can get that challenge; an unbind needs the old owner.
        let old_owner = "ab00000000000000000000000001";
        let mut bound = portal.clone();
        bound["checkpoint"]["bindings"] = json!([{"account":old_owner,"accountId":fixture.log.account_id(),
            "genesisHash":fixture.log.genesis_hash().to_hex(),"bindingId":"binding-one","version":1,"bindingState":"bound"}]);
        let snapshot = PortalCheckpoint::parse(bound.to_string().as_bytes(), station).unwrap();
        let updated = current
            .apply_checkpoint(snapshot, current.received_at)
            .unwrap();
        runtime.policies.commit(&current, &updated).await.unwrap();
        assert_eq!(post(&text, &claims).await, refusal);
        let mut transfer = intent.clone();
        transfer["action"] = json!("transfer");
        transfer["expected_binding"] =
            json!({"state":"bound","owner":old_owner,"version":1,"binding_id":"binding-one"});
        let (status, issued_transfer) = post(&transfer.to_string(), &claims).await;
        assert_eq!(status, StatusCode::OK);
        let wire = issued_transfer.to_string();
        transfer["action"] = json!("unbind");
        assert_eq!(post(&transfer.to_string(), &claims).await, refusal);
        let mut old = claims.clone();
        old["sub"] = json!(old_owner);
        let unbind = post(&transfer.to_string(), &old).await;
        assert_eq!(unbind.0, StatusCode::OK, "{}", unbind.1);
        assert_eq!(unbind.1["subject"], old_owner);

        assert_eq!(approve(&wire, &claims).await, refusal);
        assert_eq!(approve(&unbind.1.to_string(), &old).await, refusal);
        let mut altered = issued_transfer.clone();
        altered["subject"] = json!("ab00000000000000000000000002");
        assert_eq!(approve(&altered.to_string(), &old).await, refusal);
        let mut anonymous = old.clone();
        anonymous.as_object_mut().unwrap().remove("auth_time");
        assert_eq!(approve(&wire, &anonymous).await, refusal);

        // Neither viewer sees successful consent if the write fails at commit.
        sqlx::raw_sql(
            "CREATE FUNCTION reject_consent() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'consent commit fault'; END $$;
            CREATE CONSTRAINT TRIGGER reject_consent AFTER UPDATE ON station_binding_challenges
            DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_consent()",
        )
        .execute(&replica)
        .await
        .unwrap();
        assert_eq!(
            approve(&wire, &old).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        let consent_count = async || {
            sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM station_binding_challenges WHERE consent_auth_time IS NOT NULL")
            .fetch_one(&replica).await.unwrap()
        };
        assert_eq!(consent_count().await, 0);
        sqlx::query("DROP TRIGGER reject_consent ON station_binding_challenges")
            .execute(&replica)
            .await
            .unwrap();

        let mut short_login = old.clone();
        short_login["exp"] = json!(chrono::Utc::now().timestamp() + 15);
        let (a, b) = tokio::join!(approve(&wire, &short_login), approve(&wire, &short_login));
        assert_eq!(a, (StatusCode::OK, json!({"consented":true})));
        assert_eq!(a, b);
        assert_eq!(consent_count().await, 1);
        let saved_expiry: i64 = sqlx::query_scalar(
            "SELECT consent_expires_at FROM station_binding_challenges
            WHERE consent_auth_time IS NOT NULL",
        )
        .fetch_one(&replica)
        .await
        .unwrap();
        assert_eq!(saved_expiry, short_login["exp"].as_i64().unwrap() * 1000);
        // A retry with a longer login does not extend the original consent.
        assert_eq!(approve(&wire, &old).await, a);
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT consent_expires_at FROM station_binding_challenges
            WHERE consent_auth_time IS NOT NULL"
            )
            .fetch_one(&replica)
            .await
            .unwrap(),
            saved_expiry
        );

        // Uncommitted challenges must never be returned.
        sqlx::raw_sql("CREATE FUNCTION reject_binding_nonce() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'commit fault'; END $$;
            CREATE CONSTRAINT TRIGGER reject_binding_nonce AFTER INSERT ON station_binding_challenges
            DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_binding_nonce()")
            .execute(&replica).await.unwrap();
        old["auth_time"] = json!(claims["auth_time"].as_i64().unwrap() - 1);
        assert_eq!(
            post(&transfer.to_string(), &old).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_binding_challenges")
            .fetch_one(&replica)
            .await
            .unwrap();
        assert_eq!(count, 3);
        bound["checkpoint"]["bindings"][0]["version"] = json!(2);
        let changed = updated
            .apply_checkpoint(
                PortalCheckpoint::parse(bound.to_string().as_bytes(), station).unwrap(),
                updated.received_at,
            )
            .unwrap();
        runtime.policies.commit(&updated, &changed).await.unwrap();
        assert_eq!(approve(&wire, &old).await, refusal);
        replica.close().await;
        db.cleanup().await;
    }
}
