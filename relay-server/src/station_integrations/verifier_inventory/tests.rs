use super::super::tests::{append_body, fixture_with_issuer, request, ID, OWNER, PRINCIPAL};
use super::*;
use axum::{
    body::{to_bytes, Body, Bytes},
    http::Request,
};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_managed_service_inventory_times_out_stalled_bodies_and_releases_its_permit() {
    let issuer = crate::account_identity::tests::Fixture::new().await;
    let (db, runtime, f) = fixture_with_issuer(&issuer.issuer).await;
    let origin = runtime.binding.station_origin.clone();
    let genesis = f.log.genesis_hash().to_hex();
    runtime
        .app
        .recovery
        .configure_delegated(&origin, 1)
        .await
        .unwrap();
    runtime
        .app
        .recovery
        .configure_verifier_replicas(r#"{"generation":1,"replica":"a","replicas":["a"]}"#)
        .await
        .unwrap();
    let mut claims = issuer.claims();
    claims["aud"] = json!(origin);
    claims["scope"] = json!("astation.remote");
    let token = issuer.token(issuer.header(), claims);
    let router = Router::new()
        .route(
            "/agora-build/v1/logs/:genesis/verifiers/services",
            post(services),
        )
        .with_state(IntegrationState(Some(runtime.clone())));
    let valid = json!({"member_ids":["unmanaged"],"expected":f.log.head().to_json()}).to_string();
    let request = |body| {
        Request::builder()
            .method("POST")
            .uri(format!("/agora-build/v1/logs/{genesis}/verifiers/services"))
            .header("authorization", format!("Bearer {token}"))
            .body(body)
            .unwrap()
    };
    let permits = runtime.requests.available_permits();
    let reserved = runtime
        .requests
        .acquire_many((permits - 1) as u32)
        .await
        .unwrap();
    for partial in [false, true] {
        let reached = Arc::new(tokio::sync::Notify::new());
        let polled = reached.clone();
        let mut first = true;
        let stream = futures_util::stream::poll_fn(move |_| {
            if partial && first {
                first = false;
                return std::task::Poll::Ready(Some(Ok::<_, std::io::Error>(Bytes::from_static(
                    b"{",
                ))));
            }
            polled.notify_one();
            std::task::Poll::Pending
        });
        let pending = tokio::spawn(router.clone().oneshot(request(Body::from_stream(stream))));
        tokio::time::timeout(Duration::from_secs(5), reached.notified())
            .await
            .unwrap();
        assert_eq!(runtime.requests.available_permits(), 0);
        let busy = router
            .clone()
            .oneshot(request(Body::from(valid.clone())))
            .await
            .unwrap();
        assert_eq!(busy.status(), StatusCode::TOO_MANY_REQUESTS);
        // Pause only after real authentication/SQL has reached the stalled read.
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(10)).await;
        let response = pending.await.unwrap().unwrap();
        tokio::time::resume();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(runtime.requests.available_permits(), 1);
        let healthy = router
            .clone()
            .oneshot(request(Body::from(valid.clone())))
            .await
            .unwrap();
        assert_eq!(
            healthy.status(),
            StatusCode::OK,
            "the released slot must accept real requests"
        );
    }
    drop(reserved);
    assert_eq!(runtime.requests.available_permits(), permits);
    drop(router);
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_managed_service_inventory_hides_foreign_provisioning_like_unknown_ids() {
    let issuer = crate::account_identity::tests::Fixture::new().await;
    let (db, runtime, f) = fixture_with_issuer(&issuer.issuer).await;
    let origin = runtime.binding.station_origin.clone();
    let genesis = f.log.genesis_hash().to_hex();
    runtime
        .app
        .recovery
        .configure_delegated(&origin, 1)
        .await
        .unwrap();
    runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
    runtime
        .app
        .recovery
        .configure_verifier_replicas(r#"{"generation":1,"replica":"a","replicas":["a"]}"#)
        .await
        .unwrap();
    let context: String =
        sqlx::query_scalar("SELECT context FROM station_integration_provisioning")
            .fetch_one(&db.pool)
            .await
            .unwrap();
    let sealed: String = sqlx::query_scalar("SELECT sealed FROM station_service_keys")
        .fetch_one(&db.pool)
        .await
        .unwrap();
    let original: Value = serde_json::from_str(&context).unwrap();
    let mut foreign = original.clone();
    foreign["owner"] = json!("ab99999999999999999999999999");
    sqlx::query("INSERT INTO account_identities(issuer,subject,principal) VALUES($1,$2,'foreign-principal')")
        .bind(&issuer.issuer).bind(foreign["owner"].as_str().unwrap())
        .execute(&db.pool).await.unwrap();
    let mut another_genesis = original.clone();
    another_genesis["genesis"] = json!("f".repeat(64));
    let mut another_issuer = original.clone();
    another_issuer["issuer"] = json!("https://another-auth.example");
    let mut claims = issuer.claims();
    claims["aud"] = json!(origin);
    claims["scope"] = json!("astation.remote");
    let token = issuer.token(issuer.header(), claims);
    let router = Router::new()
        .route(
            "/agora-build/v1/logs/:genesis/verifiers/services",
            post(services),
        )
        .with_state(IntegrationState(Some(runtime.clone())));
    let id = format!("svc-{ID}");
    let unknown = "svc-i-99999999999999999999999999";
    for changed in [
        foreign.to_string(),
        another_genesis.to_string(),
        another_issuer.to_string(),
        "corrupt".into(),
    ] {
        sqlx::query("UPDATE station_integration_provisioning SET context=$1")
            .bind(changed)
            .execute(&db.pool)
            .await
            .unwrap();
        for requested in [&id, unknown] {
            let response = router
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri(format!("/agora-build/v1/logs/{genesis}/verifiers/services"))
                        .header("authorization", format!("Bearer {token}"))
                        .body(Body::from(
                            json!({"member_ids":[requested],"expected":f.log.head().to_json()})
                                .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let body: Value =
                serde_json::from_slice(&to_bytes(response.into_body(), 262_144).await.unwrap())
                    .unwrap();
            assert_eq!(
                body["services"],
                json!([{"id":requested}]),
                "foreign and absent records disclose no evidence"
            );
        }
        let unchanged: String = sqlx::query_scalar("SELECT sealed FROM station_service_keys")
            .fetch_one(&db.pool)
            .await
            .unwrap();
        assert_eq!(unchanged, sealed);
    }
    drop(router);
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_managed_service_inventory_opens_only_existing_account_bound_keys() {
    let issuer = crate::account_identity::tests::Fixture::new().await;
    let (db, runtime, f) = fixture_with_issuer(&issuer.issuer).await;
    let origin = runtime.binding.station_origin.clone();
    let genesis = f.log.genesis_hash().to_hex();
    runtime
        .app
        .recovery
        .configure_delegated(&origin, 1)
        .await
        .unwrap();
    let draft = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
    runtime
        .app
        .recovery
        .configure_verifier_replicas(r#"{"generation":1,"replica":"a","replicas":["a","b"]}"#)
        .await
        .unwrap();
    let registry = runtime.app.recovery.verifier_replicas().unwrap();
    let id = format!("svc-{ID}");
    let ids = vec![id.clone()];
    let pending = registry
        .managed_services_for(&genesis, PRINCIPAL, &runtime, &ids, &f.log.head())
        .await
        .unwrap()
        .unwrap();
    let body: Value = serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap();
    assert_eq!(
        pending["services"][0]["auth_key"], body["member"]["auth_key"],
        "pending inventory precedes enrollment without authorizing it"
    );
    append_body(&runtime, &f, body).await;
    let log = runtime.recovery_log(&genesis, OWNER).await.unwrap();
    let snapshot = registry
        .managed_services_for(&genesis, PRINCIPAL, &runtime, &ids, &log.head())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        snapshot["services"],
        json!([{"id":id,"auth_key":log.member(&id).unwrap().member.auth_key.to_json()}])
    );
    assert!(
        snapshot["replicas"][1].get("verifier").is_none(),
        "missing replicas stay visible"
    );
    assert!(registry
        .managed_services_for(&genesis, "another-account", &runtime, &ids, &log.head())
        .await
        .unwrap()
        .is_none());
    assert!(registry
        .managed_services_for(&genesis, PRINCIPAL, &runtime, &ids, &f.log.head())
        .await
        .is_err());
    let others = vec!["phone".to_owned(), "third-party".to_owned()];
    let snapshot = registry
        .managed_services_for(&genesis, PRINCIPAL, &runtime, &others, &log.head())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        snapshot["services"],
        json!([{"id":"phone"},{"id":"third-party"}])
    );

    let sealed: String = sqlx::query_scalar("SELECT sealed FROM station_service_keys")
        .fetch_one(&db.pool)
        .await
        .unwrap();
    for value in ["corrupt", ""] {
        sqlx::query("UPDATE station_service_keys SET sealed=$1")
            .bind(value)
            .execute(&db.pool)
            .await
            .unwrap();
        let snapshot = registry
            .managed_services_for(&genesis, PRINCIPAL, &runtime, &ids, &log.head())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(snapshot["services"], json!([{"id":id}]));
        let unchanged: String = sqlx::query_scalar("SELECT sealed FROM station_service_keys")
            .fetch_one(&db.pool)
            .await
            .unwrap();
        assert_eq!(unchanged, value);
    }
    sqlx::query("UPDATE station_service_keys SET sealed=$1")
        .bind(&sealed)
        .execute(&db.pool)
        .await
        .unwrap();
    sqlx::query("UPDATE station_integration_provisioning SET fingerprint='wrong'")
        .execute(&db.pool)
        .await
        .unwrap();
    assert!(registry
        .managed_services_for(&genesis, PRINCIPAL, &runtime, &ids, &log.head())
        .await
        .unwrap()
        .unwrap()["services"][0]
        .get("auth_key")
        .is_none());
    sqlx::query("UPDATE station_integration_provisioning SET fingerprint=$1")
        .bind(draft["fingerprint"].as_str().unwrap())
        .execute(&db.pool)
        .await
        .unwrap();

    let mut claims = issuer.claims();
    claims["aud"] = json!(origin);
    claims["scope"] = json!("astation.remote");
    let token = issuer.token(issuer.header(), claims.clone());
    let router = Router::new()
        .route(
            "/agora-build/v1/logs/:genesis/verifiers/services",
            post(services),
        )
        .with_state(IntegrationState(Some(runtime.clone())));
    for (bearer, body, expected) in [
        (
            None,
            json!({"member_ids":ids,"expected":log.head().to_json()}).to_string(),
            StatusCode::UNAUTHORIZED,
        ),
        (
            Some(token.clone()),
            json!({"member_ids":ids,"expected":log.head().to_json()}).to_string(),
            StatusCode::OK,
        ),
        (
            Some(token.clone()),
            json!({"member_ids":[id.clone(),id.clone()],"expected":log.head().to_json()})
                .to_string(),
            StatusCode::BAD_REQUEST,
        ),
        (
            Some(token.clone()),
            json!({"member_ids":ids,"expected":log.head().to_json(),"extra":null}).to_string(),
            StatusCode::BAD_REQUEST,
        ),
        (
            Some(token.clone()),
            format!(
                "{{\"member_ids\":[],\"member_ids\":[],\"expected\":{}}}",
                log.head().to_json()
            ),
            StatusCode::BAD_REQUEST,
        ),
    ] {
        let mut request = Request::builder()
            .method("POST")
            .uri(format!("/agora-build/v1/logs/{genesis}/verifiers/services"));
        if let Some(bearer) = bearer {
            request = request.header("authorization", format!("Bearer {bearer}"));
        }
        let response = router
            .clone()
            .oneshot(request.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), expected);
        let body: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 262_144).await.unwrap())
                .unwrap();
        if expected != StatusCode::OK {
            assert!(body.get("services").is_none());
        } else {
            assert!(body["services"][0]["auth_key"].is_object());
        }
    }
    claims["sub"] = json!("ab99999999999999999999999999");
    sqlx::query(
        "INSERT INTO account_identities(issuer,subject,principal) VALUES($1,$2,'other-principal')",
    )
    .bind(&issuer.issuer)
    .bind(claims["sub"].as_str().unwrap())
    .execute(&db.pool)
    .await
    .unwrap();
    let response = router
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/agora-build/v1/logs/{genesis}/verifiers/services"))
                .header(
                    "authorization",
                    format!("Bearer {}", issuer.token(issuer.header(), claims)),
                )
                .body(Body::from(
                    json!({"member_ids":ids,"expected":log.head().to_json()}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    sqlx::query("DELETE FROM station_service_keys")
        .execute(&db.pool)
        .await
        .unwrap();
    let snapshot = registry
        .managed_services_for(&genesis, PRINCIPAL, &runtime, &ids, &log.head())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(snapshot["services"], json!([{"id":id}]));
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_service_keys")
        .fetch_one(&db.pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
    registry.withdraw().await.unwrap();
    assert!(registry
        .managed_services_for(&genesis, PRINCIPAL, &runtime, &ids, &log.head())
        .await
        .is_err());
    drop(router);
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_builtin_verifier_inventories_recheck_policy_before_delivery() {
    use crate::integration_checkpoint::PortalCheckpoint;
    use crate::integration_feed::PolicyStore;
    use crate::remote_api::recovery::verifier_replicas::InventoryError;

    let origin = "https://station-dev.agora.build";
    let (db, runtime, f) = super::super::tests::fixture_at_station("https://auth.example", None, origin).await;
    let recovery = &runtime.app.recovery;
    recovery.configure_delegated(origin, 1).await.unwrap();
    recovery.configure_verifier_replicas(r#"{"generation":1,"replica":"a","replicas":["a"]}"#).await.unwrap();
    let registry = recovery.verifier_replicas().unwrap();
    let genesis = f.log.genesis_hash().to_hex();
    let ids = [format!("svc-{ID}")];
    let head = f.log.head();
    let binding = &runtime.binding;
    let replicas = || registry.snapshot_for(&genesis, PRINCIPAL, Some(binding));
    let services = || registry.managed_services_for(&genesis, PRINCIPAL, &runtime, &ids, &head);
    assert_eq!(replicas().await, Err(InventoryError::Suspended));
    assert_eq!(services().await, Err(InventoryError::Suspended));
    assert_eq!(registry.snapshot_for(&genesis, "foreign", Some(binding)).await.unwrap(), None);

    let peer = PolicyStore(db.reconnect(2).await);
    let prev = peer.load(binding).await.unwrap();
    let row = json!({"account":OWNER,"accountId":f.log.account_id(),"genesisHash":genesis,
        "bindingId":"binding-1","version":1,"bindingState":"bound"});
    let cut = json!({"cursor":0,"changes":[],"checkpoint":{"at":"2026-11-23T00:00:00.000Z",
        "integrations":[],"accounts":{"complete":true,"disabled":[]},"bindings":[row],"pendingReleases":[]}});
    let observed = PortalCheckpoint::parse(&serde_json::to_vec(&cut).unwrap(), binding).unwrap();
    let now = chrono::Utc::now().timestamp_millis();
    let mut stale = prev.apply_checkpoint(observed.clone(), now / 1000).unwrap();
    stale.record_completed_read(now - 60_000, now);
    peer.commit(&prev, &stale).await.unwrap();
    assert_eq!(replicas().await, Err(InventoryError::Suspended));
    assert_eq!(services().await, Err(InventoryError::Suspended));
    let mut current = stale.apply_checkpoint(observed, now / 1000).unwrap();
    current.record_completed_read(now, now);
    peer.commit(&stale, &current).await.unwrap();
    assert!(replicas().await.unwrap().is_some());
    assert!(services().await.unwrap().is_some());

    let release = json!({"changes":[{"id":1,"kind":"binding_released","integrationId":null,
        "state":null,"reason":"agora_build","at":"2026-11-23T00:00:00.000Z","releaseId":"release-1",
        "account":OWNER,"binding":{"accountId":f.log.account_id(),"genesisHash":genesis,
        "bindingId":"binding-1","version":1}}],"cursor":1,"integrations":[]});
    let mut rotated = binding.clone();
    rotated.report_client_id = "s-11234567890123456789012345".into();
    let empty = peer.load(&rotated).await.unwrap();
    let released = empty.apply(0, serde_json::from_value(release).unwrap(), now / 1000).unwrap();
    // Hold the root after each inventory transaction has taken its repeatable-read snapshot.
    let mut root_lock = db.pool.begin().await.unwrap();
    sqlx::query("SELECT 1 FROM remote_recovery_roots WHERE genesis_hash=$1 FOR UPDATE")
        .bind(&genesis).execute(&mut *root_lock).await.unwrap();
    let blocker: i32 = sqlx::query_scalar("SELECT pg_backend_pid()").fetch_one(&mut *root_lock).await.unwrap();
    let release_during_reads = async {
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            loop {
                let readers: i64 = sqlx::query_scalar(
                    "SELECT count(*) FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid))"
                ).bind(blocker).fetch_one(&peer.0).await.unwrap();
                if readers >= 2 { break; }
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            }
        }).await.unwrap();
        peer.commit(&empty, &released).await.unwrap();
        root_lock.commit().await.unwrap();
    };
    let (replica_read, service_read, ()) = tokio::join!(replicas(), services(), release_during_reads);
    assert_eq!(replica_read, Err(InventoryError::Suspended));
    assert_eq!(service_read, Err(InventoryError::Suspended));
    assert_eq!(peer.load(binding).await.unwrap(), current);
    assert_eq!(replicas().await, Err(InventoryError::Suspended));
    assert_eq!(services().await, Err(InventoryError::Suspended));
    assert_eq!(registry.snapshot_for(&genesis, "foreign", Some(binding)).await.unwrap(), None);
    peer.0.close().await;
    drop(runtime);
    db.cleanup().await;
}
