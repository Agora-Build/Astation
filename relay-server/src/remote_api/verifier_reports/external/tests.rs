use super::*;
use crate::account_identity::tests::Fixture as Issuer;
use crate::integration_checkpoint::PortalCheckpoint;
use crate::station_integrations::tests::{fixture_at_station, ID, OWNER, PRINCIPAL};
use atem_client::{
    membership::{
        service_add, service_key_fingerprint_of, sign_entry, Action, Role, RolesChange, ServiceScope,
    },
    KeyId, KeyProvider,
};

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_external_inbox_scopes_the_token_and_never_revives_a_paused_nonce() {
    exercise_inbox("https://custom.example").await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_builtin_external_inbox_requires_current_account_and_feed() {
    exercise_inbox("https://station-dev.agora.build").await;
}

async fn exercise_inbox(origin: &str) {
    let issuer = Issuer::new().await;
    let (db, runtime, mut f) = fixture_at_station(&issuer.issuer, None, origin).await;
    let binding = &runtime.binding;
    let store = &runtime.app.recovery;
    let genesis = f.log.genesis_hash().to_hex();
    store
        .configure_delegated(&binding.station_origin, 1)
        .await
        .unwrap();
    let key = KeyId::new("external-service");
    f.keys.insert_ed25519(key.clone(), &[42; 32]);
    let member = format!("svc-{ID}");
    let action = service_add(
        &member,
        f.keys.public_key(&key).unwrap(),
        &ServiceScope::new(["host-a"]),
        f.created + 86_400_000,
        f.created,
    )
    .unwrap();
    let entry = sign_entry(
        &f.keys,
        &KeyId::new("manager"),
        f.log.draft("phone", f.created, &action),
    )
    .unwrap();
    assert_eq!(
        store
            .append_test_entry(&genesis, PRINCIPAL, entry, f.log.head())
            .await,
        StatusCode::OK
    );
    let ancestor = runtime.recovery_log(&genesis, OWNER).await.unwrap();
    let roles = Action::SetRoles {
        device_id: "phone".into(),
        change: RolesChange::Native([Role::Control, Role::Manage, Role::View].into_iter().collect()),
    };
    let entry = sign_entry(&f.keys, &KeyId::new("manager"), ancestor.draft("phone", f.created, &roles)).unwrap();
    assert_eq!(
        store.append_test_entry(&genesis, PRINCIPAL, entry, ancestor.head()).await,
        StatusCode::OK
    );
    let log = runtime.recovery_log(&genesis, OWNER).await.unwrap();
    let fingerprint = service_key_fingerprint_of(&log, &member).unwrap();
    let mut policy =
        serde_json::to_value(&runtime.policies.load(binding).await.unwrap().integrations[ID])
            .unwrap();
    policy["state"] = json!("ready");
    policy["r9Svc"] = json!(fingerprint);
    let poll = async |events: Vec<(u64, &str, &str)>| {
        let prev = runtime.policies.load(binding).await.unwrap();
        let rows: Vec<_> = events
            .iter()
            .map(|(id, kind, state)| {
                json!({"id":id,"kind":kind,
            "integrationId":ID,"state":state,"integration":policy})
            })
            .collect();
        let cursor = events.last().unwrap().0;
        let mut page = json!({"cursor":cursor,"changes":rows});
        if prev.cursor == 0 {
            let mut first = policy.clone();
            first["id"] = json!(ID);
            page["integrations"] = json!([first]);
        }
        let now = chrono::Utc::now().timestamp_millis();
        let mut next = prev
            .apply(
                prev.cursor,
                serde_json::from_value(page).unwrap(),
                now / 1000,
            )
            .unwrap();
        next.record_completed_read(now, now);
        runtime.policies.commit(&prev, &next).await.unwrap();
    };
    poll(vec![(1, "integration_ready", "ready")]).await;
    let apply_cut = async |refreshed: bool, disabled: bool| {
        let prev = runtime.policies.load(binding).await.unwrap();
        let mut row = policy.clone();
        row["id"] = json!(ID);
        let mut cut = json!({"cursor":prev.cursor,"changes":[],"checkpoint":{
            "at":"2026-11-23T00:00:00.000Z","integrations":[row]}});
        if PortalCheckpoint::built_in(binding) {
            cut["checkpoint"]["bindings"] = json!([{"account":OWNER,"accountId":log.account_id(),
                "genesisHash":genesis,"bindingId":"binding-1","version":1,"bindingState":"bound"}]);
            cut["checkpoint"]["pendingReleases"] = json!([]);
            cut["checkpoint"]["accounts"] = json!({"complete":true,
                "disabled":if disabled {vec![OWNER]} else {vec![]}});
        }
        let now = chrono::Utc::now().timestamp_millis();
        let snapshot = PortalCheckpoint::parse(cut.to_string().as_bytes(), binding).unwrap();
        let mut next = prev.apply_checkpoint(snapshot, now / 1000).unwrap();
        next.record_completed_read(if refreshed { now } else { now - 60_000 }, now);
        runtime.policies.commit(&prev, &next).await.unwrap();
    };
    if PortalCheckpoint::built_in(binding) {
        apply_cut(true, false).await;
    }
    let mut state = runtime.app.clone();
    let verifier =
        crate::account_identity::OidcVerifier::new(&issuer.issuer, origin, "astation.remote")
            .unwrap();
    state.accounts = std::sync::Arc::new(crate::account_store::PgAccountStore::with_verifier(
        db.pool.clone(),
        std::sync::Arc::new(verifier),
    ));
    let router = crate::station_integrations::routes_with_runtime(Some(runtime.clone()))
        .nest("/api/remote/v1", crate::remote_api::routes())
        .with_state(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let local = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap();
    let call = async |method, path: &str, bearer: &str, body: Option<Value>| {
        let mut request = client
            .request(method, format!("{local}{path}"))
            .bearer_auth(bearer);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let reply = request.send().await.unwrap();
        assert_eq!(reply.headers()["cache-control"], "no-store");
        (reply.status(), reply.json::<Value>().await.unwrap())
    };
    let mut native_claims = issuer.claims();
    native_claims["aud"] = json!(origin);
    native_claims["scope"] = json!("astation.remote");
    let native = issuer.token(issuer.header(), native_claims);
    let native_path = format!("/api/remote/v1/logs/{genesis}/verifier-reports");
    let make = async |number| {
        let now = chrono::Utc::now().timestamp_millis() as u64;
        let challenge = ReportChallenge::new(
            &format!("service:{member}"),
            "sdk",
            &binding.station_origin,
            number,
            now,
            now + 30_000,
        )
        .unwrap();
        let body = json!({"challenge":challenge.to_json(),"expected":log.head().to_json()});
        assert_eq!(
            call(reqwest::Method::POST, &native_path, &native, Some(body))
                .await
                .0,
            StatusCode::OK
        );
        challenge
    };
    let first = make(1).await;
    let mut claims = issuer.claims();
    claims["aud"] = json!(binding.station_origin);
    claims["sub"] = json!(OWNER);
    claims["client_id"] = json!(ID);
    claims["scope"] = json!("agent.view");
    claims["r9_svc"] = json!(fingerprint);
    claims["exp"] = json!(claims["iat"].as_i64().unwrap() + 300);
    let raw = issuer.token(issuer.header(), claims.clone());
    let token = runtime.verifier.verify_verifier_token(&raw).await.unwrap();
    let inbox_path = format!("/agora-build/v1/logs/{genesis}/verifier-requests");
    let http = async |bearer: &str| {
        call(
            reqwest::Method::POST,
            &inbox_path,
            bearer,
            Some(json!({"slot":"sdk","expected":log.head().to_json()})),
        )
        .await
    };
    let mut wrong_audience = claims.clone();
    wrong_audience["aud"] = json!("https://station.example");
    assert_eq!(
        http(&issuer.token(issuer.header(), wrong_audience)).await.0,
        StatusCode::UNAUTHORIZED
    );
    let mut shared_audience = claims.clone();
    shared_audience["aud"] = json!([origin, "https://station.example"]);
    assert_eq!(
        http(&issuer.token(issuer.header(), shared_audience))
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    let mut missing_scope = claims.clone();
    missing_scope["scope"] = json!("agent.prompt");
    assert_eq!(
        http(&issuer.token(issuer.header(), missing_scope)).await.0,
        StatusCode::FORBIDDEN
    );
    sqlx::raw_sql(
        "CREATE FUNCTION reject_fetch() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'test fetch commit'; END $$;
        CREATE CONSTRAINT TRIGGER reject_fetch AFTER UPDATE ON remote_recovery_roots
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_fetch()",
    )
    .execute(&db.pool)
    .await
    .unwrap();
    assert_eq!(http(&raw).await.0, StatusCode::SERVICE_UNAVAILABLE);
    let nonce = URL_SAFE_NO_PAD.encode(first.nonce());
    let fetched = async || {
        sqlx::query_scalar::<_,Option<i64>>(
        "SELECT (state->'verifier_reports'->$2->>'first_external_fetch_ms')::bigint FROM remote_recovery_roots WHERE genesis_hash=$1"
    ).bind(&genesis).bind(&nonce).fetch_one(&db.pool).await.unwrap()
    };
    assert_eq!(fetched().await, None);
    sqlx::query("DROP TRIGGER reject_fetch ON remote_recovery_roots")
        .execute(&db.pool)
        .await
        .unwrap();
    assert_eq!(
        http(&raw).await,
        (StatusCode::OK, json!({"challenges":[first.to_json()]}))
    );
    let received = fetched().await.expect("committed fetch");
    assert_eq!(http(&raw).await.0, StatusCode::OK);
    assert_eq!(fetched().await, Some(received));
    let peer = RecoveryStore::postgres(db.reconnect(2).await);
    peer.configure_delegated(&binding.station_origin, 1)
        .await
        .unwrap();
    let read = async |token: &VerifiedServiceToken, slot: &str| {
        peer.external_verifier(
            binding,
            &genesis,
            token,
            ExternalVerifierRequest::Inbox {
                slot: slot.into(),
                expected: log.head(),
            },
        )
        .await
        .unwrap()
    };
    assert_eq!(
        read(&token, "sdk").await.1 .0["challenges"],
        json!([first.to_json()])
    );
    assert_eq!(read(&token, "other").await.1 .0["challenges"], json!([]));
    let mut wrong = claims.clone();
    wrong["r9_svc"] = json!("0".repeat(64));
    let other = runtime
        .verifier
        .verify_verifier_token(&issuer.token(issuer.header(), wrong))
        .await
        .unwrap();
    assert_eq!(read(&other, "sdk").await.0, StatusCode::NOT_FOUND);
    let answered = make(4).await;
    let answer_nonce = URL_SAFE_NO_PAD.encode(answered.nonce());
    let signed = |process: u8, reporter_log: &Membership| {
        let now = chrono::Utc::now().timestamp_millis() as u64;
        let signer = format!("service:{member}");
        let mut body = atem_client::member_report::verifier_report_body(
            reporter_log, &answered, &signer, "sdk", origin, now,
        )
        .unwrap()
        .to_json();
        body["process"] = json!(URL_SAFE_NO_PAD.encode([process; 16]));
        atem_client::SignedObject::sign(&f.keys, &key, body)
            .unwrap()
            .to_json()
    };
    let answer_path = format!("/agora-build/v1/logs/{genesis}/verifier-reports/{answer_nonce}");
    let submit = async |report: &Value| {
        call(
            reqwest::Method::POST,
            &answer_path,
            &raw,
            Some(json!({"report":report})),
        )
        .await
    };
    let read_path = format!("{native_path}/{answer_nonce}");
    let native_read = async || call(reqwest::Method::GET, &read_path, &native, None).await;
    assert_eq!(
        call(reqwest::Method::GET, &read_path, &raw, None).await.0,
        StatusCode::UNAUTHORIZED
    );
    let one = signed(1, &ancestor);
    let caught_up = signed(1, &log);
    let two = signed(2, &ancestor);
    assert_eq!(submit(&one).await.0, StatusCode::NOT_FOUND);
    assert_eq!(
        http(&raw).await.1["challenges"].as_array().unwrap().len(),
        2
    );
    sqlx::raw_sql(
        "CREATE CONSTRAINT TRIGGER reject_answer AFTER UPDATE ON remote_recovery_roots
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_fetch()",
    )
    .execute(&db.pool)
    .await
    .unwrap();
    assert_eq!(submit(&one).await.0, StatusCode::SERVICE_UNAVAILABLE);
    sqlx::query("DROP TRIGGER reject_answer ON remote_recovery_roots")
        .execute(&db.pool)
        .await
        .unwrap();
    assert_eq!(native_read().await.1["reports"], json!([]));
    let accepted = (StatusCode::OK, json!({"accepted":true}));
    assert_eq!(submit(&one).await, accepted);
    assert_eq!(submit(&one).await, accepted);
    assert_ne!(one, caught_up);
    assert_eq!(submit(&caught_up).await, accepted);
    assert_eq!(native_read().await.1["reports"], json!([one]));
    assert_eq!(http(&raw).await.1["challenges"], json!([first.to_json()]));
    let conflict = (StatusCode::CONFLICT, json!({"error":{"code":"verifier_process_conflict"}}));
    assert_eq!(submit(&two).await, conflict);
    assert_eq!(submit(&one).await, conflict);
    assert_eq!(submit(&caught_up).await, conflict);
    assert_eq!(submit(&two).await, conflict);
    let mut foreign = claims.clone();
    foreign["client_id"] = json!("i-11234567890123456789012345");
    assert_eq!(
        call(reqwest::Method::POST, &answer_path, &issuer.token(issuer.header(), foreign),
            Some(json!({"report":one}))).await.0,
        StatusCode::NOT_FOUND
    );
    let reports = native_read().await.1["reports"].as_array().unwrap().clone();
    assert_eq!(reports.len(), 2);
    assert!(reports.contains(&one) && reports.contains(&two));
    // Another replica can observe a pause using a rotated report credential first.
    let mut rotated = binding.clone();
    rotated.report_client_id = "s-11234567890123456789012345".into();
    let observed = runtime.policies.load(&rotated).await.unwrap();
    let mut paused = policy.clone();
    paused["id"] = json!(ID);
    paused["state"] = json!("paused");
    let page = json!({"cursor":2,"integrations":[paused],"changes":[{"id":2,"kind":"integration_paused",
        "integrationId":ID,"state":"paused","integration":paused}]});
    let observed_pause = observed
        .apply(
            0,
            serde_json::from_value(page).unwrap(),
            chrono::Utc::now().timestamp(),
        )
        .unwrap();
    runtime
        .policies
        .commit(&observed, &observed_pause)
        .await
        .unwrap();
    assert_eq!(http(&raw).await.0, StatusCode::NOT_FOUND);
    assert_eq!(submit(&one).await.0, StatusCode::NOT_FOUND);
    assert_eq!(native_read().await.0, StatusCode::CONFLICT);
    poll(vec![
        (2, "integration_paused", "paused"),
        (3, "integration_resumed", "ready"),
    ])
    .await;
    assert_eq!(read(&token, "sdk").await.1 .0["challenges"], json!([]));
    let retry = Command::Create {
        challenge: first,
        expected: log.head(),
    };
    assert_eq!(
        store
            .perform(
                &genesis,
                PRINCIPAL,
                Operation::VerifierReport {
                    origin: binding.station_origin.clone(),
                    command: retry
                }
            )
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(read(&token, "sdk").await.1 .0["challenges"], json!([]));
    let next = make(2).await;
    assert_eq!(
        read(&token, "sdk").await.1 .0["challenges"],
        json!([next.to_json()])
    );
    apply_cut(false, false).await;
    assert_eq!(http(&raw).await.0, StatusCode::NOT_FOUND);
    apply_cut(true, false).await;
    assert_eq!(http(&raw).await.1["challenges"], json!([next.to_json()]));
    poll(vec![(4, "integration_key_added", "ready")]).await;
    assert_eq!(http(&raw).await.1["challenges"], json!([next.to_json()]));
    let previous = runtime.policies.load(binding).await.unwrap();
    let mut replacement = policy.clone();
    replacement["r9Svc"] = json!("b".repeat(64));
    let page = json!({"cursor":5,"changes":[{"id":5,"kind":"integration_reconciled",
        "integrationId":ID,"state":"ready","integration":replacement}]});
    let now = chrono::Utc::now().timestamp_millis();
    let mut changed = previous
        .apply(4, serde_json::from_value(page).unwrap(), now / 1000)
        .unwrap();
    changed.record_completed_read(now, now);
    runtime.policies.commit(&previous, &changed).await.unwrap();
    assert_eq!(http(&raw).await.0, StatusCode::NOT_FOUND);
    assert_eq!(submit(&two).await.0, StatusCode::NOT_FOUND);
    poll(vec![(6, "integration_reconciled", "ready")]).await;
    assert_eq!(http(&raw).await.1["challenges"], json!([]));
    if PortalCheckpoint::built_in(binding) {
        let fresh = make(3).await;
        assert_eq!(http(&raw).await.1["challenges"], json!([fresh.to_json()]));
        apply_cut(true, true).await;
        assert_eq!(http(&raw).await.0, StatusCode::NOT_FOUND);
    }
    drop(peer);
    server.abort();
    let _ = server.await;
    drop(runtime);
    db.cleanup().await;
}
