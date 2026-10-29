use super::*;
use crate::remote_api::{push_ingress::tests::Fixture, recovery::RecoveryStore};
use atem_client::membership::Head;
use ring::{rand::SystemRandom, signature};
pub(crate) const OWNER: &str = "ab01234567890123456789012345";
pub(crate) const PRINCIPAL: &str = "principal-12345678-1234-4567-89ab-123456789abc";
pub(crate) const ID: &str = "i-01234567890123456789012345";

pub(crate) async fn fixture() -> (
    crate::test_database::TestDatabase,
    Arc<StationIntegrations>,
    Fixture,
) {
    fixture_with_issuer("https://auth.example").await
}

pub(crate) async fn fixture_with_issuer(
    issuer: &str,
) -> (
    crate::test_database::TestDatabase,
    Arc<StationIntegrations>,
    Fixture,
) {
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 8).await;
    let mut app = crate::tests::test_state();
    app.recovery = RecoveryStore::postgres(db.pool.clone());
    app.accounts = Arc::new(crate::account_store::PgAccountStore::new(db.pool.clone()));
    sqlx::query("INSERT INTO account_identities (issuer,subject,principal) VALUES ($1,$2,$3)")
        .bind(issuer)
        .bind(OWNER)
        .bind(PRINCIPAL)
        .execute(&db.pool)
        .await
        .unwrap();
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    for entry in f.log.entries() {
        assert_eq!(
            app.recovery
                .append_test_entry(
                    &f.log.genesis_hash().to_hex(),
                    PRINCIPAL,
                    entry.clone(),
                    Head {
                        seq: entry.seq - 1,
                        hash: entry.prev_hash
                    }
                )
                .await,
            StatusCode::OK
        );
    }
    let report = signature::EcdsaKeyPair::generate_pkcs8(
        &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
        &SystemRandom::new(),
    )
    .unwrap();
    let runtime = StationIntegrations::new(
        app,
        FeedBinding {
            issuer: issuer.into(),
            portal_origin: "https://portal.example".into(),
            station_origin: "https://custom.example".into(),
            report_client_id: "s-01234567890123456789012345".into(),
        },
        ServiceKeyVault::new(&[42; 32], "operator-test").unwrap(),
        StationReportKey::from_pkcs8(report.as_ref()).unwrap(),
    )
    .unwrap();
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let page=serde_json::from_value(json!({"changes":[],"cursor":0,"integrations":[{"id":ID,"ownerAccount":OWNER,"state":"awaiting_approval","scopes":["agent.view","agent.prompt","agent.approve"],"r9Svc":null,"expiresAt":(chrono::Utc::now()+chrono::Duration::days(1)).to_rfc3339(),"quotaPerSecond":10}]})).unwrap();
    runtime
        .policies
        .commit(
            &previous,
            &previous
                .apply(0, page, chrono::Utc::now().timestamp())
                .unwrap(),
        )
        .await
        .unwrap();
    (db, runtime, f)
}
pub(crate) fn request(f: &Fixture) -> ProvisionRequest {
    ProvisionRequest {
        genesis_hash: f.log.genesis_hash().to_hex(),
        manager_id: "phone".into(),
        expected_head: f.log.head().to_json(),
        signed_at: chrono::Utc::now().timestamp_millis() as u64,
        hosts: vec!["host-a".into()],
        sessions: None,
        projects: None,
    }
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_provisioning_binds_owner_root_exact_scope_and_durable_key() {
    let (db, runtime, f) = fixture().await;
    assert!(runtime
        .prepare(ID, "ab99999999999999999999999999", request(&f))
        .await
        .is_err());
    let first = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
    let retry = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
    assert_eq!(first["fingerprint"], retry["fingerprint"]);
    let body: Value = serde_json::from_str(first["bodyJSON"].as_str().unwrap()).unwrap();
    assert_eq!(
        body["member"]["scope"],
        json!({"hosts":["host-a"],"ops":["approval","prompt","rule_revoke","view"]})
    );
    assert_eq!(body["member"]["roles"], json!(["service"]));
    assert!(body["member"].get("enc_key").is_none());
    assert_eq!(first["hostedExecutionEnabled"], false);
    let stored: String = sqlx::query_scalar("SELECT context FROM station_integration_provisioning")
        .fetch_one(&db.pool).await.unwrap();
    let context: ServiceKeyContext = serde_json::from_str(&stored).unwrap();
    assert_eq!(context.owner, OWNER, "external owner stays bound to tokens and sealed service keys");
    assert_eq!(runtime.owner_principal(OWNER).await.unwrap(), PRINCIPAL);
    let mut stale = request(&f);
    stale.expected_head["hash"] = json!("f".repeat(64));
    assert!(runtime.prepare(ID, OWNER, stale).await.is_err());
    let mut overbroad = request(&f);
    overbroad.hosts = vec!["unknown-host".into()];
    assert!(runtime.prepare(ID, OWNER, overbroad).await.is_err());
    runtime.policies.deny(&runtime.binding).await.unwrap();
    assert!(runtime.prepare(ID, OWNER, request(&f)).await.is_err());
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_provisioning_never_aliases_another_issuer_or_creates_an_owner() {
    let (db, runtime, f) = fixture().await;
    sqlx::query("UPDATE account_identities SET issuer='https://another-issuer.example'")
        .execute(&db.pool).await.unwrap();
    assert_eq!(runtime.prepare(ID, OWNER, request(&f)).await.unwrap_err().status(), StatusCode::SERVICE_UNAVAILABLE);
    assert!(runtime.owner_principal(PRINCIPAL).await.is_err(), "a principal is not an external subject alias");
    let identities: i64 = sqlx::query_scalar("SELECT count(*) FROM account_identities")
        .fetch_one(&db.pool).await.unwrap();
    let keys: i64 = sqlx::query_scalar("SELECT count(*) FROM station_service_keys")
        .fetch_one(&db.pool).await.unwrap();
    assert_eq!(identities, 1, "a policy feed cannot enroll an account identity");
    assert_eq!(keys, 0);
    sqlx::query("UPDATE account_identities SET issuer=$1, principal='unrelated-principal'")
        .bind(&runtime.binding.issuer).execute(&db.pool).await.unwrap();
    assert!(runtime.prepare(ID, OWNER, request(&f)).await.is_err(), "the mapped principal must own the recovery root");
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_provisioning_missing_or_unreadable_key_never_rotates_an_identity() {
    let (db, runtime, f) = fixture().await;
    runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
    sqlx::query("UPDATE station_service_keys SET sealed='corrupt'")
        .execute(&db.pool)
        .await
        .unwrap();
    assert!(runtime.prepare(ID, OWNER, request(&f)).await.is_err());
    let stored: String = sqlx::query_scalar("SELECT sealed FROM station_service_keys")
        .fetch_one(&db.pool)
        .await
        .unwrap();
    assert_eq!(stored, "corrupt");
    sqlx::query("DELETE FROM station_service_keys")
        .execute(&db.pool)
        .await
        .unwrap();
    assert!(runtime.prepare(ID, OWNER, request(&f)).await.is_err());
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_service_keys")
        .fetch_one(&db.pool)
        .await
        .unwrap();
    assert_eq!(
        count, 0,
        "an established missing key must not be regenerated"
    );
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_feed_pacing_is_shared_by_replicas() {
    let (db, runtime, _) = fixture().await;
    let replica = PolicyStore(db.reconnect(2).await);
    let (a, b) = tokio::join!(
        runtime.policies.claim_poll(&runtime.binding),
        replica.claim_poll(&runtime.binding)
    );
    assert_ne!(a.unwrap(), b.unwrap());
    assert!(!runtime.policies.claim_poll(&runtime.binding).await.unwrap());
    replica.0.close().await;
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_background_poll_nudge_restart_and_closed_readiness() {
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 6).await;
    let mut portal = crate::integration_portal::tests::Fixture::new().await;
    *portal.shared.feed.lock().await = Some(json!({"changes":[],"cursor":0,"integrations":[{
        "id":ID,"ownerAccount":OWNER,"state":"provisioning","scopes":["agent.view"],"r9Svc":"a".repeat(64),
        "expiresAt":(chrono::Utc::now()+chrono::Duration::days(1)).to_rfc3339(),"quotaPerSecond":10}]}));
    let mut app = crate::tests::test_state();
    app.recovery = RecoveryStore::postgres(db.pool.clone());
    let runtime = StationIntegrations::new(
        app,
        portal.binding.clone(),
        ServiceKeyVault::new(&[42; 32], "operator-test").unwrap(),
        portal.key.take().unwrap(),
    )
    .unwrap();
    let worker = tokio::spawn(runtime.clone().run());
    tokio::time::timeout(Duration::from_secs(4), async {
        while portal.shared.reports.lock().await.is_empty() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        portal.shared.reports.lock().await[0]["state"],
        "waiting_for_host"
    );
    assert_eq!(
        portal.shared.reports.lock().await[0]["reason"],
        "Hosted execution awaits end-to-end verification"
    );
    let saved = runtime.policies.load(&runtime.binding).await.unwrap();
    assert!(!saved.denied);
    // An unsigned nudge asks for a fresh authenticated snapshot, not a cursor jump.
    let response = nudge(
        State(IntegrationState(Some(runtime.clone()))),
        axum::body::Bytes::from_static(br#"{"cursor":999999}"#),
    )
    .await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);
    tokio::time::timeout(Duration::from_secs(4), async {
        while portal.shared.cursors.lock().await.len() < 2 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert!(portal.shared.cursors.lock().await.iter().all(|&v| v == 0));
    tokio::time::timeout(Duration::from_secs(4), async {
        while runtime
            .policies
            .load(&runtime.binding)
            .await
            .unwrap()
            .revision
            <= saved.revision
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let before_restart = runtime
        .policies
        .load(&runtime.binding)
        .await
        .unwrap()
        .revision;
    worker.abort();
    let _ = worker.await;
    let worker = tokio::spawn(runtime.clone().run());
    tokio::time::timeout(Duration::from_secs(4), async {
        while runtime
            .policies
            .load(&runtime.binding)
            .await
            .unwrap()
            .revision
            <= before_restart
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        runtime
            .policies
            .load(&runtime.binding)
            .await
            .unwrap()
            .cursor,
        0
    );
    assert!(!portal
        .shared
        .reports
        .lock()
        .await
        .iter()
        .any(|v| v["state"] == "ready"));
    worker.abort();
    let _ = worker.await;
    drop(runtime);
    drop(portal);
    db.cleanup().await;
}

async fn signed_action(runtime: &StationIntegrations, f: &Fixture, action: atem_client::membership::Action) {
    let log = runtime.recovery_log(&f.log.genesis_hash().to_hex(), OWNER).await.unwrap();
    let body = log.draft("phone", chrono::Utc::now().timestamp_millis() as u64, &action);
    append_body(runtime, f, body).await;
}

async fn append_body(runtime: &StationIntegrations, f: &Fixture, body: Value) {
    use atem_client::{membership::Entry, signed::SignedObject};
    let log = runtime.recovery_log(&f.log.genesis_hash().to_hex(), OWNER).await.unwrap();
    let entry = Entry::parse_bytes(SignedObject::sign(&f.keys, &KeyId::new("manager"), body).unwrap()
        .to_json().to_string().as_bytes()).unwrap();
    assert_eq!(runtime.app.recovery.append_test_entry(&f.log.genesis_hash().to_hex(), PRINCIPAL,
        entry, log.head()).await, StatusCode::OK);
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_revocation_requires_signed_removal_and_durable_key_deletion_before_report() {
    let mut portal = crate::integration_portal::tests::Fixture::new().await;
    let (db, mut runtime, f) = fixture_with_issuer(&portal.binding.issuer).await;
    let original = runtime.policies.load(&runtime.binding).await.unwrap();
    {
        let r = Arc::get_mut(&mut runtime).unwrap();
        r.binding = portal.binding.clone();
        r.portal = PortalReportClient::new(r.binding.clone(), portal.key.take().unwrap()).unwrap();
    }
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let mut next = previous.clone();
    next.integrations = original.integrations;
    next.revision += 1; next.denied = false; next.received_at = chrono::Utc::now().timestamp();
    runtime.policies.commit(&previous, &next).await.unwrap();
    let draft = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let mut next = previous.clone();
    next.revision += 1;
    let policy = next.integrations.get_mut(ID).unwrap();
    policy.state = "revoking".into();
    policy.r9_svc = Some(draft["fingerprint"].as_str().unwrap().into());
    policy.expires_at = (chrono::Utc::now() - chrono::Duration::days(1)).to_rfc3339();
    runtime.policies.commit(&previous, &next).await.unwrap();
    assert!(runtime.revoked_context(ID).await.is_err(), "a never-added member is not a signed removal");
    runtime.report_revocations().await;
    assert!(portal.shared.reports.lock().await.is_empty());

    append_body(&runtime, &f, serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap()).await;
    assert!(runtime.revoked_context(ID).await.is_err(), "revoking policy alone cannot remove membership");
    signed_action(&runtime, &f, atem_client::membership::Action::Remove { device_id: format!("svc-{ID}") }).await;
    let context = runtime.revoked_context(ID).await.unwrap();

    sqlx::query("UPDATE account_identities SET issuer='https://unrelated-issuer.example'").execute(&db.pool).await.unwrap();
    assert!(runtime.revoked_context(ID).await.is_err(), "revocation cannot alias a different issuer's owner");
    runtime.report_revocations().await;
    assert!(portal.shared.reports.lock().await.is_empty());
    sqlx::query("UPDATE account_identities SET issuer=$1").bind(&runtime.binding.issuer).execute(&db.pool).await.unwrap();

    // A wrong fingerprint or a denied feed cannot authorize cleanup, even
    // though a valid signature removed some service from the account.
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let mut wrong = previous.clone(); wrong.revision += 1;
    wrong.integrations.get_mut(ID).unwrap().r9_svc = Some("f".repeat(64));
    runtime.policies.commit(&previous, &wrong).await.unwrap();
    runtime.report_revocations().await;
    assert!(portal.shared.reports.lock().await.is_empty());
    let mut restored = wrong.clone(); restored.revision += 1;
    restored.integrations = previous.integrations;
    runtime.policies.commit(&wrong, &restored).await.unwrap();
    runtime.policies.deny(&runtime.binding).await.unwrap();
    assert!(runtime.revoked_context(ID).await.is_err());
    let denied = runtime.policies.load(&runtime.binding).await.unwrap();
    let mut renewed = denied.clone(); renewed.revision += 1; renewed.denied = false;
    runtime.policies.commit(&denied, &renewed).await.unwrap();

    sqlx::query("CREATE FUNCTION fail_service_key_delete() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test delete failure'; END $$")
        .execute(&db.pool).await.unwrap();
    sqlx::query("CREATE TRIGGER fail_service_key_delete BEFORE DELETE ON station_service_keys FOR EACH ROW EXECUTE FUNCTION fail_service_key_delete()")
        .execute(&db.pool).await.unwrap();
    runtime.report_revocations().await;
    assert!(portal.shared.reports.lock().await.is_empty(), "never report completion after failed durable cleanup");
    let keys: i64 = sqlx::query_scalar("SELECT count(*) FROM station_service_keys").fetch_one(&db.pool).await.unwrap();
    assert_eq!(keys, 1);
    sqlx::query("DROP TRIGGER fail_service_key_delete ON station_service_keys").execute(&db.pool).await.unwrap();
    portal.set_status(503);
    runtime.report_revocations().await;
    assert_eq!(*portal.shared.reports.lock().await, vec![json!({"integrationId":ID,"state":"revoked"})]);
    let keys: i64 = sqlx::query_scalar("SELECT count(*) FROM station_service_keys").fetch_one(&db.pool).await.unwrap();
    assert_eq!(keys, 0);
    assert!(service_keys::load_approved(&db.pool, &runtime.vault, &context, draft["fingerprint"].as_str().unwrap()).await.is_err());
    assert!(runtime.prepare(ID, OWNER, request(&f)).await.is_err(), "a retry must not regenerate a revoked key");
    portal.set_status(200);
    runtime.report_revocations().await;
    assert_eq!(portal.shared.reports.lock().await.len(), 2, "a failed report retries with the key already deleted");
    runtime.report_revocations().await;
    assert_eq!(portal.shared.reports.lock().await.len(), 3, "repeated cleanup reports are idempotent");
    assert!(!crate::hosted_agents::HOSTED_EXECUTION_ENABLED);
    drop(runtime); drop(portal); db.cleanup().await;
}

#[cfg(unix)]
#[test]
fn operator_keys_refuse_world_readable_symlink_empty_and_oversized_files() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let folder = std::env::temp_dir().join(format!("station-key-test-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&folder).unwrap();
    let file = folder.join("wrapping");
    std::fs::write(&file, [9; 32]).unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(
        protected_file(file.to_str().unwrap(), 32).unwrap().len(),
        32
    );
    let link = folder.join("link");
    symlink(&file, &link).unwrap();
    assert!(protected_file(link.to_str().unwrap(), 32).is_err());
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(protected_file(file.to_str().unwrap(), 32).is_err());
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::write(&file, [9; 33]).unwrap();
    assert!(protected_file(file.to_str().unwrap(), 32).is_err());
    std::fs::write(&file, []).unwrap();
    assert!(protected_file(file.to_str().unwrap(), 32).is_err());
    std::fs::remove_dir_all(folder).unwrap();
}
