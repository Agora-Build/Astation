use super::*;
use crate::{
    account_identity::{VerifiedIdentity, VerifiedServiceToken},
    relay::tests::{connect_atem, next_client_json, send_json, spawn_relay},
    remote_api::push_ingress::tests::Fixture,
    service_keys::ServiceKeyContext,
    station_integrations::tests::{fixture, request, ID, OWNER, PRINCIPAL},
};
use atem_client::{
    channel::responder::{HostContext, Responder},
    membership::Entry,
    principal::Authority,
    session::{
        new_id,
        r9::{Hello, Welcome, R9_FEATURES},
        revision::KNOWN_FEATURES,
    },
    KeyId, SignedObject,
};
use axum::{
    body::{to_bytes, Body},
    http::Request,
    routing::get,
    Router,
};
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn production_hosted_routes_are_closed_even_with_no_runtime() {
    let router = routes().with_state(crate::station_integrations::IntegrationState(None));
    for (method, path) in [
        ("GET", "sessions"),
        ("GET", "events"),
        ("POST", "sessions/ses-aaaaaaaaaaaa/prompts"),
        ("POST", "sessions/ses-aaaaaaaaaaaa/approvals"),
        ("POST", "sessions/ses-aaaaaaaaaaaa/rules/revoke"),
        ("POST", "sessions/ses-aaaaaaaaaaaa/receipts"),
    ] {
        let response = router
            .clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(format!(
                        "/api/agent/v1/integrations/{ID}/hosts/host-a/{path}"
                    ))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert!(matches!(
            response.status(),
            StatusCode::FORBIDDEN | StatusCode::SERVICE_UNAVAILABLE
        ));
        let value: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap()).unwrap();
        assert!(matches!(
            value["error"]["code"].as_str(),
            Some("custom_station_required" | "hosted_execution_not_verified")
        ));
    }
    assert!(!HOSTED_EXECUTION_ENABLED);
}

#[tokio::test]
async fn portal_preflight_is_exact_and_only_exposes_station_details() {
    let router = Router::new()
        .route("/agora-build/v1/details", get(|| async { "details" }))
        .route("/api/remote/v1/log", get(|| async { "log" }))
        .layer(crate::cors_layer_for(
            "https://custom.example",
            Some("https://portal.example"),
        ));
    for (path, origin, allowed) in [
        ("/agora-build/v1/details", "https://portal.example", true),
        ("/agora-build/v1/details", "https://evil.example", false),
        ("/api/remote/v1/log", "https://portal.example", false),
    ] {
        let response = router
            .clone()
            .oneshot(
                Request::builder()
                    .method("OPTIONS")
                    .uri(path)
                    .header("origin", origin)
                    .header("access-control-request-method", "GET")
                    .header("access-control-request-headers", "authorization")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response
                .headers()
                .get("access-control-allow-origin")
                .is_some(),
            allowed
        );
        if allowed {
            assert_eq!(response.headers()["access-control-allow-origin"], origin);
        }
    }
}

async fn service(
    runtime: &crate::station_integrations::StationIntegrations,
    f: &Fixture,
) -> (ServiceKeyContext, String) {
    let draft = runtime.prepare(ID, OWNER, request(f)).await.unwrap();
    let body = serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap();
    let entry = Entry::parse_bytes(
        SignedObject::sign(&f.keys, &KeyId::new("manager"), body)
            .unwrap()
            .to_json()
            .to_string()
            .as_bytes(),
    )
    .unwrap();
    assert_eq!(
        runtime
            .app
            .recovery
            .append_test_entry(
                &f.log.genesis_hash().to_hex(),
                PRINCIPAL,
                entry,
                f.log.head()
            )
            .await,
        StatusCode::OK
    );
    let previous = runtime.policies.load(&runtime.binding).await.unwrap();
    let mut next = previous.clone();
    next.revision += 1;
    let policy = next.integrations.get_mut(ID).unwrap();
    policy.state = "ready".into();
    policy.r9_svc = Some(draft["fingerprint"].as_str().unwrap().into());
    runtime.policies.commit(&previous, &next).await.unwrap();
    (
        ServiceKeyContext {
            issuer: runtime.binding.issuer.clone(),
            owner: OWNER.into(),
            station_origin: runtime.binding.station_origin.clone(),
            integration_id: ID.into(),
            genesis: f.log.genesis_hash().to_hex(),
            service_id: format!("svc-{ID}"),
        },
        draft["fingerprint"].as_str().unwrap().into(),
    )
}

/// Controlled host uses the shared crypto and principal verifier. This tests
/// the Station adapter, not the released Atem host or real-agent behavior.
async fn controlled_host(base: String, f: Arc<Fixture>, log: atem_client::membership::Membership) {
    controlled_host_attachments(base, f, log, 1).await;
}

async fn controlled_host_attachments(
    base: String,
    f: Arc<Fixture>,
    log: atem_client::membership::Membership,
    attachments: usize,
) {
    controlled_host_scenario(base, f, log, attachments, HostScenario::default()).await;
}

#[derive(Default)]
struct HostScenario {
    busy_initializations: usize,
    pending_approval: bool,
    lose_submit_reply: bool,
    handles: Option<tokio::sync::mpsc::UnboundedSender<String>>,
}

