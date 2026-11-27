use super::*;
use crate::cluster::ConnRef;
use crate::remote_api::push_ingress::tests::Fixture;
use crate::remote_api::recovery::{HostBinding, HostRouteError, ProxyBinding, RecoveryStore};
use crate::station_integrations::tests::{fixture_at_station, ID, OWNER, PRINCIPAL};
use atem_client::control::ToStation;
use atem_client::host_route::{
    host_route_message, sign_host_route_as, HostChallenge, HostRouteBody, RouteKind,
};
use axum::body::{to_bytes, Body};
use axum::http::Request;
use tower::ServiceExt;

async fn admit(
    store: &RecoveryStore,
    f: &Fixture,
    kind: RouteKind,
) -> Result<HostBinding, HostRouteError> {
    let challenge = HostChallenge::new("phone");
    let proof = host_route_message(
        &sign_host_route_as(
            kind,
            &f.keys,
            &f.host_key,
            &HostRouteBody::at(&f.log, "host-a", "host-a", &challenge),
        )
        .unwrap(),
    )
    .to_string();
    let connection = ConnRef::new(&uuid::Uuid::new_v4().to_string(), "replica");
    match kind {
        RouteKind::Relay => {
            store
                .admit_host(&proof, challenge.nonce, "phone", "host-a", connection)
                .await
        }
        RouteKind::Proxy => {
            store
                .admit_proxy(
                    &proof,
                    challenge.nonce,
                    "phone",
                    "host-a",
                    connection,
                    ProxyBinding {
                        session: "session".into(),
                        generation: "epoch".into(),
                        native: ConnRef::new("native", "replica"),
                    },
                    PRINCIPAL,
                )
                .await
        }
    }
    .map(|(binding, _)| binding)
}

