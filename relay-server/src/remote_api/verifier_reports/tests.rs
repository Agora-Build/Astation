use super::*;
use crate::remote_api::{
    push_ingress::tests::Fixture,
    recovery::{Operation, RecoveryStore},
};
use atem_client::{
    member_report::{sign_verifier_report, verifier_report_body},
    KeyId, SignedObject,
};
use axum::http::{Method, Request};
use std::sync::Arc;
use tower::ServiceExt;

const ORIGIN: &str = "https://station-dev.agora.build";

fn challenge(f: &Fixture) -> ReportChallenge {
    ReportChallenge::new(
        "member:phone",
        "ios",
        ORIGIN,
        1,
        f.created,
        f.created + 30_000,
    )
    .unwrap()
}
fn nonce(c: &ReportChallenge) -> String {
    URL_SAFE_NO_PAD.encode(c.nonce())
}
fn create(f: &Fixture, c: &ReportChallenge) -> Command {
    Command::Create {
        challenge: c.clone(),
        expected: f.log.head(),
    }
}
fn report(f: &Fixture, c: &ReportChallenge, process: Option<u8>) -> Value {
    let body = verifier_report_body(&f.log, c, "member:phone", "ios", ORIGIN, f.created).unwrap();
    match process {
        None => sign_verifier_report(&f.keys, &KeyId::new("manager"), &body)
            .unwrap()
            .to_json(),
        Some(byte) => {
            let mut body = body.to_json();
            body["process"] = json!(URL_SAFE_NO_PAD.encode([byte; 16]));
            SignedObject::sign(&f.keys, &KeyId::new("manager"), body)
                .unwrap()
                .to_json()
        }
    }
}
fn publish(c: &ReportChallenge, report: Value) -> Command {
    Command::Publish {
        nonce: nonce(c),
        report,
    }
}

