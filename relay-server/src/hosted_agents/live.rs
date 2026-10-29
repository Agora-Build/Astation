//! Explicit operator test against an already approved disposable host. The
//! public production router stays gated; this module is absent from releases.
use super::client::HostedConnection;
use crate::{service_keys::ServiceKeyContext, station_integrations::StationIntegrations};
use axum::http::StatusCode;
use serde_json::{json, Value};
use std::{path::PathBuf, sync::Arc, time::Duration};

fn required(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is required"))
}

fn protected_json(name: &str) -> Value {
    let path = PathBuf::from(required(name));
    let metadata = std::fs::symlink_metadata(&path).expect("protected file metadata");
    assert!(metadata.is_file() && metadata.len() < 65_536);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(metadata.permissions().mode() & 0o077, 0);
    }
    serde_json::from_slice(&std::fs::read(path).expect("protected file read"))
        .expect("protected file JSON")
}

fn save_evidence(path: &std::path::Path, value: &Value) {
    use std::io::Write;
    let next = path.with_extension(format!("{}.next", uuid::Uuid::new_v4().simple()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&next)
        .expect("new request evidence checkpoint");
    file.write_all(serde_json::to_string_pretty(value).unwrap().as_bytes())
        .unwrap();
    file.sync_all().expect("request evidence commit");
    std::fs::rename(next, path).expect("request evidence checkpoint publish");
    std::fs::File::open(path.parent().unwrap())
        .unwrap()
        .sync_all()
        .unwrap();
}

/// Readiness is the result being tested, not a grant of authority. Require the
/// real token, fresh Auth policy and already signed service grant independently.
/// No policy is edited or reported ready and no public handler omits its gate.
async fn authorize(
    runtime: &StationIntegrations,
    id: &str,
    raw: &str,
    operation: &str,
) -> (ServiceKeyContext, String) {
    let context = runtime.context(id).await.expect("saved service context");
    let checkpoint = runtime
        .policies
        .load(&runtime.binding)
        .await
        .expect("policy feed");
    let policy = checkpoint
        .current(id, &context.owner, chrono::Utc::now().timestamp())
        .expect("fresh non-denied policy");
    assert!(matches!(
        policy.state.as_str(),
        "waiting_for_host" | "ready"
    ));
    assert!(policy.scopes.iter().any(|s| s == operation));
    let fingerprint = policy.r9_svc.clone().expect("approved service fingerprint");
    let token = runtime
        .verifier
        .verify_integration(raw, operation, &fingerprint)
        .await
        .expect("real Auth service token");
    assert_eq!(token.identity.subject, context.owner);
    assert_eq!(token.client_id, id);
    assert_eq!(token.identity.issuer, context.issuer);
    assert_eq!(token.service_fingerprint, fingerprint);
    assert!(token.expires_at <= policy.expires_at().unwrap());
    (context, fingerprint)
}

async fn open(runtime: &StationIntegrations, id: &str, raw: &str, host: &str) -> HostedConnection {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
    loop {
        let (context, fingerprint) = authorize(runtime, id, raw, "agent.view").await;
        if let Ok(connection) = HostedConnection::open(runtime, &context, &fingerprint, host).await
        {
            return connection;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "proved service connection unavailable; no submit replayed"
        );
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

async fn history(connection: &mut HostedConnection, session: &str) -> Vec<Value> {
    let conversation = atem_client::session::new_id();
    connection.attached.chat_mut().open(&conversation, session);
    let binding = connection
        .attached
        .binding(session, connection.now())
        .expect("chat binding");
    let frame = connection
        .attached
        .send(
            &json!({"type":"agentChat","data":{
                "v":1,"op":"open","conversationId":conversation,"agentId":session,"binding":binding
            }}),
            connection.now(),
        )
        .expect("chat open frame");
    connection.send(frame).await.expect("chat open delivery");
    let messages = connection
        .until(|v| {
            v["type"] == "agentChat"
                && v["data"]["conversationId"] == conversation
                && matches!(v["data"]["op"].as_str(), Some("history_end" | "error"))
        })
        .await
        .expect("ordered history completion");
    if let Some(error) = messages.iter().find(|v| v["data"]["op"] == "error") {
        panic!("history refused: code {}", error["data"]["error"]["code"]);
    }
    messages
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "exclusive isolated Station port, real approved service and fresh Auth token required"]
async fn protected_service_against_real_host_keeps_public_execution_closed() {
    assert!(!super::HOSTED_EXECUTION_ENABLED);
    assert_eq!(required("LIVE_HOSTED_DISPOSABLE"), "yes");
    let id = required("LIVE_HOSTED_INTEGRATION");
    let host = required("LIVE_HOSTED_HOST");
    let session = required("LIVE_HOSTED_SESSION");
    let process = required("LIVE_HOSTED_PROCESS_GEN");
    let token = protected_json("LIVE_HOSTED_TOKEN_FILE");
    let raw = token["access_token"].as_str().expect("access token");
    let evidence_path = PathBuf::from(required("LIVE_HOSTED_EVIDENCE_FILE"));
    let recovering = std::env::var("LIVE_HOSTED_RECOVER").as_deref() == Ok("receipts");
    let without_native = std::env::var("LIVE_HOSTED_WITHOUT_NATIVE").as_deref() == Ok("yes");
    let existing_cluster = std::env::var("LIVE_HOSTED_EXISTING_CLUSTER").as_deref() == Ok("yes");
    let failover_file = std::env::var("LIVE_HOSTED_FAILOVER_FILE")
        .ok()
        .map(PathBuf::from);
    assert!(
        failover_file.is_none() || existing_cluster,
        "replica failover needs the existing cluster"
    );
    assert!(
        !recovering || failover_file.is_none(),
        "receipt recovery must not request another replica interruption"
    );
    if let Some(path) = &failover_file {
        assert!(
            !path.exists(),
            "a previous failover marker cannot satisfy a new run"
        );
    }
    // A rerun must query the saved receipt instead of replaying a lost submit.
    assert!(
        recovering || !evidence_path.exists(),
        "existing evidence: recover its request via receipts first"
    );
    let _ = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .with_test_writer()
        .try_init();

    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(5)
        .connect(&required("DATABASE_URL"))
        .await
        .expect("dedicated Station database");
    let identity = Arc::new(crate::identity_store::PgIdentityStore::new(pool.clone()));
    // Join as a socket-free observer to force service traffic over the replica bus.
    // Existing host/native sockets and the deployed HTTP router remain untouched.
    let cluster = if existing_cluster {
        Some(
            crate::cluster::redis::connect_cluster(
                &required("REDIS_URL"),
                identity.clone(),
                Duration::from_secs(10),
            )
            .await
            .expect("existing isolated Redis cluster"),
        )
    } else {
        None
    };
    let relay = cluster
        .as_ref()
        .map(|cluster| cluster.relay.clone())
        .unwrap_or_else(crate::relay::RelayHub::new);
    relay
        .load_keys(identity.as_ref())
        .await
        .expect("existing relay identity keys");
    let recovery = crate::remote_api::recovery::RecoveryStore::postgres(pool.clone());
    relay.configure_recovery(recovery.clone());
    relay.configure_push_tokens(Arc::new(crate::push_tokens::PgPushTokenStore::new(
        pool.clone(),
    )));
    let state = crate::AppState {
        sessions: crate::session_store::SessionStore::new(),
        relay,
        rtc_sessions: crate::rtc_session::RtcSessionStore::new(),
        voice_sessions: crate::voice_session::VoiceSessionStore::new(),
        vault: Arc::new(crate::vault_store::PgVaultStore::new(pool.clone())),
        knowledge: Arc::new(crate::knowledge_store::PgKnowledgeStore::new(pool.clone())),
        identity,
        accounts: Arc::new(crate::account_store::PgAccountStore::new(pool)),
        recovery,
    };
    let runtime = StationIntegrations::from_env(state.clone())
        .expect("protected Station configuration")
        .expect("configured Station");
    let port: u16 = required("PORT").parse().expect("isolated Station port");
    let server = if existing_cluster {
        println!("LIVE: observing existing isolated cluster; no listener or host restart");
        None
    } else {
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port))
            .await
            .expect("exclusive isolated Station port");
        let mut router = crate::router(state);
        if without_native {
            router = router.layer(axum::middleware::from_fn(
                |request: axum::extract::Request, next: axum::middleware::Next| async move {
                    let native = request.uri().path() == "/ws"
                        && request.uri().query().is_some_and(|query| {
                            url::form_urlencoded::parse(query.as_bytes())
                                .any(|(key, value)| key == "role" && value == "astation")
                        });
                    if native {
                        return axum::response::IntoResponse::into_response(
                            StatusCode::SERVICE_UNAVAILABLE,
                        );
                    }
                    next.run(request).await
                },
            ));
        }
        Some(tokio::spawn(async move {
            axum::serve(
                listener,
                router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
            .expect("isolated Station listener")
        }))
    };

    let public = reqwest::Client::new()
        .get(format!(
            "http://127.0.0.1:{port}/api/agent/v1/integrations/{id}/hosts/{host}/sessions"
        ))
        .bearer_auth(raw)
        .send()
        .await
        .expect("public gate response");
    assert_eq!(public.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        public.json::<Value>().await.unwrap()["error"]["code"],
        "hosted_execution_not_verified"
    );
    println!("LIVE: public execution remains closed; waiting for proved host reconnect");

    let mut connection = open(&runtime, &id, raw, &host).await;
    let target = connection
        .attached
        .target(&session)
        .expect("replacement session in verified registry");
    assert_eq!(target.process_gen, process);
    if without_native {
        assert!(runtime
            .app
            .relay
            .room(&target.account_id)
            .await
            .unwrap()
            .is_none_or(|r| r.owner.is_none()));
        println!("LIVE: distributed directory confirms no Astation room owner is online");
    }
    println!(
        "LIVE: real Auth, protected key, encrypted service welcome and replacement registry pass"
    );

    let mut evidence = if recovering {
        let saved = protected_json("LIVE_HOSTED_EVIDENCE_FILE");
        assert_eq!(saved["integration_id"], id);
        assert_eq!(saved["host"], host);
        assert_eq!(saved["target"], json!(target));
        assert!(saved["request_id"]
            .as_str()
            .is_some_and(atem_client::session::wire::is_uuid_v4));
        assert!(saved["marker"]
            .as_str()
            .is_some_and(|m| m.starts_with("ASTATION_SERVICE_E2E_")
                || m.starts_with("Astation service check ")));
        println!("LIVE: recovery mode, queries only; the saved prompt will not be resubmitted");
        saved
    } else {
        let request = atem_client::session::new_id();
        // Long random tokens are correctly scrubbed by Atem's secret filter.
        let marker = format!(
            "Astation service check {:06} complete",
            rand::random::<u32>() % 1_000_000
        );
        let prompt = format!(
            "Reply with exactly {marker}. Do not use tools, run commands or change any files."
        );
        json!({"request_id":request,"target":target,"marker":marker,"native_clients_blocked":without_native && !existing_cluster,
            "native_absence_required":without_native,
            "phase":"prepared","integration_id":id,"host":host,"prompt":prompt})
    };
    let request = evidence["request_id"].as_str().unwrap().to_owned();
    let marker = evidence["marker"].as_str().unwrap().to_owned();
    if !recovering {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&evidence_path)
            .expect("new protected request evidence");
        use std::io::Write;
        file.write_all(serde_json::to_string_pretty(&evidence).unwrap().as_bytes())
            .unwrap();
        file.sync_all()
            .expect("request identity durable before submit");
        std::fs::File::open(evidence_path.parent().unwrap())
            .unwrap()
            .sync_all()
            .unwrap();
        authorize(&runtime, &id, raw, "agent.prompt").await;
        let (submit_id, frame) = connection
            .attached
            .submit_prompt(
                &session,
                &request,
                evidence["prompt"].as_str().unwrap(),
                connection.now(),
            )
            .expect("one prompt without takeover");
        connection
            .send(frame)
            .await
            .expect("prompt send; recover receipt on uncertainty, never resubmit");
        let response = connection
            .until(|v| v["data"]["re"] == submit_id)
            .await
            .expect("prompt outcome; recover receipt on uncertainty, never resubmit");
        assert!(
            response.iter().any(|v| v["data"]["op"] == "receipt"
                && v["data"]["request_id"] == request
                && v["data"]["target"] == json!(target)
                && matches!(
                    v["data"]["state"].as_str(),
                    Some("accepted" | "executing" | "completed")
                )),
            "host refused the prompt"
        );
        evidence["phase"] = json!("receipt_received");
        evidence["submit_reply"] = json!(response);
        save_evidence(&evidence_path, &evidence);
        println!("LIVE: prompt receipt received; closing service attachment immediately");
    }
    if let Some(path) = &failover_file {
        let old = runtime
            .app
            .relay
            .room(&target.account_id)
            .await
            .unwrap()
            .and_then(|room| room.atems.get(&host).cloned())
            .expect("current host socket");
        evidence["failover_from"] = json!({"connection":old.conn,"replica":old.replica});
        evidence["phase"] = json!("awaiting_replica_failover");
        save_evidence(&evidence_path, &evidence);
        drop(connection);
        println!(
            "LIVE: accepted request saved; awaiting operator interruption of its host replica"
        );
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        while !path.exists() {
            assert!(
                tokio::time::Instant::now() < deadline,
                "replica failover marker deadline; recover the saved receipt only"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let marker = protected_json("LIVE_HOSTED_FAILOVER_FILE");
        assert_eq!(marker["request_id"], request);
        let next = runtime
            .app
            .relay
            .room(&target.account_id)
            .await
            .unwrap()
            .and_then(|room| room.atems.get(&host).cloned())
            .expect("reconnected host socket");
        assert_ne!(next.conn, old.conn, "host must have reconnected");
        assert_ne!(
            next.replica, old.replica,
            "host must be on the other replica"
        );
        evidence["failover_to"] = json!({"connection":next.conn,"replica":next.replica});
        evidence["phase"] = json!("replica_failover_observed");
        save_evidence(&evidence_path, &evidence);
        println!(
            "LIVE: actual host socket moved to another replica; only querying the accepted request"
        );
        connection = open(&runtime, &id, raw, &host).await;
    }
    let mut query_connection = if recovering || failover_file.is_some() {
        Some(connection)
    } else {
        drop(connection);
        None
    };

    let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
    loop {
        let mut recovered = match query_connection.take() {
            Some(connection) => connection,
            None => open(&runtime, &id, raw, &host).await,
        };
        assert_eq!(recovered.attached.target(&session).as_ref(), Some(&target));
        let (query_id, frame) = recovered
            .attached
            .receipt_query(&session, &[request.clone()], recovered.now())
            .expect("receipt lookup on fresh attachment");
        recovered.send(frame).await.expect("receipt query send");
        let receipts = recovered
            .until(|v| v["data"]["re"] == query_id)
            .await
            .expect("durable receipt reply");
        let receipt = receipts
            .iter()
            .flat_map(|v| v["data"]["receipts"].as_array().into_iter().flatten())
            .find(|r| r["request_id"] == request && r["target"] == json!(target))
            .expect("same durable request and complete target after reconnect");
        assert!(
            matches!(
                receipt["state"].as_str(),
                Some("accepted" | "executing" | "completed")
            ),
            "prompt rejected or outcome unknown; preserve evidence"
        );
        let completed = receipt["state"] == "completed";
        println!(
            "LIVE: recovered same request receipt, state {}",
            receipt["state"]
        );
        evidence["recovered_receipt"] = receipt.clone();
        save_evidence(&evidence_path, &evidence);
        let messages = history(&mut recovered, &session).await;
        evidence["history_summary"] = json!(messages.iter().map(|v| {
            let data = &v["data"];
            json!({"op":data["op"],"role":data["role"],"messageId":data["messageId"],
                "keys":data.as_object().map(|o| o.keys().collect::<Vec<_>>()),
                "parts":data["parts"].as_array().map(|parts| parts.iter().map(|p| json!({
                    "kind":p["kind"],"keys":p.as_object().map(|o| o.keys().collect::<Vec<_>>()),
                    "markdown_type":match &p["markdown"] { Value::String(_) => "string", Value::Object(_) => "object", Value::Null => "null", _ => "other" },
                    "markdown_length":p["markdown"].as_str().map(str::len),
                    "marker_in_markdown":p["markdown"].as_str().is_some_and(|s| s.contains(&marker)),
                    "marker_in_text":p["text"].as_str().is_some_and(|s| s.contains(&marker))
                })).collect::<Vec<_>>())})
        }).collect::<Vec<_>>());
        evidence["correlated_messages"] = json!(messages
            .iter()
            .filter(|v| v["data"]["op"] == "message" && v["data"]["requestId"] == request)
            .collect::<Vec<_>>());
        save_evidence(&evidence_path, &evidence);
        let reply_ids = receipt["result"]["reply_message_ids"].as_array();
        let found = messages.iter().any(|v| {
            v["data"]["op"] == "message"
                && v["data"]["role"] == "assistant"
                && reply_ids.is_some_and(|ids| ids.contains(&v["data"]["messageId"]))
                && v["data"]["parts"].as_array().is_some_and(|parts| {
                    parts.iter().any(|p| {
                        [p["markdown"].as_str(), p["text"].as_str()]
                            .into_iter()
                            .flatten()
                            .any(|text| text.contains(&marker))
                    })
                })
        });
        if found && completed {
            evidence["phase"] = json!("completed_after_reconnect");
            evidence["response_marker_matches"] = json!(true);
            save_evidence(&evidence_path, &evidence);
            println!("LIVE: actual Codex response marker present in ordered history after disconnect/reconnect");
            break;
        }
        let all_replies_retained = reply_ids.is_some_and(|ids| {
            !ids.is_empty()
                && ids.iter().all(|id| {
                    messages
                        .iter()
                        .any(|v| v["data"]["op"] == "message" && &v["data"]["messageId"] == id)
                })
        });
        assert!(!(completed && all_replies_retained),
            "completed receipt's retained replies do not match the submitted marker; inspect protected correlated evidence");
        assert!(
            tokio::time::Instant::now() < deadline,
            "real agent response not observed; keep request evidence for recovery"
        );
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    assert!(!super::HOSTED_EXECUTION_ENABLED);
    if without_native {
        assert!(runtime
            .app
            .relay
            .room(&target.account_id)
            .await
            .unwrap()
            .is_none_or(|r| r.owner.is_none()));
        println!("LIVE: completed prompt and recovered response with native clients unavailable");
    }
    println!("LIVE: protected service smoke passed; public release gate still closed");
    if let Some(server) = server {
        server.abort();
    }
    if let Some(cluster) = cluster {
        cluster.relay.drain(Duration::from_secs(1)).await;
        cluster.abort();
        println!("LIVE: service round trip crossed the existing replica bus; observer withdrawn");
    }
}