async fn ack(
    store: &RecoveryStore,
    f: &Fixture,
    binding: &HostBinding,
    origin: &str,
) -> StatusCode {
    let feed = serde_json::to_value(binding).unwrap()["delegated_feed"]["feed_id"].clone();
    let message = json!({"type":"relay","op":"control_ack","account_id":f.log.account_id(),
        "genesis_hash":binding.genesis,"host_id":"host-a","host_trust_gen":1,"origin":origin,
        "feed_id":feed,"cursor":0,"results":[]});
    let ToStation::ControlAck(parsed) = ToStation::decode(message.to_string().as_bytes()).unwrap()
    else {
        unreachable!()
    };
    store.acknowledge_delegated(binding, parsed).await.0
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_binding_commit_rechecks_both_logins_and_retains_one_transition() {
    let auth = crate::account_identity::tests::Fixture::new().await;
    let origin = "https://station-dev.agora.build";
    let (db, runtime, fixture) = fixture_at_station(&auth.issuer, None, origin).await;
    let before = runtime.policies.load(&runtime.binding).await.unwrap();
    let portal = json!({"changes":[],"cursor":before.cursor,"checkpoint":{
        "at":"2026-11-24T10:00:00.000Z","integrations":[{
            "id":ID,"ownerAccount":OWNER,"state":"awaiting_approval","scopes":["agent.view","agent.prompt","agent.approve"],
            "r9Svc":null,"expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10}],
        "accounts":{"complete":true,"disabled":[]},"bindings":[],"pendingReleases":[]}});
    let snapshot =
        PortalCheckpoint::parse(portal.to_string().as_bytes(), &runtime.binding).unwrap();
    let mut checkpoint = before
        .apply_checkpoint(snapshot, before.received_at)
        .unwrap();
    let now = chrono::Utc::now().timestamp_millis();
    checkpoint.record_completed_read(now, now);
    runtime.policies.commit(&before, &checkpoint).await.unwrap();
    let genesis = fixture.log.genesis_hash().to_hex();
    let account = fixture.log.account_id();
    let app = Router::new()
        .route("/logs/:genesis/binding/challenge", post(super::super::mint))
        .route(
            "/logs/:genesis/binding/consent",
            post(super::super::consent),
        )
        .route("/logs/:genesis/binding/commit", post(super::super::commit))
        .with_state(IntegrationState(Some(runtime.clone())));
    let send = async |path: &str, body: &Value, claims: &Value| {
        let access = auth.token(auth.header(), claims.clone());
        let req = Request::post(format!("/logs/{genesis}/binding/{path}"))
            .header("Authorization", format!("Bearer {access}"))
            .body(Body::from(body.to_string()))
            .unwrap();
        let response = app.clone().oneshot(req).await.unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 16_384).await.unwrap();
        (status, serde_json::from_slice::<Value>(&bytes).unwrap())
    };
    let sign = |body: &Value| {
        let challenge = StationBindingChallenge::parse(body.to_string().as_bytes()).unwrap();
        let request = station_binding_request(
            &fixture.log,
            &challenge,
            challenge.signer(),
            origin,
            challenge.claims(),
            challenge.issued_at(),
        )
        .unwrap();
        atem_client::station_binding::sign_station_binding(
            &fixture.keys,
            &atem_client::KeyId::new("manager"),
            &request,
        )
        .unwrap()
        .to_json()
    };
    let mut owner = auth.claims();
    owner["aud"] = json!(origin);
    owner["scope"] = json!("astation.remote");
    owner["auth_time"] = owner["iat"].clone();
    let mut new_owner = owner.clone();
    new_owner["sub"] = json!("ab00000000000000000000000008");
    let mut intent = json!({"action":"bind","account_id":account,"signer":"member:phone","head":fixture.log.head().to_json(),
        "expected_binding":{"state":"never_bound"}});
    assert_eq!(
        send("commit", &json!({}), &owner).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    if !cfg!(feature = "delegated-host-work") {
        db.cleanup().await;
        return;
    }
    runtime
        .app
        .recovery
        .configure_delegated(origin, 1)
        .await
        .unwrap();
    let (status, issued) = send("challenge", &intent, &owner).await;
    assert_eq!(status, StatusCode::OK);
    let proof = sign(&issued);
    let refusal = (
        StatusCode::CONFLICT,
        json!({"error":{"code":"binding_unavailable"}}),
    );
    assert_eq!(send("commit", &proof, &new_owner).await, refusal);
    let mut other_login = owner.clone();
    other_login["auth_time"] = json!(owner["auth_time"].as_i64().unwrap() - 1);
    assert_eq!(send("commit", &proof, &other_login).await, refusal);
    let mut broken = proof.clone();
    broken["sig"] = json!(atem_client::encoding::b64u(&[0; 64]));
    assert_eq!(send("commit", &broken, &owner).await, refusal);
    let replica = db.reconnect(2).await;
    let peer = RecoveryStore::postgres(replica.clone());
    peer.set_verifier_portal(&runtime.binding).unwrap();
    peer.configure_delegated(origin, 1).await.unwrap();
    let old_relay = admit(&peer, &fixture, RouteKind::Relay).await.unwrap();
    let old_proxy = admit(&peer, &fixture, RouteKind::Proxy).await.unwrap();
    sqlx::raw_sql("CREATE FUNCTION reject_bind_commit() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'commit fault'; END $$;
        CREATE CONSTRAINT TRIGGER reject_bind_commit AFTER INSERT ON station_native_binding_transitions
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_bind_commit()").execute(&replica).await.unwrap();
    assert_eq!(
        send("commit", &proof, &owner).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    let counts = async || {
        sqlx::query_as::<_,(i64,i64)>("SELECT
        (SELECT count(*) FROM station_native_binding_transitions), (SELECT count(*) FROM station_binding_challenges)")
        .fetch_one(&replica).await.unwrap()
    };
    assert_eq!(counts().await, (0, 1));
    for route in [&old_relay, &old_proxy] {
        assert!(peer.prepare_delegated(route).await);
        assert_eq!(ack(&peer, &fixture, route, origin).await, StatusCode::OK);
    }
    sqlx::query("DROP TRIGGER reject_bind_commit ON station_native_binding_transitions")
        .execute(&replica)
        .await
        .unwrap();
    let (a, b) = tokio::join!(
        send("commit", &proof, &owner),
        send("commit", &proof, &owner)
    );
    assert_eq!(a.0, StatusCode::OK, "{}", a.1);
    assert_eq!(a, b);
    assert_eq!(a.1["version"], 1);
    assert_eq!(a.1["account"], OWNER);
    assert_eq!(counts().await, (1, 0));
    let retired: Vec<ConnRef> = sqlx::query_scalar::<_, sqlx::types::Json<Vec<ConnRef>>>(
        "SELECT retired_routes FROM station_native_binding_transitions WHERE version=1",
    )
    .fetch_one(&replica)
    .await
    .unwrap()
    .0;
    assert_eq!(retired.len(), 2);
    assert!(retired.contains(&old_relay.connection));
    assert!(retired.contains(&old_proxy.connection));
    for route in [&old_relay, &old_proxy] {
        assert!(peer
            .with_host_route(route, || std::future::ready(()))
            .await
            .is_none());
        assert_eq!(
            ack(&peer, &fixture, route, origin).await,
            StatusCode::FORBIDDEN
        );
    }
    let owner_route = admit(&peer, &fixture, RouteKind::Relay).await.unwrap();
    assert_eq!(send("commit", &broken, &owner).await, refusal);
    assert_eq!(send("challenge", &intent, &owner).await, refusal);

    // The Portal still mirrors never-bound. The next version comes from the shared local record.
    intent["action"] = json!("transfer");
    intent["expected_binding"] =
        json!({"state":"bound","binding_id":a.1["bindingId"],"version":1,"owner":OWNER});
    let (status, transfer) = send("challenge", &intent, &new_owner).await;
    assert_eq!(status, StatusCode::OK, "{transfer}");
    let signed_transfer = sign(&transfer);
    assert_eq!(send("commit", &signed_transfer, &new_owner).await, refusal);
    assert_eq!(send("consent", &transfer, &owner).await.0, StatusCode::OK);
    let moved = send("commit", &signed_transfer, &new_owner).await;
    assert_eq!(moved.0, StatusCode::OK, "{}", moved.1);
    assert_eq!(moved.1["version"], 2);
    assert_eq!(moved.1["account"], new_owner["sub"]);
    assert_eq!(counts().await, (2, 0));
    assert!(!peer.prepare_delegated(&owner_route).await);
    let moved_relay = admit(&peer, &fixture, RouteKind::Relay).await.unwrap();
    let moved_proxy = admit(&peer, &fixture, RouteKind::Proxy).await.unwrap();
    let pending_disable = async |account: &str| {
        sqlx::query(
            "INSERT INTO station_delegated_availability_fences
            (issuer,portal_origin,station_origin,account,minimum_cursor) VALUES ($1,$2,$3,$4,1)",
        )
        .bind(&auth.issuer)
        .bind(&runtime.binding.portal_origin)
        .bind(origin)
        .bind(account)
        .execute(&replica)
        .await
        .unwrap();
    };
    pending_disable(OWNER).await;
    for route in [&moved_relay, &moved_proxy] {
        assert!(peer.prepare_delegated(route).await);
        assert_eq!(ack(&peer, &fixture, route, origin).await, StatusCode::OK);
    }
    // A disable of the new owner on a different credential fences the actual
    // write and the ledger, even with an already admitted route.
    pending_disable(new_owner["sub"].as_str().unwrap()).await;
    let retained_state = async || {
        sqlx::query_scalar::<_, Value>(
            "SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1",
        )
        .bind(&genesis)
        .fetch_one(&replica)
        .await
        .unwrap()
    };
    let before_disable = retained_state().await;
    for route in [&moved_relay, &moved_proxy] {
        assert!(peer
            .with_host_route(route, || std::future::ready(()))
            .await
            .is_none());
        assert_eq!(
            ack(&peer, &fixture, route, origin).await,
            StatusCode::SERVICE_UNAVAILABLE
        );
    }
    assert_eq!(retained_state().await, before_disable);
    sqlx::query("DELETE FROM station_delegated_availability_fences WHERE account=$1")
        .bind(new_owner["sub"].as_str().unwrap())
        .execute(&replica)
        .await
        .unwrap();
    let report: Value =
        sqlx::query_scalar("SELECT report FROM station_native_binding_transitions WHERE version=2")
            .fetch_one(&replica)
            .await
            .unwrap();
    assert_eq!(report["bindingState"], "bound");
    assert_eq!(report["state"], "binding_changed");
    assert!(report["reportId"]
        .as_str()
        .unwrap()
        .starts_with("binding_changed:"));

    intent["action"] = json!("unbind");
    intent["expected_binding"] =
        json!({"state":"bound","binding_id":a.1["bindingId"],"version":2,"owner":new_owner["sub"]});
    let (status, unbind) = send("challenge", &intent, &new_owner).await;
    assert_eq!(status, StatusCode::OK);
    let stopped = send("commit", &sign(&unbind), &new_owner).await;
    assert_eq!(stopped.0, StatusCode::OK, "{}", stopped.1);
    assert_eq!(stopped.1["version"], 3);
    assert_eq!(stopped.1["bindingState"], "unbound");
    assert_eq!(counts().await, (3, 0));
    for route in [&moved_relay, &moved_proxy] {
        assert!(!peer.prepare_delegated(route).await);
        assert_eq!(
            ack(&peer, &fixture, route, origin).await,
            StatusCode::FORBIDDEN
        );
    }
    for kind in [RouteKind::Relay, RouteKind::Proxy] {
        assert!(admit(&peer, &fixture, kind).await.is_err());
    }
    assert_eq!(send("commit", &proof, &owner).await, a);
    replica.close().await;
    db.cleanup().await;
}
