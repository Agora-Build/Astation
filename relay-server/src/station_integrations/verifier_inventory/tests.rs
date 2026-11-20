use super::super::tests::{append_body, fixture_with_issuer, request, ID, OWNER, PRINCIPAL};
use super::*;
use axum::{
    body::{to_bytes, Body},
    http::Request,
};
use tower::ServiceExt;

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
