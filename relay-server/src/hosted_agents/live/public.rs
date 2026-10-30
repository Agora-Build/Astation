//! Operator-only public-origin canary. No fixture policy, router or gate bypass.
use super::{http::formatted_reply, http::response, protected_json, required, save_evidence};
use atem_client::session::{new_id, wire::Target};
use axum::http::StatusCode;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio_tungstenite::{connect_async, tungstenite::client::IntoClientRequest};

#[tokio::test]
#[ignore = "approved public canary, current protected token and disposable real agent required"]
async fn approved_public_origin_recovers_one_prompt_without_replay() {
    assert_eq!(required("LIVE_HOSTED_DISPOSABLE"), "yes");
    assert_eq!(required("LIVE_HOSTED_PUBLIC_ROLLOUT"), "approved");
    let origin = required("PUBLIC_BASE_URL");
    assert!(crate::account_identity::integration_station_origin(&origin));
    let id = required("LIVE_HOSTED_INTEGRATION");
    let host = required("LIVE_HOSTED_HOST");
    let session = required("LIVE_HOSTED_SESSION");
    let process = required("LIVE_HOSTED_PROCESS_GEN");
    let expected_build = required("LIVE_HOSTED_EXPECTED_BUILD");
    let token = protected_json("LIVE_HOSTED_TOKEN_FILE");
    assert!(token["expires_at"].as_i64().unwrap() > chrono::Utc::now().timestamp() + 150);
    let raw = token["access_token"].as_str().unwrap();
    let path = PathBuf::from(required("LIVE_HOSTED_EVIDENCE_FILE"));
    let recovering = std::env::var("LIVE_HOSTED_RECOVER").as_deref() == Ok("receipts");
    assert!(
        recovering || !path.exists(),
        "existing evidence: recover, never resubmit"
    );
    let client = reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .timeout(Duration::from_secs(30))
        .build()
        .unwrap();
    let health = response(client.get(format!("{origin}/health")), StatusCode::OK).await;
    assert_eq!(health["build_commit"], expected_build);
    assert_eq!(health["redis"], "ok");
    assert_eq!(health["replicas"], 2);
    let prefix = format!("{origin}/api/agent/v1/integrations/{id}/hosts/{host}");
    let session_url = format!("{prefix}/sessions/{session}");
    for token in [None, Some("invalid")] {
        let mut request = client.get(format!("{prefix}/sessions"));
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        response(request, StatusCode::UNAUTHORIZED).await;
    }
    let snapshot = response(
        client.get(format!("{prefix}/sessions")).bearer_auth(raw),
        StatusCode::OK,
    )
    .await;
    let target: Target = serde_json::from_value(
        snapshot["targets"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["session_id"] == session)
            .expect("current real agent target")
            .clone(),
    )
    .unwrap();
    assert_eq!(target.atem_device_id, host);
    assert_eq!(target.process_gen, process);
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
    response(
        client
            .post(format!("{session_url}/history"))
            .bearer_auth(raw)
            .json(&json!({"target":stale})),
        StatusCode::CONFLICT,
    )
    .await;

    let stream_url = format!("{}/events", prefix.replacen("https://", "wss://", 1));
    let upgrade = || {
        let mut request = stream_url.clone().into_client_request().unwrap();
        request
            .headers_mut()
            .insert("authorization", format!("Bearer {raw}").parse().unwrap());
        request
    };
    let (mut socket, _) = tokio::time::timeout(Duration::from_secs(30), connect_async(upgrade()))
        .await
        .unwrap()
        .expect("real public proxy WebSocket upgrade");
    let first = tokio::time::timeout(Duration::from_secs(15), socket.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let first: Value = serde_json::from_str(first.to_text().unwrap()).unwrap();
    assert_eq!(first["type"], "snapshot");
    assert!(first["targets"]
        .as_array()
        .unwrap()
        .contains(&json!(target)));
    socket
        .send(json!({"target":target}).to_string().into())
        .await
        .unwrap();
    let mut evidence = if recovering {
        let saved = protected_json("LIVE_HOSTED_EVIDENCE_FILE");
        assert_eq!(saved["kind"], "public_origin_rollout");
        assert_eq!(saved["origin"], origin);
        assert_eq!(saved["integration_id"], id);
        assert_eq!(saved["target"], json!(target));
        assert!(saved["request_id"]
            .as_str()
            .is_some_and(atem_client::session::wire::is_uuid_v4));
        saved
    } else {
        let marker = format!(
            "Astation public canary {:06} complete",
            rand::random::<u32>() % 1_000_000
        );
        json!({"kind":"public_origin_rollout","origin":origin,"integration_id":id,
            "target":target,"request_id":new_id(),"marker":marker,"phase":"prepared",
            "prompt":format!("Reply with exactly **{marker}** followed by a blank line and [Astation](https://agora.build). Do not use tools, run commands or change any files."),
            "health":health,"snapshot":snapshot,"ws_snapshot":first})
    };
    let request = evidence["request_id"].as_str().unwrap().to_owned();
    let marker = evidence["marker"].as_str().unwrap().to_owned();
    if !recovering {
        // Exactly one send. After any transport/HTTP uncertainty only receipts
        // are read; even a saved prepared record never authorizes a replay.
        save_evidence(&path, &evidence);
        let submitted = client
            .post(format!("{session_url}/prompts"))
            .bearer_auth(raw)
            .json(&json!({"target":target,"request_id":request,"text":evidence["prompt"]}))
            .send()
            .await;
        if let Ok(reply) = submitted {
            let status = reply.status();
            evidence["submit_status"] = json!(status.as_u16());
            if let Ok(body) = reply.json::<Value>().await {
                evidence["submit_reply"] = body;
            }
        }
        evidence["phase"] = json!("submitted_or_uncertain");
        save_evidence(&path, &evidence);
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
    loop {
        let reply = response(
            client
                .post(format!("{session_url}/receipts"))
                .bearer_auth(raw)
                .json(&json!({"target":target,"request_ids":[request]})),
            StatusCode::OK,
        )
        .await;
        let receipt = reply["events"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|e| e["data"]["receipts"].as_array().into_iter().flatten())
            .find(|r| r["request_id"] == request && r["target"] == json!(target))
            .cloned();
        if let Some(receipt) = receipt {
            evidence["recovered_receipt"] = receipt.clone();
            save_evidence(&path, &evidence);
            assert!(matches!(
                receipt["state"].as_str(),
                Some("accepted" | "executing" | "completed")
            ));
            if receipt["state"] == "completed" {
                break;
            }
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "recover saved request; never resubmit"
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
        .unwrap();
    assert!(history["events"]
        .as_array()
        .unwrap()
        .iter()
        .any(|event| formatted_reply(event, replies, &marker)));
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let frame = socket.next().await.unwrap().unwrap();
            let Ok(text) = frame.to_text() else { continue };
            let event: Value = serde_json::from_str(text).unwrap();
            if event["type"] == "agentChat" && formatted_reply(&event, replies, &marker) {
                break;
            }
        }
    })
    .await
    .expect("matching formatted response over the public event stream");
    socket.close(None).await.unwrap();
    let (mut reconnect, _) =
        tokio::time::timeout(Duration::from_secs(30), connect_async(upgrade()))
            .await
            .unwrap()
            .expect("fresh public event-stream attachment");
    let frame = tokio::time::timeout(Duration::from_secs(15), reconnect.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let frame: Value = serde_json::from_str(frame.to_text().unwrap()).unwrap();
    assert_eq!(frame["type"], "snapshot");
    assert!(frame["targets"]
        .as_array()
        .unwrap()
        .contains(&json!(target)));
    reconnect.close(None).await.unwrap();
    evidence["phase"] = json!("completed");
    evidence["formatted_history_and_stream"] = json!(true);
    evidence["fresh_public_ws_reconnect"] = json!(true);
    save_evidence(&path, &evidence);
    println!("LIVE: public HTTPS/WSS, one real prompt, original receipt recovery and formatted response pass");
}