async fn controlled_host_scenario(
    base: String,
    f: Arc<Fixture>,
    log: atem_client::membership::Membership,
    attachments: usize,
    scenario: HostScenario,
) {
    let mut socket = connect_atem(&base, "phone", "host-a").await;
    crate::remote_api::host_route_tests::prove(&mut socket, &f.keys, &f.host_key, &log, "host-a")
        .await;
    let mut receipts = std::collections::BTreeMap::new();
    let approval_created_at = chrono::Utc::now().timestamp_millis() as u64;
    for attachment in 0..attachments {
        let open = loop {
            let event = next_client_json(&mut socket).await;
            if event["event"] != "close" {
                break event;
            }
        };
        assert_eq!(open["event"], "open");
        let handle = open["channel"].as_str().unwrap().to_owned();
        if let Some(handles) = &scenario.handles {
            handles.send(handle.clone()).unwrap();
        }
        let init = next_client_json(&mut socket).await;
        if attachment < scenario.busy_initializations {
            let reply = atem_client::channel::responder::InitLimiter::busy()
                .reply
                .unwrap();
            send_json(
                &mut socket,
                json!({"type":"channel","event":"frame","channel":handle,
                "frame":serde_json::from_slice::<Value>(&reply).unwrap()}),
            )
            .await;
            if attachment + 1 == attachments {
                assert_eq!(next_client_json(&mut socket).await["event"], "close");
            }
            continue;
        }
        let clock = atem_client::membership::HostNow {
            wall_ms: chrono::Utc::now().timestamp_millis() as u64,
            mono_ms: 0,
            boot_id: "controlled-host".into(),
        };
        let (waiting, accept) = {
            let ctx = HostContext {
                log: &log,
                host_id: "host-a",
                host_trust_gen: 1,
                provider: &f.keys,
                key: &f.host_key,
            };
            Responder::on_init(&ctx, &serde_json::to_vec(&init["frame"]).unwrap(), 0).unwrap()
        };
        send_json(&mut socket, json!({"type":"channel","event":"frame","channel":handle,"frame":serde_json::from_slice::<Value>(&accept).unwrap()})).await;
        let finish = next_client_json(&mut socket).await;
        let opened = waiting
            .on_finish(&serde_json::to_vec(&finish["frame"]).unwrap(), 0)
            .unwrap();
        let hello = Hello::parse(opened.hello()).unwrap();
        assert_eq!(hello.revision, Some(9));
        assert_eq!(
            hello.proof.principal,
            atem_client::channel::Principal::Service {
                device_id: format!("svc-{ID}")
            }
        );
        let member = &log.member(&format!("svc-{ID}")).unwrap().member;
        let authority =
            Authority::of_member(&hello.proof.principal, member, "host-a", clock.wall_ms).unwrap();
        let mut channel = opened
            .key(&hello.proof)
            .admit(&authority.key, authority.channel_deadline_ms(&clock))
            .unwrap();
        let runtime_gen = new_id();
        let welcome = Welcome {
            id: new_id(),
            re: hello.id,
            account_id: log.account_id().into(),
            atem_device_id: "host-a".into(),
            host_trust_gen: 1,
            runtime_gen: runtime_gen.clone(),
            controller_session: new_id(),
            attachment_gen: new_id(),
            client_kind: authority.client_kind,
            permissions: authority.permissions.iter().copied().collect(),
            authorization_ms_left: 60_000,
            server_time: clock.wall_ms,
            revision: 9,
            features: KNOWN_FEATURES
                .iter()
                .chain(R9_FEATURES)
                .map(|s| s.to_string())
                .collect(),
            principal: authority.name(),
            scope: authority.scope,
            head: log.head(),
            pending_recovery: vec![],
            channel_id: channel.channel_id().into(),
        };
        let bytes = channel.seal(&welcome.to_bytes(), 0).unwrap();
        send_json(&mut socket, json!({"type":"channel","event":"frame","channel":handle,"frame":serde_json::from_slice::<Value>(&bytes).unwrap()})).await;
        let list = next_client_json(&mut socket).await;
        let plain: Value = serde_json::from_slice(
            &channel
                .open(&serde_json::to_vec(&list["frame"]).unwrap(), 0)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(plain["data"]["op"], "list");
        let sessions = json!({"type":"session","data":{"v":1,"op":"sessions","id":new_id(),"re":plain["data"]["id"],
        "runtime_gen":runtime_gen,"runtime_epoch":1,"seq":1,"sessions":[{"session_id":"ses-aaaaaaaaaaaa","process_gen":"11111111-1111-4111-8111-111111111111", "provider":"claude","cwd_label":"example","state":"running","activity":"ready","activity_since":0,"controller":null,"capabilities":["chat"],"created_at":0}]}});
        atem_client::session::wire::decode(&serde_json::to_vec(&sessions).unwrap()).unwrap();
        let bytes = channel
            .seal(&serde_json::to_vec(&sessions).unwrap(), 0)
            .unwrap();
        send_json(&mut socket, json!({"type":"channel","event":"frame","channel":handle,"frame":serde_json::from_slice::<Value>(&bytes).unwrap()})).await;
        if scenario.pending_approval {
            let approval = json!({"type":"session","data":{"v":1,"op":"approval_request","id":new_id(),
                "approval_id":"88888888-8888-4888-8888-888888888888","session_id":"ses-aaaaaaaaaaaa",
                "process_gen":"11111111-1111-4111-8111-111111111111","tool":"Bash","summary":"touch /test/probe",
                "created_at":approval_created_at,"always_rules":[{"rule_id":"offered-rule","label":"Only this test command","scope":"session"}]}});
            let rules = json!({"type":"session","data":{"v":1,"op":"approval_rules","id":new_id(),
                "session_id":"ses-aaaaaaaaaaaa","process_gen":"11111111-1111-4111-8111-111111111111",
                "rules":[{"rule_id":"active-rule","label":"Previously approved command","scope":"session"}]}});
            let mut previous_rules = rules.clone();
            previous_rules["data"]["id"] = json!(new_id());
            previous_rules["data"]["rules"][0]["rule_id"] = json!("superseded-rule");
            for item in [approval, previous_rules, rules] {
                let bytes = channel
                    .seal(&serde_json::to_vec(&item).unwrap(), 0)
                    .unwrap();
                send_json(&mut socket,json!({"type":"channel","event":"frame","channel":handle,"frame":serde_json::from_slice::<Value>(&bytes).unwrap()})).await;
            }
        }
        loop {
            let frame = next_client_json(&mut socket).await;
            if frame["event"] == "close" {
                break;
            }
            let plain: Value = serde_json::from_slice(
                &channel
                    .open(&serde_json::to_vec(&frame["frame"]).unwrap(), 0)
                    .unwrap(),
            )
            .unwrap();
            let data = &plain["data"];
            let reply = match data["op"].as_str().unwrap() {
                "open" => {
                    let chat = |op: &str, sequence: u64| {
                        json!({"type":"agentChat","data":{"v":1,"op":op,
                    "conversationId":data["conversationId"],"agentId":data["agentId"],
                    "generation":"22222222-2222-4222-8222-222222222222","sequence":sequence}})
                    };
                    let opened = chat("opened", 0);
                    let mut message = chat("message", 1);
                    message["data"]["messageId"] = json!("m1");
                    message["data"]["role"] = json!("assistant");
                    message["data"]["history"] = json!(true);
                    message["data"]["parts"] = json!([{"id":"p1","kind":"text","markdown":"**Ready**\n\n[Project](https://example.test)"}]);
                    for item in [opened, message] {
                        let bytes = channel
                            .seal(&serde_json::to_vec(&item).unwrap(), 0)
                            .unwrap();
                        send_json(&mut socket,json!({"type":"channel","event":"frame","channel":handle,"frame":serde_json::from_slice::<Value>(&bytes).unwrap()})).await;
                    }
                    let mut end = chat("history_end", 2);
                    end["data"]["page"] = json!({"selector":"newest","count":1,"end":true,"coverage":"complete","truncated":false,"holes":[]});
                    end
                }
                "submit" => {
                    if data["kind"] == "prompt" {
                        assert_eq!(data["acquire"], true);
                    } else {
                        assert!(
                            data.get("acquire").is_none(),
                            "approval/rule submissions are lease-free"
                        );
                    }
                    let receipt = json!({"request_id":data["request_id"],"target":data["binding"]["target"],
                    "kind":data["kind"],"state":"accepted","updated_at":clock.wall_ms});
                    assert!(
                        receipts
                            .insert(
                                data["request_id"].as_str().unwrap().to_owned(),
                                receipt.clone(),
                            )
                            .is_none(),
                        "the adapter must not replay a submitted mutation"
                    );
                    if scenario.lose_submit_reply {
                        send_json(&mut socket, json!({"type":"channel","event":"close","channel":handle,"reason":"closed"})).await;
                        break;
                    }
                    let mut message = receipt;
                    message["v"] = json!(1);
                    message["op"] = json!("receipt");
                    message["id"] = json!(new_id());
                    message["re"] = data["id"].clone();
                    json!({"type":"session","data":message})
                }
                "receipt_query" => {
                    json!({"type":"session","data":{"v":1,"op":"receipts","id":new_id(),"re":data["id"],
                "receipts":data["request_ids"].as_array().unwrap().iter().filter_map(|v|receipts.get(v.as_str().unwrap()).cloned()).collect::<Vec<_>>()}})
                }
                other => panic!("unexpected controlled-host request: {other}"),
            };
            if reply["type"] == "session" {
                atem_client::session::wire::decode(&serde_json::to_vec(&reply).unwrap()).unwrap();
            }
            let bytes = channel
                .seal(&serde_json::to_vec(&reply).unwrap(), 0)
                .unwrap();
            send_json(&mut socket, json!({"type":"channel","event":"frame","channel":handle,"frame":serde_json::from_slice::<Value>(&bytes).unwrap()})).await;
        }
    }
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_host_init_busy_has_bounded_pre_authentication_retries() {
    use std::time::{Duration, Instant};
    for refused in [1, 4] {
        let (db, runtime, f) = fixture().await;
        let (context, fingerprint) = service(&runtime, &f).await;
        let log = runtime
            .app
            .recovery
            .integration_log(&context.genesis, PRINCIPAL)
            .await
            .unwrap();
        let mut app = runtime.app.clone();
        app.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
            app.knowledge.clone(),
            app.vault.clone(),
            Arc::new(crate::remote_api::recovery::tests::TestAccountVerifier),
        ));
        let (base, relay) = spawn_relay(app).await;
        let host = tokio::spawn(controlled_host_scenario(
            base,
            Arc::new(f),
            log,
            if refused == 1 { 2 } else { 4 },
            HostScenario {
                busy_initializations: refused,
                ..Default::default()
            },
        ));
        tokio::time::timeout(Duration::from_secs(3), async {
            while !crate::remote_api::recovery::host_target(
                &runtime.app,
                &context.genesis,
                PRINCIPAL,
                "host-a",
            )
            .await
            .is_ok_and(|(_, _, proof, _)| proof.is_some())
            {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let start = Instant::now();
        let result = tokio::time::timeout(
            Duration::from_secs(8),
            client::HostedConnection::open(&runtime, &context, &fingerprint, "host-a"),
        )
        .await
        .expect("busy retries must be bounded");
        assert!(start.elapsed() >= Duration::from_secs(1));
        if refused == 1 {
            let connection = result.unwrap();
            assert!(connection.attached.target("ses-aaaaaaaaaaaa").is_some());
            drop(connection);
        } else {
            let response = result.err().expect("four busy handshakes must stop");
            assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
            assert_eq!(response.headers()["retry-after"], "1");
            let body: Value =
                serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap())
                    .unwrap();
            assert_eq!(body["error"]["code"], "host_connection_busy");
        }
        host.await.unwrap();
        relay.abort();
        drop(runtime);
        db.cleanup().await;
    }
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_registry_includes_approval_catchup_after_snapshot() {
    let (db, runtime, f) = fixture().await;
    let (context, fingerprint) = service(&runtime, &f).await;
    let log = runtime
        .app
        .recovery
        .integration_log(&context.genesis, PRINCIPAL)
        .await
        .unwrap();
    let mut app = runtime.app.clone();
    app.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        app.knowledge.clone(),
        app.vault.clone(),
        Arc::new(crate::remote_api::recovery::tests::TestAccountVerifier),
    ));
    let (base, server) = spawn_relay(app).await;
    let host = tokio::spawn(controlled_host_scenario(
        base,
        Arc::new(f),
        log,
        1,
        HostScenario {
            pending_approval: true,
            ..Default::default()
        },
    ));
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while !crate::remote_api::recovery::host_target(
            &runtime.app,
            &context.genesis,
            PRINCIPAL,
            "host-a",
        )
        .await
        .is_ok_and(|(_, _, binding, _)| binding.is_some())
        {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let connection = client::HostedConnection::open(&runtime, &context, &fingerprint, "host-a")
        .await
        .unwrap();
    assert_eq!(
        connection.attached.registry().pending_approvals().count(),
        1
    );
    assert_eq!(
        connection
            .attached
            .registry()
            .pending_approvals()
            .next()
            .unwrap()
            .approval_id,
        "88888888-8888-4888-8888-888888888888"
    );
    assert_eq!(connection.initial_rules.len(), 1);
    assert_eq!(
        connection.initial_rules[0]["rules"][0]["rule_id"],
        "active-rule"
    );
    drop(connection);
    host.await.unwrap();
    server.abort();
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_service_registry_without_mac_and_membership_policy_fences() {
    let (db, runtime, f) = fixture().await;
    let (context, fingerprint) = service(&runtime, &f).await;
    let log = runtime
        .app
        .recovery
        .integration_log(&context.genesis, PRINCIPAL)
        .await
        .unwrap();
    let mut app = runtime.app.clone();
    app.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        app.knowledge.clone(),
        app.vault.clone(),
        Arc::new(crate::remote_api::recovery::tests::TestAccountVerifier),
    ));
    let (base, server) = spawn_relay(app).await;
    let f = Arc::new(f);
    let host = tokio::spawn(controlled_host(base, f.clone(), log));
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while !crate::remote_api::recovery::host_target(
            &runtime.app,
            &context.genesis,
            PRINCIPAL,
            "host-a",
        )
        .await
        .is_ok_and(|(_, _, binding, _)| binding.is_some())
        {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let mut connection = client::HostedConnection::open(&runtime, &context, &fingerprint, "host-a")
        .await
        .unwrap();
    assert_eq!(connection.attached.registry().sessions().count(), 1);
    assert_eq!(
        connection
            .attached
            .target("ses-aaaaaaaaaaaa")
            .unwrap()
            .account_id,
        "account-test"
    );
    let admission = admission::Admission {
        token: VerifiedServiceToken {
            identity: VerifiedIdentity {
                issuer: runtime.binding.issuer.clone(),
                subject: OWNER.into(),
                authenticated_at: None,
            },
            client_id: ID.into(),
            service_fingerprint: fingerprint,
            scopes: vec!["agent.view".into()],
            expires_at: chrono::Utc::now().timestamp() + 60,
        },
        context,
        operation: "agent.view",
    };
    connection.recheck(&runtime, &admission).await.unwrap();
    let target = connection.attached.target("ses-aaaaaaaaaaaa").unwrap();
    let prompt_id = new_id();
    for (operation, fields) in [
        (
            operations::Operation::Prompt,
            json!({"request_id":prompt_id,"text":"**Hello** https://example.test"}),
        ),
        (
            operations::Operation::Receipts,
            json!({"request_ids":[prompt_id]}),
        ),
        (
            operations::Operation::Approval,
            json!({"request_id":new_id(),"approval":{"approval_id":new_id(),"decision":"allow_always","rule_id":"session-rule"}}),
        ),
        (
            operations::Operation::Revoke,
            json!({"request_id":new_id(),"rule_id":"session-rule"}),
        ),
        (operations::Operation::History, json!({})),
    ] {
        let mut value = fields;
        value["target"] = serde_json::to_value(&target).unwrap();
        let call = serde_json::from_value(value).unwrap();
        let events = operations::perform(&mut connection, &call, operation, &runtime, &admission)
            .await
            .unwrap();
        assert!(!events.is_empty());
        if matches!(operation, operations::Operation::History) {
            assert!(events.iter().any(|e| e["data"]["parts"][0]["markdown"]
                == "**Ready**\n\n[Project](https://example.test)"));
            assert!(events
                .iter()
                .any(|e| e["data"]["page"]["coverage"] == "complete"));
        }
    }
    // Even a same-key renewal must fence the old channel before another effect.
    let current = runtime
        .app
        .recovery
        .integration_log(&admission.context.genesis, PRINCIPAL)
        .await
        .unwrap();
    let expiry = atem_client::membership::service_grant(&current, &admission.context.service_id)
        .unwrap()
        .1;
    let body = current.draft(
        "phone",
        chrono::Utc::now().timestamp_millis() as u64,
        &atem_client::membership::service_renewal(
            &current,
            &admission.context.service_id,
            expiry + 3_600_000,
            chrono::Utc::now().timestamp_millis() as u64,
        )
        .unwrap(),
    );
    let entry = Entry::parse_bytes(
        SignedObject::sign(&f.keys, &KeyId::new("manager"), body)
            .unwrap()
            .to_json()
            .to_string()
            .as_bytes(),
    )
    .unwrap();
    assert_eq!(
        runtime
            .app
            .recovery
            .append_test_entry(&admission.context.genesis, PRINCIPAL, entry, current.head())
            .await,
        StatusCode::OK
    );
    assert!(connection.recheck(&runtime, &admission).await.is_err());
    runtime.policies.deny(&runtime.binding).await.unwrap();
    assert!(connection.recheck(&runtime, &admission).await.is_err());
    drop(connection);
    host.await.unwrap();
    server.abort();
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_event_socket_keeps_rich_messages_and_closes_on_policy_denial() {
    use axum::{extract::WebSocketUpgrade, response::IntoResponse};
    let (db, runtime, f) = fixture().await;
    let (context, fingerprint) = service(&runtime, &f).await;
    let log = runtime
        .app
        .recovery
        .integration_log(&context.genesis, PRINCIPAL)
        .await
        .unwrap();
    let mut app = runtime.app.clone();
    app.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        app.knowledge.clone(),
        app.vault.clone(),
        Arc::new(crate::remote_api::recovery::tests::TestAccountVerifier),
    ));
    let (base, relay) = spawn_relay(app).await;
    let host = tokio::spawn(controlled_host(base, Arc::new(f), log));
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while !crate::remote_api::recovery::host_target(
            &runtime.app,
            &context.genesis,
            PRINCIPAL,
            "host-a",
        )
        .await
        .is_ok_and(|(_, _, binding, _)| binding.is_some())
        {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    // Test-only attachment route isolates the event adapter; production Auth
    // and its closed admission gate are covered separately, not bypassed live.
    let api = Router::new().route(
        "/events",
        get({
            let runtime = runtime.clone();
            move |upgrade: WebSocketUpgrade| {
                let runtime = runtime.clone();
                let context = context.clone();
                let fingerprint = fingerprint.clone();
                async move {
                    let connection =
                        client::HostedConnection::open(&runtime, &context, &fingerprint, "host-a")
                            .await
                            .unwrap();
                    let admission = admission::Admission {
                        token: VerifiedServiceToken {
                            identity: VerifiedIdentity {
                                issuer: runtime.binding.issuer.clone(),
                                subject: OWNER.into(),
                                authenticated_at: None,
                            },
                            client_id: ID.into(),
                            service_fingerprint: fingerprint,
                            scopes: vec!["agent.view".into()],
                            expires_at: chrono::Utc::now().timestamp() + 60,
                        },
                        context,
                        operation: "agent.view",
                    };
                    let permit = runtime.requests.clone().try_acquire_owned().unwrap();
                    upgrade
                        .on_upgrade(move |socket| {
                            operations::event_socket(socket, runtime, admission, connection, permit)
                        })
                        .into_response()
                }
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = listener.local_addr().unwrap();
    let api = tokio::spawn(async move {
        axum::serve(listener, api).await.unwrap();
    });
    let mut socket = tokio_tungstenite::connect_async(format!("ws://{origin}/events"))
        .await
        .unwrap()
        .0;
    let snapshot = next_client_json(&mut socket).await;
    assert_eq!(snapshot["type"], "snapshot");
    send_json(&mut socket, json!({"target":snapshot["targets"][0]})).await;
    assert_eq!(next_client_json(&mut socket).await["data"]["op"], "opened");
    assert_eq!(
        next_client_json(&mut socket).await["data"]["parts"][0]["markdown"],
        "**Ready**\n\n[Project](https://example.test)"
    );
    assert_eq!(
        next_client_json(&mut socket).await["data"]["op"],
        "history_end"
    );
    runtime.policies.deny(&runtime.binding).await.unwrap();
    use futures_util::StreamExt;
    let closed = tokio::time::timeout(std::time::Duration::from_secs(3), socket.next())
        .await
        .unwrap();
    assert!(matches!(
        closed,
        Some(Ok(tokio_tungstenite::tungstenite::Message::Close(_))) | None
    ));
    host.await.unwrap();
    api.abort();
    relay.abort();
    drop(runtime);
    db.cleanup().await;
}

async fn http_json(response: reqwest::Response, status: StatusCode) -> Value {
    assert_eq!(response.status(), status);
    response.json().await.unwrap()
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_dispatch_failure_preserves_mutation_recovery_without_replaying() {
    let (db, runtime, f) = fixture().await;
    let (context, fingerprint) = service(&runtime, &f).await;
    let log = runtime
        .app
        .recovery
        .integration_log(&context.genesis, PRINCIPAL)
        .await
        .unwrap();
    let mut app = runtime.app.clone();
    app.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        app.knowledge.clone(),
        app.vault.clone(),
        Arc::new(crate::remote_api::recovery::tests::TestAccountVerifier),
    ));
    let (base, relay) = spawn_relay(app).await;
    let (handles, mut incoming_handles) = tokio::sync::mpsc::unbounded_channel();
    let host = tokio::spawn(controlled_host_scenario(
        base,
        Arc::new(f),
        log,
        4,
        HostScenario {
            handles: Some(handles),
            ..Default::default()
        },
    ));
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(3);
    let route = loop {
        if let Ok((_, route, Some(_), _)) = crate::remote_api::recovery::host_target(
            &runtime.app,
            &context.genesis,
            PRINCIPAL,
            "host-a",
        )
        .await
        {
            break route;
        }
        assert!(tokio::time::Instant::now() < deadline);
        tokio::task::yield_now().await;
    };
    for (operation, fields, scope) in [
        (
            operations::Operation::Prompt,
            json!({"request_id":new_id(),"text":"private test prompt"}),
            "agent.prompt",
        ),
        (
            operations::Operation::Approval,
            json!({"request_id":new_id(),"approval":{"approval_id":new_id(),"decision":"deny","message":"private test answer"}}),
            "agent.approve",
        ),
        (
            operations::Operation::Revoke,
            json!({"request_id":new_id(),"rule_id":"offered-rule"}),
            "agent.approve",
        ),
        (
            operations::Operation::Receipts,
            json!({"request_ids":[new_id()]}),
            "agent.view",
        ),
    ] {
        let mut connection =
            client::HostedConnection::open(&runtime, &context, &fingerprint, "host-a")
                .await
                .unwrap();
        let handle = incoming_handles.recv().await.unwrap();
        let target = json!(connection.attached.target("ses-aaaaaaaaaaaa").unwrap());
        let mut body = fields.clone();
        body["target"] = target.clone();
        let call = serde_json::from_value(body).unwrap();
        let admission = admission::Admission {
            token: VerifiedServiceToken {
                identity: VerifiedIdentity {
                    issuer: runtime.binding.issuer.clone(),
                    subject: OWNER.into(),
                    authenticated_at: None,
                },
                client_id: ID.into(),
                service_fingerprint: fingerprint.clone(),
                scopes: vec![scope.into()],
                expires_at: chrono::Utc::now().timestamp() + 60,
            },
            context: context.clone(),
            operation: scope,
        };
        // A malformed carrier envelope synchronously closes the real transport
        // before dispatch; the fake host must see no submit or receipt query.
        assert!(!runtime
            .app
            .relay
            .channels()
            .reply(&handle, &route, "invalid envelope"));
        let response = operations::perform(&mut connection, &call, operation, &runtime, &admission)
            .await
            .unwrap_err();
        let readonly = matches!(operation, operations::Operation::Receipts);
        assert_eq!(
            response.status(),
            if readonly {
                StatusCode::SERVICE_UNAVAILABLE
            } else {
                StatusCode::GATEWAY_TIMEOUT
            }
        );
        let result: Value =
            serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap()).unwrap();
        if readonly {
            assert_eq!(result["error"]["code"], "host_connection_lost");
            assert!(result.get("recovery").is_none());
        } else {
            assert_eq!(
                result,
                json!({"error":{"code":"delivery_uncertain"},"request_id":fields["request_id"],"target":target,"recovery":"query_receipts"})
            );
        }
    }
    tokio::time::timeout(std::time::Duration::from_secs(3), host)
        .await
        .unwrap()
        .unwrap();
    relay.abort();
    let _ = relay.await;
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_http_lost_mutation_replies_recover_on_new_attachments_without_replay() {
    use crate::{
        account_identity::tests::Fixture as AuthFixture,
        station_integrations::tests::fixture_with_issuer,
    };
    let auth = AuthFixture::new().await;
    let (db, runtime, f) = fixture_with_issuer(&auth.issuer).await;
    let (context, fingerprint) = service(&runtime, &f).await;
    let log = runtime
        .app
        .recovery
        .integration_log(&context.genesis, PRINCIPAL)
        .await
        .unwrap();
    let mut app = runtime.app.clone();
    app.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        app.knowledge.clone(),
        app.vault.clone(),
        Arc::new(crate::remote_api::recovery::tests::TestAccountVerifier),
    ));
    let (base, relay) = spawn_relay(app).await;
    let host = tokio::spawn(controlled_host_scenario(
        base,
        Arc::new(f),
        log,
        7,
        HostScenario {
            lose_submit_reply: true,
            ..Default::default()
        },
    ));
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while !crate::remote_api::recovery::host_target(
            &runtime.app,
            &context.genesis,
            PRINCIPAL,
            "host-a",
        )
        .await
        .is_ok_and(|(_, _, binding, _)| binding.is_some())
        {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let router = operation_routes().with_state(crate::station_integrations::IntegrationState(
        Some(runtime.clone()),
    ));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let api = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap();
    let prefix = format!("{origin}/api/agent/v1/integrations/{ID}/hosts/host-a");
    let mut claims = auth.claims();
    claims["aud"] = json!(runtime.binding.station_origin);
    claims["client_id"] = json!(ID);
    claims["r9_svc"] = json!(fingerprint);
    claims["scope"] = json!("agent.view agent.prompt agent.approve");
    claims["exp"] = json!(chrono::Utc::now().timestamp() + 300);
    let token = auth.token(auth.header(), claims);
    let snapshot = http_json(
        http.get(format!("{prefix}/sessions"))
            .bearer_auth(&token)
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
    )
    .await;
    let target = &snapshot["targets"][0];
    let session_url = format!("{prefix}/sessions/ses-aaaaaaaaaaaa");
    for (suffix, fields, kind) in [
        (
            "prompts",
            json!({"text":"**One submission only**"}),
            "prompt",
        ),
        (
            "approvals",
            json!({"approval":{"approval_id":new_id(),"decision":"deny","message":"Do not run"}}),
            "approval",
        ),
        (
            "rules/revoke",
            json!({"rule_id":"offered-rule"}),
            "approval_rule_revoke",
        ),
    ] {
        let request = new_id();
        let mut body = fields;
        body["target"] = target.clone();
        body["request_id"] = json!(request);
        let uncertain = http_json(
            http.post(format!("{session_url}/{suffix}"))
                .bearer_auth(&token)
                .json(&body)
                .send()
                .await
                .unwrap(),
            StatusCode::GATEWAY_TIMEOUT,
        )
        .await;
        assert_eq!(
            uncertain,
            json!({"error":{"code":"delivery_uncertain"},"request_id":request,"target":target,"recovery":"query_receipts"})
        );
        let recovered = http_json(
            http.post(format!("{session_url}/receipts"))
                .bearer_auth(&token)
                .json(&json!({"target":target,"request_ids":[request]}))
                .send()
                .await
                .unwrap(),
            StatusCode::OK,
        )
        .await;
        let receipts: Vec<_> = recovered["events"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|e| e["data"]["receipts"].as_array().into_iter().flatten())
            .collect();
        assert_eq!(receipts.len(), 1);
        assert_eq!(receipts[0]["request_id"], request);
        assert_eq!(receipts[0]["target"], *target);
        assert_eq!(receipts[0]["kind"], kind);
        assert_eq!(receipts[0]["state"], "accepted");
    }
    tokio::time::timeout(std::time::Duration::from_secs(3), host)
        .await
        .unwrap()
        .unwrap();
    assert!(!HOSTED_EXECUTION_ENABLED);
    api.abort();
    let _ = api.await;
    relay.abort();
    let _ = relay.await;
    drop(runtime);
    db.cleanup().await;
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_http_api_authentication_operations_reconnect_and_revocation_without_app() {
    use crate::{
        account_identity::tests::Fixture as AuthFixture,
        station_integrations::tests::fixture_with_issuer,
    };
    let auth = AuthFixture::new().await;
    let (db, runtime, f) = fixture_with_issuer(&auth.issuer).await;
    let (context, fingerprint) = service(&runtime, &f).await;
    let log = runtime
        .app
        .recovery
        .integration_log(&context.genesis, PRINCIPAL)
        .await
        .unwrap();
    let mut app = runtime.app.clone();
    app.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        app.knowledge.clone(),
        app.vault.clone(),
        Arc::new(crate::remote_api::recovery::tests::TestAccountVerifier),
    ));
    let (base, relay) = spawn_relay(app).await;
    let host = tokio::spawn(controlled_host_scenario(
        base,
        Arc::new(f),
        log,
        9,
        HostScenario {
            pending_approval: true,
            ..Default::default()
        },
    ));
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while !crate::remote_api::recovery::host_target(
            &runtime.app,
            &context.genesis,
            PRINCIPAL,
            "host-a",
        )
        .await
        .is_ok_and(|(_, _, binding, _)| binding.is_some())
        {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();

    // Only this loopback test listener omits the release gate. Real JWT
    // verification, policy checks and encrypted R9 handlers still run.
    let router = operation_routes()
        .layer(axum::extract::DefaultBodyLimit::max(65_536))
        .with_state(crate::station_integrations::IntegrationState(Some(
            runtime.clone(),
        )));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let api = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap();
    let prefix = format!("{origin}/api/agent/v1/integrations/{ID}/hosts/host-a");
    let mut claims = auth.claims();
    claims["aud"] = json!(runtime.binding.station_origin);
    claims["client_id"] = json!(ID);
    claims["r9_svc"] = json!(fingerprint);
    claims["scope"] = json!("agent.view agent.prompt agent.approve");
    claims["exp"] = json!(chrono::Utc::now().timestamp() + 300);
    let token = auth.token(auth.header(), claims.clone());
    let sessions_url = format!("{prefix}/sessions");

    let response = http.get(&sessions_url).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(response.headers()["www-authenticate"], "Bearer");
    assert_eq!(response.headers()["cache-control"], "no-store");
    for (field, value, status) in [
        (
            "aud",
            json!("https://portal.example"),
            StatusCode::UNAUTHORIZED,
        ),
        (
            "iss",
            json!("https://other-issuer.example"),
            StatusCode::UNAUTHORIZED,
        ),
        (
            "sub",
            json!("ab99999999999999999999999999"),
            StatusCode::UNAUTHORIZED,
        ),
        (
            "client_id",
            json!("i-11234567890123456789012345"),
            StatusCode::UNAUTHORIZED,
        ),
        ("r9_svc", json!("0".repeat(64)), StatusCode::UNAUTHORIZED),
        ("client_id", json!("astation"), StatusCode::UNAUTHORIZED),
        ("scope", json!("agent.prompt"), StatusCode::FORBIDDEN),
        (
            "exp",
            json!(chrono::Utc::now().timestamp() - 120),
            StatusCode::UNAUTHORIZED,
        ),
    ] {
        let mut wrong = claims.clone();
        wrong[field] = value;
        let response = http
            .get(&sessions_url)
            .bearer_auth(auth.token(auth.header(), wrong))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), status, "claim {field}");
        assert_eq!(response.headers()["cache-control"], "no-store");
    }
    let response = http
        .get(&sessions_url)
        .bearer_auth(format!("{token}invalid"))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    let snapshot = http_json(
        http.get(&sessions_url)
            .bearer_auth(&token)
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
    )
    .await;
    assert_eq!(snapshot["sessions"][0]["session_id"], "ses-aaaaaaaaaaaa");
    assert_eq!(snapshot["approvals"].as_array().unwrap().len(), 1);
    assert_eq!(
        snapshot["approvals"][0]["approval_id"],
        "88888888-8888-4888-8888-888888888888"
    );
    assert_eq!(snapshot["approval_rules"].as_array().unwrap().len(), 1);
    assert_eq!(
        snapshot["approval_rules"][0]["rules"][0]["rule_id"],
        "active-rule"
    );
    let target = snapshot["targets"][0].clone();
    let session_url = format!("{prefix}/sessions/ses-aaaaaaaaaaaa");
    for (suffix, body, status) in [
        (
            "prompts",
            json!({"target":target,"request_id":new_id(),"text":"do not run","takeover":true}),
            StatusCode::BAD_REQUEST,
        ),
        (
            "approvals",
            json!({"target":target,"request_id":new_id(),"approval":{"approval_id":new_id(),"decision":"allow_once"},"take_control":true}),
            StatusCode::BAD_REQUEST,
        ),
        (
            "interrupt",
            json!({"target":target,"request_id":new_id()}),
            StatusCode::BAD_REQUEST,
        ),
        (
            "prompts",
            json!({"target":target,"request_id":new_id(),"text":"do not run","unrecognized":true}),
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        (
            "prompts",
            json!({"target":target,"request_id":new_id(),"text":"x".repeat(65_537)}),
            StatusCode::PAYLOAD_TOO_LARGE,
        ),
    ] {
        assert_eq!(
            http.post(format!("{session_url}/{suffix}"))
                .bearer_auth(&token)
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            status,
            "{suffix}"
        );
    }
    let prompt_id = new_id();
    for (suffix, body, expected_kind) in [
        (
            "prompts",
            json!({"target":target,"request_id":prompt_id,"text":"**Hello**\n\n[Project](https://example.test)"}),
            Some("prompt"),
        ),
        (
            "receipts",
            json!({"target":target,"request_ids":[prompt_id]}),
            None,
        ),
        (
            "approvals",
            json!({"target":target,"request_id":new_id(),"approval":{"approval_id":new_id(),"decision":"allow_always","rule_id":"session-rule"}}),
            Some("approval"),
        ),
        (
            "rules/revoke",
            json!({"target":target,"request_id":new_id(),"rule_id":"session-rule"}),
            Some("approval_rule_revoke"),
        ),
        ("history", json!({"target":target}), None),
    ] {
        let reply = http_json(
            http.post(format!("{session_url}/{suffix}"))
                .bearer_auth(&token)
                .json(&body)
                .send()
                .await
                .unwrap(),
            StatusCode::OK,
        )
        .await;
        let events = reply["events"].as_array().unwrap();
        if let Some(kind) = expected_kind {
            assert!(events.iter().any(|e| e["data"]["op"] == "receipt"
                && e["data"]["kind"] == kind
                && e["data"]["state"] == "accepted"
                && e["data"]["request_id"] == body["request_id"]));
        } else if suffix == "receipts" {
            assert!(events
                .iter()
                .any(|e| e["data"]["receipts"][0]["request_id"] == prompt_id));
        } else {
            assert!(events.iter().any(|e| e["data"]["parts"][0]["markdown"]
                == "**Ready**\n\n[Project](https://example.test)"));
            assert!(events
                .iter()
                .any(|e| e["data"]["page"]["coverage"] == "complete"));
        }
    }
    let approvals = http_json(
        http.get(format!("{session_url}/approvals"))
            .bearer_auth(&token)
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
    )
    .await;
    assert_eq!(approvals["target"], target);
    assert_eq!(approvals["approvals"], snapshot["approvals"]);
    assert_eq!(
        approvals["approval_rules"][0]["rules"],
        snapshot["approval_rules"][0]["rules"]
    );

    let mut stale_target = target.clone();
    stale_target["process_gen"] = json!(new_id());
    let stale = http_json(
        http.post(format!("{session_url}/prompts"))
            .bearer_auth(&token)
            .json(&json!({"target":stale_target,"request_id":new_id(),"text":"do not run"}))
            .send()
            .await
            .unwrap(),
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(stale["error"]["code"], "stale_target");

    use futures_util::StreamExt;
    use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};
    let socket_url = format!("{prefix}/events").replacen("http://", "ws://", 1);
    let unauthorized = tokio_tungstenite::connect_async(&socket_url)
        .await
        .unwrap_err();
    assert!(matches!(
        unauthorized,
        tokio_tungstenite::tungstenite::Error::Http(response)
            if response.status() == StatusCode::UNAUTHORIZED
    ));
    let mut socket_request = socket_url.into_client_request().unwrap();
    socket_request
        .headers_mut()
        .insert("authorization", format!("Bearer {token}").parse().unwrap());
    let mut socket = tokio_tungstenite::connect_async(socket_request)
        .await
        .unwrap()
        .0;
    let stream_snapshot = next_client_json(&mut socket).await;
    assert_eq!(stream_snapshot["type"], "snapshot");
    assert_eq!(stream_snapshot["approvals"], snapshot["approvals"]);
    assert_eq!(
        stream_snapshot["approval_rules"][0]["rules"],
        snapshot["approval_rules"][0]["rules"]
    );
    send_json(&mut socket, json!({"target":target})).await;
    assert_eq!(next_client_json(&mut socket).await["data"]["op"], "opened");
    assert_eq!(
        next_client_json(&mut socket).await["data"]["parts"][0]["markdown"],
        "**Ready**\n\n[Project](https://example.test)"
    );
    assert_eq!(
        next_client_json(&mut socket).await["data"]["op"],
        "history_end"
    );

    // Revocation must deny this still-valid token before opening another
    // attachment and close the authenticated update stream.
    runtime.policies.deny(&runtime.binding).await.unwrap();
    let closed = tokio::time::timeout(std::time::Duration::from_secs(3), socket.next())
        .await
        .unwrap();
    assert!(matches!(closed, Some(Ok(Message::Close(_))) | None));
    tokio::time::timeout(std::time::Duration::from_secs(3), host)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        http.get(&sessions_url)
            .bearer_auth(&token)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    assert!(!HOSTED_EXECUTION_ENABLED);
    api.abort();
    let _ = api.await;
    relay.abort();
    let _ = relay.await;
    drop(runtime);
    db.cleanup().await;
}
