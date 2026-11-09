use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use std::time::Duration;

pub(super) fn png() -> Vec<u8> {
    let small = STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=").unwrap();
    // A valid ancillary text chunk makes this exercise three encrypted upload chunks.
    let mut bytes = small[..small.len() - 12].to_vec();
    let data = [b"test\0".as_slice(), &vec![b'a'; 200_000]].concat();
    bytes.extend((data.len() as u32).to_be_bytes());
    let input = [b"tEXt".as_slice(), &data].concat();
    bytes.extend(&input);
    let mut crc = !0u32;
    for byte in input {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb88320u32 & (0u32.wrapping_sub(crc & 1)));
        }
    }
    bytes.extend((!crc).to_be_bytes());
    bytes.extend(&small[small.len() - 12..]);
    bytes
}

pub(super) fn call(png: &[u8]) -> Value {
    let now = chrono::Utc::now().timestamp_millis() as u64;
    json!({"target":{"account_id":"account-test","atem_device_id":"host-a","host_trust_gen":1,
        "session_id":"ses-aaaaaaaaaaaa","process_gen":"11111111-1111-4111-8111-111111111111"},
        "route_id":"ui","route_revision":1,"message_id":new_id(),"workflow_id":new_id(),"recipient_id":new_id(),
        "created_at":now,"expires_at":now+300_000,"mark":{"mark_id":"mark_test","url":"http://localhost:3000/",
            "title":"Test page","screenshot":{"attachment_id":new_id(),"digest":atem_client::session::host_work::digest(png),
                "size":png.len(),"media_type":"image/png"},"annotations":[{"tool":"arrow","text":"Make this red","x":1,"y":1}]},
        "png_base64":STANDARD.encode(png)})
}

#[tokio::test]
async fn marks_require_the_separate_host_work_gate() {
    let router = crate::hosted_agents::host_work::routes().with_state(IntegrationState(None));
    let response = router
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!(
                    "/api/agent/v1/integrations/{ID}/hosts/host-a/sessions/ses-aaaaaaaaaaaa/marks"
                ))
                .header("content-type", "application/json")
                .body(Body::from(call(&png()).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let bytes = axum::body::to_bytes(response.into_body(), 4096)
        .await
        .unwrap();
    let error: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        error["error"]["code"],
        if cfg!(feature = "host-work-api") {
            "host_connection_lost"
        } else {
            "host_work_not_verified"
        }
    );
}

#[tokio::test]
async fn mark_validation_rejects_changed_bytes_bounds_and_sender_fields() {
    let png = png();
    let valid = call(&png);
    let request: marks::MarkCall = serde_json::from_value(valid.clone()).unwrap();
    assert!(request.validate().is_ok());
    for (field, value) in [
        ("sender", json!("member:phone")),
        ("png_base64", json!(STANDARD.encode(b"not png"))),
        ("expires_at", json!(1)),
        ("route_revision", json!(0)),
    ] {
        let mut bad = valid.clone();
        bad[field] = value;
        assert!(
            serde_json::from_value::<marks::MarkCall>(bad).map_or(true, |r| r.validate().is_err()),
            "{field}"
        );
    }
    let mut bad = valid;
    bad["mark"]["screenshot"]["digest"] = json!("0".repeat(64));
    assert!(serde_json::from_value::<marks::MarkCall>(bad)
        .unwrap()
        .validate()
        .is_err());
}

