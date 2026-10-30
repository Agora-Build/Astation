//! Real-host HTTP adapter check. Only an isolated policy schema and loopback
//! test listener assume readiness; deployed policy and the release gate do not.
use super::{protected_json, save_evidence};
use crate::{
    integration_feed::PolicyStore,
    station_integrations::{IntegrationState, StationIntegrations},
    test_database::TestDatabase,
};
use atem_client::session::{new_id, wire::Target};
use axum::{extract::DefaultBodyLimit, http::StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{path::Path, sync::Arc, time::Duration};
use tokio_tungstenite::{connect_async, tungstenite::client::IntoClientRequest};

async fn response(request: reqwest::RequestBuilder, status: StatusCode) -> Value {
    let reply = request.send().await.expect("bounded HTTP response");
    let actual = reply.status();
    let value: Value = reply.json().await.expect("JSON HTTP response");
    assert_eq!(actual, status, "HTTP error code {}", value["error"]["code"]);
    value
}

fn formatted_reply(event: &Value, replies: &[Value], marker: &str) -> bool {
    let data = &event["data"];
    data["op"] == "message"
        && data["role"] == "assistant"
        && replies.contains(&data["messageId"])
        && data["parts"].as_array().is_some_and(|parts| {
            parts.iter().any(|p| {
                p["markdown"].as_str().is_some_and(|s| {
                    s.contains(marker)
                        && s.contains("**")
                        && s.contains("[Astation](https://agora.build)")
                })
            })
        })
}

pub(super) async fn run(
    original: Arc<StationIntegrations>,
    id: &str,
    raw: &str,
    host: &str,
    session: &str,
    target: &Target,
    evidence_path: &Path,
    recovering: bool,
) {
    let checkpoint = original.policies.load(&original.binding).await.unwrap();
    assert!(!checkpoint.denied);
    assert_eq!(checkpoint.integrations[id].state, "waiting_for_host");
    let mut ready = checkpoint.clone();
    ready.integrations.get_mut(id).unwrap().state = "ready".into();

    // Shadow only readiness and quota. Keys, native consent, host identity and
    // membership still come from the actual approved records in public.
    let fixture = TestDatabase::new("DATABASE_URL", 5).await;
    for table in ["station_integration_policy", "station_integration_quota"] {
        sqlx::query(&format!(
            "CREATE TABLE {table} (LIKE public.{table} INCLUDING ALL)"
        ))
        .execute(&fixture.pool)
        .await
        .unwrap();
    }
    let schema: String = sqlx::query_scalar("SELECT current_schema()")
        .fetch_one(&fixture.pool)
        .await
        .unwrap();
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(5)
        .connect_with(
            (*fixture.pool.connect_options())
                .clone()
                .options([("search_path", format!("{schema},public"))]),
        )
        .await
        .unwrap();
    let binding = serde_json::to_string(&original.binding).unwrap();
    sqlx::query("INSERT INTO station_integration_policy(binding,checkpoint) VALUES ($1,$2)")
        .bind(&binding)
        .bind(serde_json::to_string(&ready).unwrap())
        .execute(&pool)
        .await
        .unwrap();
    let mut runtime = StationIntegrations::from_env(original.app.clone())
        .unwrap()
        .unwrap();
    Arc::get_mut(&mut runtime).unwrap().policies = PolicyStore(pool.clone());
    // Never start this fixture's feed/readiness worker or publish it to Portal.
    let router = super::super::operation_routes()
        .layer(DefaultBodyLimit::max(65_536))
        .with_state(IntegrationState(Some(runtime.clone())));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .unwrap();
    let prefix = format!("http://{address}/api/agent/v1/integrations/{id}/hosts/{host}");
    let session_url = format!("{prefix}/sessions/{session}");
    response(
        client.get(format!("{prefix}/sessions")),
        StatusCode::UNAUTHORIZED,
    )
    .await;
    response(
        client
            .get(format!("{prefix}/sessions"))
            .bearer_auth("invalid"),
        StatusCode::UNAUTHORIZED,
    )
    .await;
    let snapshot = response(
        client.get(format!("{prefix}/sessions")).bearer_auth(raw),
        StatusCode::OK,
    )
    .await;
    assert!(snapshot["targets"]
        .as_array()
        .unwrap()
        .contains(&json!(target)));
    let approvals = response(
        client
            .get(format!("{session_url}/approvals"))
            .bearer_auth(raw),
        StatusCode::OK,
    )
    .await;
    assert_eq!(approvals["target"], json!(target));
    assert!(approvals["approvals"].as_array().unwrap().is_empty());
    let mut stale = json!(target);
    stale["process_gen"] = json!(new_id());
    let refused = response(
        client
            .post(format!("{session_url}/history"))
            .bearer_auth(raw)
            .json(&json!({"target":stale})),
        StatusCode::CONFLICT,
    )
    .await;
    assert_eq!(refused["error"]["code"], "stale_target");
    println!("LIVE: real JWT HTTP discovery, approval lookup and stale-target refusal pass");

    let mut upgrade = format!("ws://{address}/api/agent/v1/integrations/{id}/hosts/{host}/events")
        .into_client_request()
        .unwrap();
    upgrade
        .headers_mut()
        .insert("authorization", format!("Bearer {raw}").parse().unwrap());
    let (mut socket, _) = tokio::time::timeout(Duration::from_secs(30), connect_async(upgrade))
        .await
        .unwrap()
        .expect("authenticated HTTP WebSocket upgrade");
    let initial = tokio::time::timeout(Duration::from_secs(10), socket.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let initial: Value = serde_json::from_str(initial.to_text().unwrap()).unwrap();
    assert_eq!(initial["type"], "snapshot");
    assert!(initial["targets"]
        .as_array()
        .unwrap()
        .contains(&json!(target)));
    socket
        .send(json!({"target":target}).to_string().into())
        .await
        .unwrap();

    let mut evidence = if recovering {
        let saved = protected_json("LIVE_HOSTED_EVIDENCE_FILE");
        assert_eq!(saved["kind"], "http_readiness_fixture");
        assert_eq!(saved["target"], json!(target));
        assert_eq!(saved["integration_id"], id);
        assert_eq!(saved["host"], host);
        assert!(saved["request_id"]
            .as_str()
            .is_some_and(atem_client::session::wire::is_uuid_v4));
        saved
    } else {
        let marker = format!(
            "Astation HTTP check {:06} complete",
            rand::random::<u32>() % 1_000_000
        );
        json!({"kind":"http_readiness_fixture","phase":"prepared",
            "integration_id":id,"host":host,"target":target,"request_id":new_id(),
            "marker":marker,"prompt":format!(
                "Reply with exactly **{marker}** followed by a blank line and [Astation](https://agora.build). Do not use tools, run commands or change any files."),
            "snapshot":snapshot,"approvals":approvals,"ws_snapshot":initial})
    };
    let request = evidence["request_id"].as_str().unwrap().to_owned();
    let marker = evidence["marker"].as_str().unwrap().to_owned();
    if !recovering {
        save_evidence(evidence_path, &evidence);
        // Exactly one POST. A lost response is recovered by receipt queries,
        // including on a later operator run, never by another submit.
        let submitted = client
            .post(format!("{session_url}/prompts"))
            .bearer_auth(raw)
            .json(&json!({"target":target,"request_id":request,"text":evidence["prompt"]}))
            .send()
            .await
            .expect("prompt response uncertain: recover saved receipt, do not resend");
        let status = submitted.status();
        evidence["submit_status"] = json!(status.as_u16());
        evidence["submit_reply"] = submitted.json::<Value>().await.unwrap();
        evidence["phase"] = json!("submitted");
        save_evidence(evidence_path, &evidence);
        assert!(
            status == StatusCode::OK
                || (status == StatusCode::GATEWAY_TIMEOUT
                    && evidence["submit_reply"]["error"]["code"] == "delivery_uncertain")
        );
    }

    let deadline = tokio::time::Instant::now() + Duration::from_secs(80);
    loop {
        let receipt_reply = response(
            client
                .post(format!("{session_url}/receipts"))
                .bearer_auth(raw)
                .json(&json!({"target":target,"request_ids":[request]})),
            StatusCode::OK,
        )
        .await;
        let receipt = receipt_reply["events"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|e| e["data"]["receipts"].as_array().into_iter().flatten())
            .find(|r| r["request_id"] == request && r["target"] == json!(target))
            .expect("same complete receipt on a fresh HTTP attachment")
            .clone();
        evidence["recovered_receipt"] = receipt.clone();
        save_evidence(evidence_path, &evidence);
        assert!(
            matches!(
                receipt["state"].as_str(),
                Some("accepted" | "executing" | "completed")
            ),
            "prompt did not complete: preserve receipt evidence; do not resend"
        );
        if receipt["state"] == "completed" {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "receipt deadline; recover, do not resend"
        );
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    let history = response(
        client
            .post(format!("{session_url}/history"))
            .bearer_auth(raw)
            .json(&json!({"target":target})),
        StatusCode::OK,
    )
    .await;
    let replies = evidence["recovered_receipt"]["result"]["reply_message_ids"]
        .as_array()
        .unwrap()
        .clone();
    assert!(
        history["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| formatted_reply(e, &replies, &marker)),
        "correlated real assistant Markdown response"
    );
    evidence["history"] = history;
    save_evidence(evidence_path, &evidence);
    let stream = tokio::time::timeout(Duration::from_secs(15), async {
        let mut events = Vec::new();
        while let Some(frame) = socket.next().await {
            let frame = frame.unwrap();
            if let Ok(text) = frame.to_text() {
                let event: Value = serde_json::from_str(text).unwrap();
                let matched = formatted_reply(&event, &replies, &marker);
                events.push(event);
                if matched {
                    return events;
                }
            }
        }
        panic!("stream closed before correlated assistant message");
    })
    .await
    .expect("real-time assistant WebSocket update");
    evidence["ws_events"] = json!(stream);
    println!("LIVE: HTTP receipt/history recovery and real-time Markdown response pass; prompt replayed: false");

    // Deny only the isolated checkpoint. A connected event stream must stop,
    // and fresh HTTP requests must fail. Actual Portal revocation is separate.
    ready.denied = true;
    sqlx::query("UPDATE station_integration_policy SET checkpoint=$1 WHERE binding=$2")
        .bind(serde_json::to_string(&ready).unwrap())
        .bind(&binding)
        .execute(&pool)
        .await
        .unwrap();
    response(
        client.get(format!("{prefix}/sessions")).bearer_auth(raw),
        StatusCode::UNAUTHORIZED,
    )
    .await;
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(frame) = socket.next().await {
            match frame {
                Ok(frame) if !frame.is_close() => {}
                _ => break,
            }
        }
    })
    .await
    .expect("policy denial closes existing WebSocket");
    evidence["phase"] = json!("completed");
    evidence["isolated_policy_denial_closed_stream"] = json!(true);
    save_evidence(evidence_path, &evidence);
    server.abort();
    let _ = server.await;
    drop(socket);
    drop(runtime);
    pool.close().await;
    fixture.cleanup().await;
    let actual = original.policies.load(&original.binding).await.unwrap();
    assert!(!actual.denied);
    assert_eq!(actual.integrations[id], checkpoint.integrations[id]);
    assert!(!super::super::HOSTED_EXECUTION_ENABLED);
    println!(
        "LIVE: fixture denial closes HTTP/WS; deployed policy and public release gate unchanged"
    );
}