#[test]
fn immutable_challenges_and_distinct_signed_processes_survive_restart() {
    let f = Fixture::new(1_792_400_000_000);
    let c = challenge(&f);
    let mut records = BTreeMap::new();
    let run =
        |records: &mut BTreeMap<_, _>, command| apply(records, &f.log, ORIGIN, command, f.created);
    let _ = run(&mut records, create(&f, &c)).unwrap();
    let _ = run(&mut records, publish(&c, report(&f, &c, None))).unwrap();
    let _ = run(&mut records, publish(&c, report(&f, &c, Some(2)))).unwrap();
    let saved = serde_json::to_value(&records).unwrap();
    let mut restored = serde_json::from_value(saved).unwrap();
    let reply = run(&mut restored, create(&f, &c)).unwrap().1 .0;
    assert_eq!(reply["reports"].as_array().unwrap().len(), 2);
    for report in reply["reports"].as_array().unwrap() {
        verify_verifier_report(&f.log, report.to_string().as_bytes(), &c, f.created).unwrap();
    }
    for process in [3, 4] {
        let _ = run(&mut restored, publish(&c, report(&f, &c, Some(process)))).unwrap();
    }
    assert_eq!(
        run(&mut restored, publish(&c, report(&f, &c, Some(5))))
            .unwrap_err()
            .0,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(restored[&nonce(&c)].reports.len(), MAX_REPORTS);
    let mut changed = c.to_json();
    changed["connection"] = json!(2);
    let changed = ReportChallenge::parse(changed.to_string().as_bytes()).unwrap();
    assert_eq!(
        run(&mut restored, create(&f, &changed)).unwrap_err().0,
        StatusCode::CONFLICT
    );
    let _ = run(&mut restored, Command::Close { nonce: nonce(&c) }).unwrap();
    assert_eq!(
        run(&mut restored, create(&f, &c)).unwrap_err().0,
        StatusCode::GONE
    );
}

#[test]
fn bad_signatures_wrong_challenges_and_changed_same_process_never_replace_reports() {
    let f = Fixture::new(1_792_400_000_000);
    let c = challenge(&f);
    let mut records = BTreeMap::new();
    let _ = apply(&mut records, &f.log, ORIGIN, create(&f, &c), f.created).unwrap();
    let good = report(&f, &c, None);
    let mut bad = good.clone();
    bad["sig"] = json!(URL_SAFE_NO_PAD.encode([0; 64]));
    for value in [bad, report(&f, &challenge(&f), None)] {
        assert_eq!(
            apply(&mut records, &f.log, ORIGIN, publish(&c, value), f.created)
                .unwrap_err()
                .0,
            StatusCode::BAD_REQUEST
        );
    }
    let _ = apply(
        &mut records,
        &f.log,
        ORIGIN,
        publish(&c, good.clone()),
        f.created,
    )
    .unwrap();
    let _ = apply(
        &mut records,
        &f.log,
        ORIGIN,
        publish(&c, good.clone()),
        f.created,
    )
    .unwrap();
    let resigned = SignedObject::sign(&f.keys, &KeyId::new("manager"), good["body"].clone())
        .unwrap()
        .to_json();
    let _ = apply(
        &mut records,
        &f.log,
        ORIGIN,
        publish(&c, resigned),
        f.created,
    )
    .unwrap();
    let mut body = good["body"].clone();
    body["verifier"]["version"] = json!(99);
    let changed = SignedObject::sign(&f.keys, &KeyId::new("manager"), body)
        .unwrap()
        .to_json();
    assert_eq!(
        apply(
            &mut records,
            &f.log,
            ORIGIN,
            publish(&c, changed),
            f.created
        )
        .unwrap_err()
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(records[&nonce(&c)].reports.len(), 1);
}

#[test]
fn inbox_is_exact_and_account_storage_and_response_sizes_are_bounded() {
    let f = Fixture::new(1_792_400_000_000);
    let mut records = BTreeMap::new();
    for slot in 0..8 {
        for n in 0..MAX_PER_SLOT {
            let c = ReportChallenge::new(
                "member:phone",
                &format!("slot-{slot}"),
                ORIGIN,
                n as u64 + 1,
                f.created,
                f.created + 30_000,
            )
            .unwrap();
            let _ = apply(&mut records, &f.log, ORIGIN, create(&f, &c), f.created).unwrap();
        }
    }
    assert_eq!(records.len(), MAX_PENDING);
    assert_eq!(
        apply(
            &mut records,
            &f.log,
            ORIGIN,
            create(&f, &challenge(&f)),
            f.created
        )
        .unwrap_err()
        .0,
        StatusCode::TOO_MANY_REQUESTS
    );
    for (slot, count) in [("slot-0", MAX_PER_SLOT), ("absent", 0)] {
        let reply = apply(
            &mut records,
            &f.log,
            ORIGIN,
            Command::Inbox {
                signer: "member:phone".into(),
                slot: slot.into(),
                expected: f.log.head(),
            },
            f.created,
        )
        .unwrap();
        assert_eq!(reply.1 .0["challenges"].as_array().unwrap().len(), count);
        assert!(reply.1 .0.to_string().len() < 262_144);
    }
    collect(&mut records, f.created + 60_000);
    assert!(records.is_empty());
    for _ in 0..MAX_PER_SLOT {
        let c = challenge(&f);
        let _ = apply(&mut records, &f.log, ORIGIN, create(&f, &c), f.created).unwrap();
    }
    assert_eq!(
        apply(
            &mut records,
            &f.log,
            ORIGIN,
            create(&f, &challenge(&f)),
            f.created
        )
        .unwrap_err()
        .0,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(records.len(), MAX_PER_SLOT);
}

#[test]
fn expiry_foreign_origin_membership_changes_and_foreign_signers_refuse() {
    let f = Fixture::new(1_792_400_000_000);
    let c = challenge(&f);
    let mut records = BTreeMap::new();
    assert_eq!(
        apply(
            &mut records,
            &f.log,
            "https://other.example",
            create(&f, &c),
            f.created
        )
        .unwrap_err()
        .0,
        StatusCode::CONFLICT
    );
    let _ = apply(&mut records, &f.log, ORIGIN, create(&f, &c), f.created).unwrap();
    assert_eq!(
        apply(
            &mut records,
            &f.log,
            ORIGIN,
            Command::Read { nonce: nonce(&c) },
            f.created + 30_000
        )
        .unwrap_err()
        .0,
        StatusCode::GONE
    );
    for signer in ["member:absent", "service:phone", "host:host-a"] {
        let cmd = Command::Inbox {
            signer: signer.into(),
            slot: "ios".into(),
            expected: f.log.head(),
        };
        assert!(apply(&mut records, &f.log, ORIGIN, cmd, f.created).is_err());
    }
    let mut stale = f.log.head();
    stale.seq -= 1;
    assert_eq!(
        apply(
            &mut records,
            &f.log,
            ORIGIN,
            Command::Inbox {
                signer: "member:phone".into(),
                slot: "ios".into(),
                expected: stale
            },
            f.created
        )
        .unwrap_err()
        .0,
        StatusCode::CONFLICT
    );
}

#[test]
fn advancing_membership_retires_old_calls_but_preserves_authenticated_ancestor_responses() {
    use atem_client::membership::{sign_entry, Action, HostNow, Role, RolesChange};
    let mut f = Fixture::new(1_792_400_000_000);
    let ancestor = Membership::from_stored(
        f.log.account_id(),
        &f.log.genesis_hash(),
        &f.log.to_stored(),
    )
    .unwrap();
    let old = challenge(&f);
    let mut records = BTreeMap::new();
    let _ = apply(&mut records, &f.log, ORIGIN, create(&f, &old), f.created).unwrap();
    let entry = sign_entry(
        &f.keys,
        &KeyId::new("manager"),
        f.log.draft(
            "phone",
            f.created,
            &Action::SetRoles {
                device_id: "phone".into(),
                change: RolesChange::Native(
                    [Role::Control, Role::Manage, Role::View]
                        .into_iter()
                        .collect(),
                ),
            },
        ),
    )
    .unwrap();
    let result = f.log.evaluate_objects(
        &[entry.object().clone()],
        &HostNow {
            wall_ms: f.created,
            mono_ms: 0,
            boot_id: "test".into(),
        },
    );
    assert_eq!(result.appended, 1);
    f.log = result.next;
    assert_eq!(
        apply(
            &mut records,
            &f.log,
            ORIGIN,
            Command::Read { nonce: nonce(&old) },
            f.created
        )
        .unwrap_err()
        .0,
        StatusCode::CONFLICT
    );
    let next = challenge(&f);
    let _ = apply(&mut records, &f.log, ORIGIN, create(&f, &next), f.created).unwrap();
    let mut body = verifier_report_body(&ancestor, &next, "member:phone", "ios", ORIGIN, f.created)
        .unwrap()
        .to_json();
    body["process"] = json!(URL_SAFE_NO_PAD.encode([5; 16]));
    let report = SignedObject::sign(&f.keys, &KeyId::new("manager"), body)
        .unwrap()
        .to_json();
    assert!(
        !verify_verifier_report(&f.log, report.to_string().as_bytes(), &next, f.created)
            .unwrap()
            .at_head
    );
    let reply = apply(
        &mut records,
        &f.log,
        ORIGIN,
        publish(&next, report.clone()),
        f.created,
    )
    .unwrap();
    assert_eq!(reply.1 .0["reports"], json!([report]));
}

#[tokio::test]
async fn default_runtime_keeps_all_carriage_routes_disabled() {
    let mut state = crate::tests::test_state();
    state.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        state.knowledge.clone(),
        state.vault.clone(),
        Arc::new(super::super::tests::TestAccountVerifier),
    ));
    let app = axum::Router::new()
        .nest("/api/remote/v1", crate::remote_api::routes())
        .with_state(state);
    let root = "a".repeat(64);
    for (method, suffix) in [
        (Method::POST, "verifier-reports"),
        (Method::POST, "verifier-requests"),
        (Method::GET, "verifier-reports/nonce"),
        (Method::POST, "verifier-reports/nonce"),
        (Method::DELETE, "verifier-reports/nonce"),
    ] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(format!("/api/remote/v1/logs/{root}/{suffix}"))
                    .header("authorization", "Bearer alice")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(response.headers()["cache-control"], "no-store");
    }
}

