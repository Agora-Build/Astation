//! Observe real owner-driven Portal changes. Only waiting_for_host readiness
//! is assumed by the private fixture; pause/revocation are never simulated.
use super::{protected_json, response, save_evidence};
use crate::{integration_feed::PolicyCheckpoint, station_integrations::StationIntegrations};
use atem_client::session::wire::Target;
use axum::http::StatusCode;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};
use tokio::net::TcpStream;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, Message},
    MaybeTlsStream, WebSocketStream,
};

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

async fn history_boundary(socket: &mut Socket) {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let frame = socket.next().await.unwrap().unwrap();
            assert!(!frame.is_close());
            if let Ok(text) = frame.to_text() {
                let event: Value = serde_json::from_str(text).unwrap();
                if event["type"] == "agentChat" && event["data"]["op"] == "history_end" {
                    break;
                }
            }
        }
    })
    .await
    .expect("live subscribed history before ready for pause");
}

async fn refreshed_subscription(prefix: &str, raw: &str, target: &Target) -> Socket {
    let mut upgrade = format!("{}/events", prefix.replacen("http://", "ws://", 1))
        .into_client_request()
        .unwrap();
    upgrade
        .headers_mut()
        .insert("authorization", format!("Bearer {raw}").parse().unwrap());
    let (mut next, _) = tokio::time::timeout(Duration::from_secs(30), connect_async(upgrade))
        .await
        .unwrap()
        .expect("refresh authenticated subscription before token expiry");
    let initial = tokio::time::timeout(Duration::from_secs(10), next.next())
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
    next.send(json!({"target":target}).to_string().into())
        .await
        .unwrap();
    history_boundary(&mut next).await;
    next
}

async fn changes(original: &StationIntegrations, cursor: u64, id: &str, kind: &str) -> Value {
    // Share the report client's pacing with the real feed worker.
    tokio::time::sleep(Duration::from_secs(1)).await;
    let page = original
        .portal
        .changes(cursor)
        .await
        .expect("actual authenticated change feed");
    assert!(page
        .changes
        .iter()
        .any(|c| c.integration_id.as_deref() == Some(id) && c.kind == kind));
    json!({"cursor":page.cursor,"changes":page.changes.iter().map(|c|
        json!({"id":c.id,"integration_id":c.integration_id,"kind":c.kind,
            "state":c.integration.as_ref().map(|p|p.state.as_str())})
    ).collect::<Vec<_>>()})
}

async fn mirror(
    original: &StationIntegrations,
    pool: &sqlx::PgPool,
    binding: &str,
    id: &str,
) -> PolicyCheckpoint {
    let actual = original.policies.load(&original.binding).await.unwrap();
    assert!(!actual.denied, "actual Station policy unavailable");
    let age = chrono::Utc::now().timestamp() - actual.received_at;
    assert!(
        (0..=120).contains(&age),
        "actual Portal feed must remain fresh"
    );
    let mut fixture = actual.clone();
    if fixture.integrations[id].state == "waiting_for_host" {
        fixture.integrations.get_mut(id).unwrap().state = "ready".into();
    }
    sqlx::query("UPDATE station_integration_policy SET checkpoint=$1 WHERE binding=$2")
        .bind(serde_json::to_string(&fixture).unwrap())
        .bind(binding)
        .execute(pool)
        .await
        .unwrap();
    actual
}