#[tokio::test]
#[cfg(feature = "host-work-api")]
#[ignore = "requires isolated Postgres; optional CHISEL_MARK_TEST_SCRIPT runs the real Node sender"]
async fn postgres_online_marks_authenticated_stream_integrity_and_failures() {
    for mode in [
        "success",
        "stale",
        "old_grant",
        "policy",
        "disconnect",
        "heartbeat",
        "lost_reply",
        "chisel",
    ] {
        let script = std::env::var("CHISEL_MARK_TEST_SCRIPT").ok();
        if mode == "chisel" && script.is_none() {
            continue;
        }
        let auth = crate::account_identity::tests::Fixture::new().await;
        let (db, runtime, f) =
            crate::station_integrations::tests::fixture_with_issuer(&auth.issuer).await;
        let (context, fingerprint) = service_for_marks(&runtime, &f, mode != "old_grant").await;
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
        let png = png();
        let host = tokio::spawn(controlled_host_scenario(
            base,
            Arc::new(f),
            log,
            if mode == "chisel" { 2 } else { 1 },
            HostScenario {
                mark_png: Some(png.clone()),
                mark_hold: matches!(mode, "policy" | "disconnect" | "heartbeat"),
                mark_drop_publish: mode == "lost_reply",
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
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let router = http_test_routes().with_state(IntegrationState(Some(runtime.clone())));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let api = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        let mut claims = auth.claims();
        claims["aud"] = json!(runtime.binding.station_origin);
        claims["client_id"] = json!(ID);
        claims["r9_svc"] = json!(fingerprint);
        claims["scope"] = json!("agent.view agent.prompt");
        claims["exp"] = json!(chrono::Utc::now().timestamp() + 300);
        let token = auth.token(auth.header(), claims);
        if mode == "chisel" {
            let png_file = std::env::temp_dir().join(format!("chisel-mark-test-{}.png", new_id()));
            tokio::fs::write(&png_file, &png).await.unwrap();
            let mut child = tokio::process::Command::new(
                std::env::var("CHISEL_NODE").unwrap_or_else(|_| "node".into()),
            );
            let output = tokio::time::timeout(
                Duration::from_secs(20),
                child
                    .arg(script.unwrap())
                    .env("CHISEL_TEST_ORIGIN", &origin)
                    .env("CHISEL_TEST_TOKEN", &token)
                    .env("CHISEL_TEST_PNG_FILE", &png_file)
                    .kill_on_drop(true)
                    .output(),
            )
            .await
            .unwrap()
            .unwrap();
            tokio::fs::remove_file(png_file).await.unwrap();
            assert!(
                output.status.success(),
                "Node sender failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(String::from_utf8_lossy(&output.stdout).contains("CHISEL_ONLINE_MARK_PASS"));
        } else {
            let http = reqwest::Client::builder()
                .timeout(Duration::from_secs(15))
                .build()
                .unwrap();
            let url = format!("{origin}/api/agent/v1/integrations/{ID}/hosts/host-a/sessions/ses-aaaaaaaaaaaa/marks");
            let mut call = call(&png);
            let unauthorized = http.post(&url).json(&call).send().await.unwrap();
            assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);
            if mode == "stale" {
                call["target"]["process_gen"] = json!(new_id());
            }
            let mut response = http
                .post(&url)
                .bearer_auth(&token)
                .json(&call)
                .send()
                .await
                .unwrap();
            if matches!(mode, "stale" | "old_grant") {
                let status = if mode == "stale" {
                    StatusCode::CONFLICT
                } else {
                    StatusCode::FORBIDDEN
                };
                assert_eq!(response.status(), status);
                assert_eq!(
                    response.json::<Value>().await.unwrap()["error"]["code"],
                    if mode == "stale" {
                        "stale_target"
                    } else {
                        "mark_grant_required"
                    }
                );
            } else {
                assert_eq!(response.status(), StatusCode::OK);
                assert_eq!(response.headers()["content-type"], "application/x-ndjson");
                let mut text = String::new();
                if matches!(mode, "policy" | "disconnect" | "heartbeat") {
                    while !text.contains("\n") {
                        text.push_str(
                            std::str::from_utf8(&response.chunk().await.unwrap().unwrap()).unwrap(),
                        );
                    }
                    assert!(text.contains("\"event\":\"accepted\""));
                    let short_calls = runtime
                        .requests
                        .clone()
                        .try_acquire_many_owned(8)
                        .expect("online streams must leave the short API pool available");
                    drop(short_calls);
                    if mode == "policy" {
                        runtime.policies.deny(&runtime.binding).await.unwrap();
                    }
                }
                if mode == "heartbeat" {
                    while text.matches("\"event\":\"work\"").count() < 2 {
                        text.push_str(
                            std::str::from_utf8(&response.chunk().await.unwrap().unwrap()).unwrap(),
                        );
                    }
                } else if mode != "disconnect" {
                    text.push_str(&response.text().await.unwrap());
                    let events: Vec<Value> = text
                        .lines()
                        .map(|s| serde_json::from_str(s).unwrap())
                        .collect();
                    if mode == "success" {
                        assert_eq!(events.first().unwrap()["event"], "accepted");
                        assert_eq!(events.last().unwrap()["state"], "awaiting_result");
                        assert!(events.iter().any(|e| e["event"] == "work"));
                    } else {
                        assert_eq!(events.last().unwrap()["event"], "error");
                        assert_eq!(
                            events.last().unwrap()["delivery"],
                            if mode == "policy" {
                                "accepted"
                            } else {
                                "uncertain"
                            }
                        );
                        if mode == "lost_reply" {
                            assert!(!events.iter().any(|e| e["event"] == "accepted"));
                        }
                    }
                }
            }
        }
        tokio::time::timeout(Duration::from_secs(4), host)
            .await
            .expect(mode)
            .unwrap();
        api.abort();
        relay.abort();
        drop(runtime);
        db.cleanup().await;
    }
}