#[cfg(feature = "delegated-host-work")]
#[tokio::test]
async fn actual_http_requires_account_login_and_refuses_foreign_roots_and_malformed_input() {
    let mut state = crate::tests::test_state();
    state.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        state.knowledge.clone(),
        state.vault.clone(),
        Arc::new(super::super::tests::TestAccountVerifier),
    ));
    state.recovery = RecoveryStore::memory();
    state.recovery.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = Fixture::new(super::super::now().wall_ms);
    f.publish(&state.recovery).await;
    let c = challenge(&f);
    let genesis = f.log.genesis_hash().to_hex();
    let app = axum::Router::new()
        .nest("/api/remote/v1", crate::remote_api::routes())
        .with_state(state);
    let path = format!("/api/remote/v1/logs/{genesis}/verifier-reports");
    let body = json!({"challenge":c.to_json(),"expected":f.log.head().to_json()}).to_string();
    for (owner, raw, expected) in [
        (None, body.clone(), StatusCode::UNAUTHORIZED),
        (Some("mallory"), body.clone(), StatusCode::NOT_FOUND),
        (Some("alice"), body.clone(), StatusCode::OK),
        (
            Some("alice"),
            body.replacen("\"challenge\":", "\"challenge\":null,\"challenge\":", 1),
            StatusCode::BAD_REQUEST,
        ),
        (
            Some("alice"),
            " ".repeat(MAX_BODY + 1),
            StatusCode::BAD_REQUEST,
        ),
    ] {
        let mut request = Request::builder()
            .method(Method::POST)
            .uri(&path)
            .header("content-type", "application/json");
        if let Some(owner) = owner {
            request = request.header("authorization", format!("Bearer {owner}"));
        }
        let response = app
            .clone()
            .oneshot(request.body(Body::from(raw)).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), expected);
        assert_eq!(response.headers()["cache-control"], "no-store");
    }
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(format!("{path}/{}", nonce(&c)))
                .header("authorization", "Bearer alice")
                .body(Body::from(
                    json!({"report":report(&f, &c, None)}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_replicas_commit_once_and_restart_without_exposing_failed_writes() {
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = RecoveryStore::postgres(db.pool.clone());
    let replica = RecoveryStore::postgres(db.reconnect(4).await);
    #[cfg(feature = "delegated-host-work")]
    {
        store.configure_delegated(ORIGIN, 1).await.unwrap();
        replica.configure_delegated(ORIGIN, 1).await.unwrap();
    }
    let f = Fixture::new(super::super::now().wall_ms);
    f.publish(&store).await;
    let c = challenge(&f);
    let genesis = f.log.genesis_hash().to_hex();
    let op = |command| Operation::VerifierReport {
        origin: ORIGIN.into(),
        command,
    };
    #[cfg(feature = "delegated-host-work")]
    let portal = {
        use crate::integration_checkpoint::PortalCheckpoint;
        use crate::integration_feed::{FeedBinding, PolicyStore};
        let portal = FeedBinding {
            issuer: "https://auth.example".into(), portal_origin: "https://portal.example".into(),
            station_origin: ORIGIN.into(), report_client_id: "s-01234567890123456789012345".into(),
        };
        assert_eq!(store.perform(&genesis,"alice",op(create(&f,&c))).await.0, StatusCode::SERVICE_UNAVAILABLE);
        store.set_verifier_portal(&portal).unwrap();
        replica.set_verifier_portal(&portal).unwrap();
        let owner = "ab01234567890123456789012345";
        sqlx::query("INSERT INTO account_identities (issuer,subject,principal) VALUES ($1,$2,'alice')")
            .bind(&portal.issuer).bind(owner).execute(&db.pool).await.unwrap();
        let policies = PolicyStore(db.pool.clone());
        let empty = policies.load(&portal).await.unwrap();
        let page = json!({"changes":[{"id":1,"kind":"noop"}],"cursor":1,"integrations":[]});
        let initial = empty.apply(0, serde_json::from_value(page).unwrap(), 100).unwrap();
        policies.commit(&empty, &initial).await.unwrap();
        let cut = json!({"changes":[],"cursor":1,"checkpoint":{
            "at":"2026-11-23T00:00:00.000Z","integrations":[],"accounts":{"complete":true,"disabled":[]},
            "bindings":[{"account":owner,"accountId":f.log.account_id(),"genesisHash":genesis,
                "bindingId":"binding-1","version":1,"bindingState":"bound"}],"pendingReleases":[]}});
        let source = PortalCheckpoint::parse(&serde_json::to_vec(&cut).unwrap(), &portal).unwrap();
        let observed = initial.apply_checkpoint(source, 101).unwrap();
        policies.commit(&initial, &observed).await.unwrap();
        assert_eq!(replica.perform(&genesis,"alice",op(create(&f,&c))).await.0, StatusCode::SERVICE_UNAVAILABLE);
        let now = chrono::Utc::now().timestamp_millis();
        let mut fresh = observed.apply(1, serde_json::from_value(json!({"changes":[],"cursor":1})).unwrap(),now/1000).unwrap();
        fresh.record_completed_read(now, now);
        policies.commit(&observed, &fresh).await.unwrap();
        portal
    };
    assert_eq!(
        store.perform(&genesis, "alice", op(create(&f, &c))).await.0,
        StatusCode::OK
    );
    let (a, b) = tokio::join!(
        store.perform(&genesis, "alice", op(publish(&c, report(&f, &c, None)))),
        replica.perform(&genesis, "alice", op(publish(&c, report(&f, &c, Some(2)))))
    );
    assert_eq!((a.0, b.0), (StatusCode::OK, StatusCode::OK));
    let before = replica
        .perform(&genesis, "alice", op(Command::Read { nonce: nonce(&c) }))
        .await
        .1
         .0;
    assert_eq!(before["reports"].as_array().unwrap().len(), 2);
    sqlx::query(
        "ALTER TABLE remote_recovery_roots ADD CONSTRAINT inject_failure CHECK (false) NOT VALID",
    )
    .execute(&db.pool)
    .await
    .unwrap();
    assert_eq!(
        store
            .perform(&genesis, "alice", op(publish(&c, report(&f, &c, Some(3)))))
            .await
            .0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    sqlx::query("ALTER TABLE remote_recovery_roots DROP CONSTRAINT inject_failure")
        .execute(&db.pool)
        .await
        .unwrap();
    let restarted = RecoveryStore::postgres(db.reconnect(2).await);
    #[cfg(feature = "delegated-host-work")]
    {
        restarted.configure_delegated(ORIGIN, 1).await.unwrap();
        restarted.set_verifier_portal(&portal).unwrap();
    }
    assert_eq!(
        restarted
            .perform(&genesis, "alice", op(Command::Read { nonce: nonce(&c) }))
            .await
            .1
             .0,
        before
    );
    assert_eq!(
        restarted
            .perform(&genesis, "mallory", op(Command::Read { nonce: nonce(&c) }))
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    #[cfg(feature = "delegated-host-work")]
    {
        // A release on the peer blocks both reading an existing nonce and
        // writing a valid proof for it, even before the Portal sees our report.
        let policies = crate::integration_feed::PolicyStore(db.pool.clone());
        let before = policies.load(&portal).await.unwrap();
        let page = json!({"changes":[{"id":2,"kind":"binding_released","integrationId":null,
            "state":null,"reason":"agora_build","at":"2026-11-23T00:00:00.000Z",
            "releaseId":"release-1","account":"ab01234567890123456789012345","binding":{
            "accountId":f.log.account_id(),"genesisHash":genesis,"bindingId":"binding-1","version":1}}],"cursor":2});
        let now = chrono::Utc::now().timestamp_millis();
        let mut released = before.apply(1,serde_json::from_value(page).unwrap(),now/1000).unwrap();
        released.record_completed_read(now, now);
        policies.commit(&before, &released).await.unwrap();
        for cmd in [Command::Read { nonce:nonce(&c) }, publish(&c, report(&f,&c,Some(3)))] {
            let reply = restarted.perform(&genesis,"alice",op(cmd)).await;
            assert_eq!(reply.0, StatusCode::SERVICE_UNAVAILABLE);
            assert_eq!(reply.1.0["error"]["code"], "service_suspended");
        }
        super::super::delegated_recovery::Binding::new(ORIGIN, 1)
            .unwrap()
            .initialize(&db.pool, true)
            .await
            .unwrap();
        for command in [
            Command::Read { nonce: nonce(&c) },
            publish(&c, report(&f, &c, Some(3))),
        ] {
            assert_eq!(
                store.perform(&genesis, "alice", op(command)).await.0,
                StatusCode::SERVICE_UNAVAILABLE
            );
        }
    }
    store.pool().unwrap().close().await;
    replica.pool().unwrap().close().await;
    restarted.pool().unwrap().close().await;
    db.cleanup().await;
}