pub(super) async fn observe_revocation(
    original: &StationIntegrations,
    pool: &sqlx::PgPool,
    binding: &str,
    id: &str,
    raw: &str,
    client: &reqwest::Client,
    prefix: &str,
    socket: &mut Socket,
    target: &Target,
    path: &Path,
) {
    let token = protected_json("LIVE_HOSTED_TOKEN_FILE");
    let mut expiry = token["expires_at"].as_i64().unwrap();
    let mut raw = raw.to_owned();
    assert!(expiry > chrono::Utc::now().timestamp() + 120);
    history_boundary(socket).await;
    let baseline = mirror(original, pool, binding, id).await;
    assert_eq!(baseline.integrations[id].state, "waiting_for_host");
    let fingerprint = baseline.integrations[id].r9_svc.as_deref().unwrap();
    let mut evidence = json!({"kind":"actual_portal_revocation","phase":"ready_for_revoke",
        "integration_id":id,"target":target,"baseline_cursor":baseline.cursor,
        "baseline_revision":baseline.revision,
        "revoke_deadline_at":chrono::Utc::now().timestamp()+1_200,
        "pre_revoke_token_expires_at":expiry,"readiness_fixture_only":true,
        "agent_mutations_submitted":0});
    save_evidence(path, &evidence);
    println!("LIVE: ready for revoke; actual feed, issued token and subscribed stream live");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(1_200);
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    let mut socket_closed = false;
    let revoked = loop {
        tokio::select! {
            _ = tick.tick() => {
                let actual = mirror(original, pool, binding, id).await;
                assert!(tokio::time::Instant::now() < deadline, "owner revoke observation deadline");
                match actual.integrations[id].state.as_str() {
                    "revoking" | "revoked" => break actual,
                    "waiting_for_host" => {
                        let next = protected_json("LIVE_HOSTED_TOKEN_FILE");
                        let next_expiry = next["expires_at"].as_i64().unwrap();
                        if next_expiry > expiry {
                            let next_raw = next["access_token"].as_str().unwrap();
                            assert!(next_expiry > chrono::Utc::now().timestamp() + 120);
                            let next_socket = refreshed_subscription(prefix, next_raw, target).await;
                            let mut previous = std::mem::replace(socket, next_socket);
                            let _ = previous.close(None).await;
                            raw = next_raw.to_owned();
                            expiry = next_expiry;
                            evidence["pre_revoke_token_expires_at"] = json!(expiry);
                            let rotations = evidence["token_refreshes"].as_u64().unwrap_or(0)+1;
                            evidence["token_refreshes"] = json!(rotations);
                            save_evidence(path, &evidence);
                        }
                    },
                    _ => panic!("unexpected actual policy transition before revoke"),
                }
            },
            frame = socket.next() => {
                match frame {
                    Some(Ok(frame)) if !frame.is_close() => {},
                    _ => {
                        // The stream's policy check may win the race with our tick.
                        let actual = mirror(original, pool, binding, id).await;
                        assert!(matches!(actual.integrations[id].state.as_str(), "revoking" | "revoked"),
                            "stream closed before actual revocation");
                        socket_closed = true;
                        break actual;
                    }
                }
            }
        }
    };
    assert!(revoked.cursor > baseline.cursor);
    original
        .verifier
        .verify_integration(&raw, "agent.view", fingerprint)
        .await
        .expect("issued token still verifies; actual revocation must deny it");
    let denied = response(
        client.get(format!("{prefix}/sessions")).bearer_auth(&raw),
        StatusCode::UNAUTHORIZED,
    )
    .await;
    if !socket_closed {
        tokio::time::timeout(Duration::from_secs(5), async {
            while let Some(frame) = socket.next().await {
                match frame {
                    Ok(frame) if !frame.is_close() => {}
                    _ => break,
                }
            }
        })
        .await
        .expect("actual revocation closes existing event stream");
    }
    let mut upgrade = format!("{}/events", prefix.replacen("http://", "ws://", 1))
        .into_client_request()
        .unwrap();
    upgrade
        .headers_mut()
        .insert("authorization", format!("Bearer {raw}").parse().unwrap());
    match tokio::time::timeout(Duration::from_secs(15), connect_async(upgrade))
        .await
        .unwrap()
    {
        Err(tokio_tungstenite::tungstenite::Error::Http(reply)) => {
            assert_eq!(reply.status(), StatusCode::UNAUTHORIZED)
        }
        _ => panic!("revoked integration must refuse a fresh WebSocket attachment"),
    }
    evidence["phase"] = json!("revocation_denied");
    evidence["revoked_cursor"] = json!(revoked.cursor);
    evidence["revoked_revision"] = json!(revoked.revision);
    evidence["actual_state"] = json!(revoked.integrations[id].state);
    evidence["revocation_events"] =
        changes(original, baseline.cursor, id, "integration_revoked").await;
    evidence["issued_token_still_valid"] = json!(true);
    evidence["fresh_http_denied"] = denied;
    evidence["open_stream_closed"] = json!(true);
    evidence["fresh_ws_reconnect_denied"] = json!(true);
    save_evidence(path, &evidence);
    println!("LIVE: actual revocation denies issued-token HTTP, closes stream and refuses reconnect; zero agent mutations");
}

pub(super) async fn observe(
    original: &StationIntegrations,
    pool: &sqlx::PgPool,
    binding: &str,
    id: &str,
    raw: &str,
    client: &reqwest::Client,
    prefix: &str,
    socket: &mut Socket,
    target: &Target,
    path: &Path,
) {
    let token = protected_json("LIVE_HOSTED_TOKEN_FILE");
    let mut expiry = token["expires_at"].as_i64().unwrap();
    let mut raw = raw.to_owned();
    assert!(expiry > chrono::Utc::now().timestamp() + 120);
    // Require the actual subscribed history boundary before announcing readiness.
    history_boundary(socket).await;
    let baseline = mirror(original, pool, binding, id).await;
    assert_eq!(baseline.integrations[id].state, "waiting_for_host");
    let mut evidence = json!({"kind":"actual_portal_lifecycle","phase":"ready_for_pause",
        "integration_id":id,"target":target,"baseline_cursor":baseline.cursor,
        "baseline_revision":baseline.revision,
        "pause_deadline_at":chrono::Utc::now().timestamp()+1_200,
        "pre_pause_token_expires_at":expiry,"readiness_fixture_only":true,
        "agent_mutations_submitted":0});
    save_evidence(path, &evidence);
    println!("LIVE: ready for pause; actual feed observer, issued token and subscribed event stream live");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(1_200);
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    let paused = loop {
        tokio::select! {
            _ = tick.tick() => {
                let actual = mirror(original, pool, binding, id).await;
                assert!(tokio::time::Instant::now() < deadline, "owner pause observation deadline");
                match actual.integrations[id].state.as_str() {
                    "paused" => {
                        assert!(actual.cursor > baseline.cursor);
                        break actual;
                    },
                    "waiting_for_host" => {
                        let next = protected_json("LIVE_HOSTED_TOKEN_FILE");
                        let next_expiry = next["expires_at"].as_i64().unwrap();
                        if next_expiry > expiry {
                            let next_raw = next["access_token"].as_str().unwrap();
                            assert!(next_expiry > chrono::Utc::now().timestamp() + 120);
                            let next_socket = refreshed_subscription(prefix, next_raw, target).await;
                            // Establish the replacement first so the owner window has no gap.
                            let mut previous = std::mem::replace(socket, next_socket);
                            let _ = previous.close(None).await;
                            raw = next_raw.to_owned();
                            expiry = next_expiry;
                            evidence["pre_pause_token_expires_at"] = json!(expiry);
                            let rotations = evidence["token_refreshes"].as_u64().unwrap_or(0) + 1;
                            evidence["token_refreshes"] = json!(rotations);
                            save_evidence(path, &evidence);
                            println!("LIVE: refreshed Auth token and overlapping subscription; pause observer remains live");
                        }
                    },
                    _ => panic!("unexpected actual policy transition before pause"),
                }
            },
            frame = socket.next() => {
                let frame = frame.expect("stream must remain open before observed pause").unwrap();
                assert!(!frame.is_close(), "stream closed before actual pause was observed");
            }
        }
    };
    let fingerprint = paused.integrations[id].r9_svc.as_deref().unwrap();
    original
        .verifier
        .verify_integration(&raw, "agent.view", fingerprint)
        .await
        .expect("issued token still verifies; policy must independently deny it");
    let denied = response(
        client.get(format!("{prefix}/sessions")).bearer_auth(&raw),
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
    .expect("actual pause closes existing event stream");
    evidence["phase"] = json!("paused_observed");
    evidence["paused_cursor"] = json!(paused.cursor);
    evidence["paused_revision"] = json!(paused.revision);
    evidence["pause_events"] = changes(original, baseline.cursor, id, "integration_paused").await;
    evidence["issued_token_still_valid"] = json!(true);
    evidence["fresh_http_denied"] = denied;
    evidence["open_stream_closed"] = json!(true);
    save_evidence(path, &evidence);
    println!(
        "LIVE: actual pause observed; still-valid issued token denied and existing stream closed"
    );

    let deadline = tokio::time::Instant::now() + Duration::from_secs(900);
    let resumed = loop {
        let actual = mirror(original, pool, binding, id).await;
        match actual.integrations[id].state.as_str() {
            "waiting_for_host" => {
                assert!(actual.cursor > paused.cursor);
                assert_eq!(actual.integrations[id], baseline.integrations[id]);
                break actual;
            }
            "paused" => {}
            _ => panic!("unexpected actual policy transition while awaiting resume"),
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "owner resume observation deadline"
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
    };
    evidence["phase"] = json!("resumed_awaiting_fresh_token");
    evidence["resumed_cursor"] = json!(resumed.cursor);
    evidence["resumed_revision"] = json!(resumed.revision);
    evidence["resume_events"] = changes(original, paused.cursor, id, "integration_resumed").await;
    save_evidence(path, &evidence);
    println!("LIVE: actual resume observed; waiting for newly issued Auth token");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
    let fresh = loop {
        let next = protected_json("LIVE_HOSTED_TOKEN_FILE");
        if next["expires_at"].as_i64().is_some_and(|e| e > expiry) {
            break next;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "fresh token deadline after actual resume"
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
    };
    let raw = fresh["access_token"].as_str().unwrap();
    let snapshot = response(
        client.get(format!("{prefix}/sessions")).bearer_auth(raw),
        StatusCode::OK,
    )
    .await;
    assert!(snapshot["targets"]
        .as_array()
        .unwrap()
        .contains(&json!(target)));
    let mut upgrade = format!("{}/events", prefix.replacen("http://", "ws://", 1))
        .into_client_request()
        .unwrap();
    upgrade
        .headers_mut()
        .insert("authorization", format!("Bearer {raw}").parse().unwrap());
    let (mut reconnected, _) =
        tokio::time::timeout(Duration::from_secs(30), connect_async(upgrade))
            .await
            .unwrap()
            .expect("fresh authenticated stream after actual resume");
    let snapshot = tokio::time::timeout(Duration::from_secs(10), reconnected.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let snapshot: Value = serde_json::from_str(snapshot.to_text().unwrap()).unwrap();
    assert_eq!(snapshot["type"], "snapshot");
    assert!(snapshot["targets"]
        .as_array()
        .unwrap()
        .contains(&json!(target)));
    reconnected.send(Message::Close(None)).await.unwrap();
    evidence["phase"] = json!("completed");
    evidence["fresh_token_http_and_ws_reconnect"] = json!(true);
    save_evidence(path, &evidence);
    println!("LIVE: actual Portal pause/resume and fresh-token HTTP/WebSocket reconnect pass; no agent input");
}
