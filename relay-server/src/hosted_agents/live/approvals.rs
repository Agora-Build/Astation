//! Genuine, explicitly selected disposable Codex cases from Atem #81.
use super::{authorize, history, open, protected_json, save_evidence, HostedConnection};
use crate::station_integrations::StationIntegrations;
use atem_client::session::{new_id, wire::ReceiptKind};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn append(evidence: &mut Value, key: &str, values: Vec<Value>) {
    evidence[key].as_array_mut().unwrap().extend(values);
}

async fn query(
    connection: &mut HostedConnection,
    session: &str,
    requests: &[String],
) -> Vec<Value> {
    let (id, frame) = connection
        .attached
        .receipt_query(session, requests, connection.now())
        .expect("receipt query");
    connection
        .send(frame)
        .await
        .expect("read-only receipt delivery");
    connection
        .until(|v| v["data"]["re"] == id)
        .await
        .expect("receipt reply")
}

fn receipt_completed(events: &[Value], request: &str, target: &Value) -> bool {
    events
        .iter()
        .flat_map(|v| v["data"]["receipts"].as_array().into_iter().flatten())
        .any(|r| r["request_id"] == request && &r["target"] == target && r["state"] == "completed")
}

fn new_auto_cards(
    events: &[Value],
    old: &[Value],
    rule: &str,
    request: &str,
    turn: Option<&str>,
) -> bool {
    events.iter().any(|v| {
        v["data"]["op"] == "message"
            && (v["data"]["requestId"] == request || turn.is_some_and(|t| v["data"]["turnId"] == t))
            && !old
                .iter()
                .any(|before| before["data"]["messageId"] == v["data"]["messageId"])
            && v["data"]["parts"].as_array().is_some_and(|parts| {
                parts.iter().any(|p| {
                    p["kind"] == "approval" && p["state"] == "auto_allowed" && p["rule_id"] == rule
                })
            })
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn run(
    runtime: &StationIntegrations,
    id: &str,
    raw: &str,
    host: &str,
    session: &str,
    mut connection: HostedConnection,
    path: &Path,
    case: &str,
    recovering: bool,
) {
    assert!(matches!(
        case,
        "allow_once" | "deny" | "allow_always" | "auto_allow" | "revoke" | "after_revoke"
    ));
    let target = connection
        .attached
        .target(session)
        .expect("current test target");
    let resuming = std::env::var("LIVE_HOSTED_APPROVAL_RESUME").as_deref() == Ok("pending");
    let mut evidence = if recovering || resuming {
        let saved = protected_json("LIVE_HOSTED_EVIDENCE_FILE");
        assert_eq!(saved["target"], json!(target));
        assert_eq!(saved["case"], case);
        assert_eq!(saved["integration_id"], id);
        saved
    } else {
        assert!(
            !path.exists(),
            "existing evidence must be recovered, never resubmitted"
        );
        json!({"case":case,"target":target,"integration_id":id,"phase":"prepared",
            "requests":[],"events":[],"started_at":chrono::Utc::now().timestamp_millis()})
    };
    if recovering {
        let requests: Vec<String> = evidence["requests"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["request_id"].as_str().unwrap().to_owned())
            .collect();
        let receipts = query(&mut connection, session, &requests).await;
        evidence["recovery_receipts"] = json!(receipts);
        evidence["pending"] = json!(connection
            .attached
            .registry()
            .pending_approvals()
            .collect::<Vec<_>>());
        evidence["recovery_history"] = json!(history(&mut connection, session).await);
        save_evidence(path, &evidence);
        println!(
            "LIVE: approval recovery queried saved requests only; no prompt or answer replayed"
        );
        return;
    }
    assert!(
        resuming
            || !connection
                .attached
                .registry()
                .pending_approvals()
                .any(|a| a.session_id == session),
        "a previous approval is pending; inspect it before another test"
    );
    let initial_history = history(&mut connection, session).await;
    let initial_rules = connection
        .initial_rules
        .iter()
        .rev()
        .find(|v| v["session_id"] == session)
        .map(|v| v["rules"].clone())
        .unwrap_or_else(|| json!([]));
    evidence["initial_rules"] = initial_rules.clone();
    let rule = if matches!(case, "auto_allow" | "revoke" | "after_revoke") {
        let saved = protected_json("LIVE_HOSTED_APPROVAL_RULE_FILE");
        assert_eq!(saved["target"], json!(target));
        Some(
            saved["rule_id"]
                .as_str()
                .expect("saved offered rule")
                .to_owned(),
        )
    } else {
        None
    };
    let file = match case {
        "allow_once" => "allow-once.txt",
        "deny" => "denied.txt",
        _ => "always.txt",
    };
    let command = format!("touch /home/guohai/atem-r9-testhost/probe/{file}");
    let request = if resuming {
        assert_eq!(
            evidence["requests"].as_array().unwrap().len(),
            1,
            "an answer was already prepared: query receipts instead of repeating it"
        );
        assert_eq!(evidence["requests"][0]["kind"], "prompt");
        assert!(
            connection
                .attached
                .registry()
                .pending_approvals()
                .any(|a| json!(a) == evidence["approval"]),
            "saved approval is no longer pending; do not answer it"
        );
        evidence["requests"][0]["request_id"]
            .as_str()
            .unwrap()
            .to_owned()
    } else {
        new_id()
    };
    if !resuming {
        let (wire_id, frame) = if case == "revoke" {
            authorize(runtime, id, raw, "agent.approve").await;
            evidence["requests"] =
                json!([{"request_id":request,"kind":"approval_rule_revoke","rule_id":rule}]);
            connection
                .attached
                .submit(
                    session,
                    ReceiptKind::ApprovalRuleRevoke,
                    &request,
                    json!({"rule_id":rule}),
                    connection.now(),
                )
                .expect("lease-free rule revoke")
        } else {
            authorize(runtime, id, raw, "agent.prompt").await;
            let prompt = if matches!(case, "allow_always" | "auto_allow" | "after_revoke") {
                format!("Run exactly this shell command, unchanged: {command} . Do nothing else.")
            } else {
                format!("Run the shell command: {command} . Do nothing else.")
            };
            evidence["requests"] = json!([{"request_id":request,"kind":"prompt","text":prompt}]);
            connection
                .attached
                .submit_prompt(session, &request, &prompt, connection.now())
                .expect("one explicit test prompt, no takeover")
        };
        save_evidence(path, &evidence);
        connection
            .send(frame)
            .await
            .expect("mutation delivery uncertain: recover saved receipts only");
        let reply = connection
            .until(|v| v["data"]["re"] == wire_id)
            .await
            .expect("initial reply uncertain: recover saved receipts only");
        assert!(
            reply.iter().any(|v| v["data"]["op"] == "receipt"
                && v["data"]["request_id"] == request
                && v["data"]["target"] == json!(target)
                && matches!(
                    v["data"]["state"].as_str(),
                    Some("accepted" | "executing" | "completed")
                )),
            "host refused test request"
        );
        append(&mut evidence, "events", reply);
        evidence["phase"] = json!("submitted");
        save_evidence(path, &evidence);
    }
    // Approval answers and rule revocation must work without taking a lease.
    if connection
        .attached
        .binding(session, connection.now())
        .is_some_and(|b| b.lease_epoch.is_some())
    {
        let (release, frame) = connection
            .attached
            .release(session, connection.now())
            .unwrap();
        connection.send(frame).await.expect("explicit release");
        let reply = connection
            .until(|v| v["data"]["re"] == release)
            .await
            .unwrap();
        append(&mut evidence, "events", reply);
    }
    let mut requests = vec![request.clone()];
    if !matches!(case, "auto_allow" | "revoke") {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
        loop {
            if connection
                .attached
                .registry()
                .pending_approvals()
                .any(|a| a.session_id == session)
            {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "no genuine approval; inspect saved evidence"
            );
            let reply = connection
                .receive()
                .await
                .expect("approval stream interrupted; recover without resubmitting");
            append(&mut evidence, "events", reply);
            save_evidence(path, &evidence);
            assert!(!evidence["events"].as_array().unwrap().iter().any(|v|
                v["data"]["op"] == "receipt" && v["data"]["request_id"] == request
                && matches!(v["data"]["state"].as_str(),Some("rejected"|"outcome_unknown"|"completed"))),
                "turn ended without a genuine pending approval; inspect the saved receipt/history before continuing");
        }
        let pending = connection
            .attached
            .registry()
            .pending_approvals()
            .filter(|a| a.session_id == session)
            .cloned()
            .collect::<Vec<_>>();
        assert_eq!(pending.len(), 1, "answer only the exact test approval");
        let approval = pending[0].clone();
        evidence["approval"] = json!(approval);
        evidence["phase"] = json!("approval_pending");
        save_evidence(path, &evidence);
        assert_eq!(approval.process_gen, target.process_gen);
        let summary = approval.summary.trim();
        assert!(
            summary == command || summary == format!("{command} ."),
            "approval is not the exact harmless probe command; inspect protected evidence"
        );
        println!("LIVE: genuine Codex approval pending for case {case}");
        if case == "allow_once" {
            drop(connection);
            tokio::time::sleep(Duration::from_secs(2)).await;
            connection = open(runtime, id, raw, host).await;
            let caught_up = connection
                .attached
                .registry()
                .pending_approvals()
                .filter(|a| a.session_id == session)
                .cloned()
                .collect::<Vec<_>>();
            assert_eq!(
                caught_up, pending,
                "reconnect preserves exactly one same pending approval"
            );
            evidence["pending_after_reconnect"] = json!(caught_up);
            println!("LIVE: reconnect catch-up retained the same genuine approval exactly once");
        }
        let decision = match case {
            "deny" | "after_revoke" => "deny",
            "allow_always" => "allow_always",
            _ => "allow_once",
        };
        let mut payload = json!({"approval_id":approval.approval_id,"decision":decision});
        if case == "allow_always" {
            assert_eq!(
                approval.always_rules.len(),
                1,
                "use only the offered exact session rule"
            );
            let offered = &approval.always_rules[0];
            assert_eq!(offered.scope, "session");
            payload["rule_id"] = json!(offered.rule_id);
            evidence["offered_rule"] = json!(offered);
        }
        if decision == "deny" {
            payload["message"] = json!("Denied by the explicit Astation disposable approval test.");
        }
        let answer = new_id();
        evidence["requests"]
            .as_array_mut()
            .unwrap()
            .push(json!({"request_id":answer,"kind":"approval","payload":payload}));
        save_evidence(path, &evidence);
        authorize(runtime, id, raw, "agent.approve").await;
        let controller = connection
            .attached
            .registry()
            .session(session)
            .unwrap()
            .controller
            .clone();
        let (answer_id, frame) = connection
            .attached
            .submit(
                session,
                ReceiptKind::Approval,
                &answer,
                payload,
                connection.now(),
            )
            .expect("lease-free answer from service with control permission");
        connection
            .send(frame)
            .await
            .expect("answer outcome uncertain: query receipt, never answer again");
        let reply = connection
            .until(|v| v["data"]["re"] == answer_id)
            .await
            .expect("answer reply uncertain: query receipt, never answer again");
        assert!(
            reply.iter().any(|v| v["data"]["op"] == "receipt"
                && v["data"]["request_id"] == answer
                && matches!(
                    v["data"]["state"].as_str(),
                    Some("accepted" | "executing" | "completed")
                )),
            "answer refused"
        );
        assert_eq!(
            connection
                .attached
                .registry()
                .session(session)
                .unwrap()
                .controller,
            controller,
            "answer must not change controller"
        );
        append(&mut evidence, "events", reply);
        requests.push(answer);
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(100);
    loop {
        authorize(runtime, id, raw, "agent.view").await;
        let receipts = query(&mut connection, session, &requests).await;
        let completed = requests
            .iter()
            .all(|r| receipt_completed(&receipts, r, &json!(target)));
        evidence["receipts"] = json!(receipts);
        evidence["pending"] = json!(connection
            .attached
            .registry()
            .pending_approvals()
            .collect::<Vec<_>>());
        append(&mut evidence, "events", receipts);
        save_evidence(path, &evidence);
        if completed {
            break;
        }
        assert!(
            !connection
                .attached
                .registry()
                .pending_approvals()
                .any(|a| a.session_id == session),
            "an unexpected further approval needs explicit inspection; no automatic answer"
        );
        assert!(
            tokio::time::Instant::now() < deadline,
            "turn not complete: preserve and query receipts only"
        );
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    let final_history = history(&mut connection, session).await;
    append(&mut evidence, "events", final_history.clone());
    assert!(
        !connection
            .attached
            .registry()
            .pending_approvals()
            .any(|a| a.session_id == session),
        "card must close"
    );
    if case == "auto_allow" {
        let turn = evidence["receipts"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|v| v["data"]["receipts"].as_array().into_iter().flatten())
            .find(|r| r["request_id"] == request)
            .and_then(|r| r["result"]["turn_id"].as_str());
        assert!(new_auto_cards(&final_history,&initial_history,rule.as_deref().unwrap(),&request,turn),
            "no new auto_allowed card for exact rule; inspect generated command before a deliberate retry");
    }
    if case == "allow_always" {
        let offered = evidence["offered_rule"].clone();
        assert!(
            evidence["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["data"]["op"] == "approval_rules"
                    && v["data"]["session_id"] == session
                    && v["data"]["rules"]
                        .as_array()
                        .is_some_and(|rules| rules.contains(&offered))),
            "active session rule not observed"
        );
        save_evidence(
            Path::new(&super::required("LIVE_HOSTED_APPROVAL_RULE_FILE")),
            &json!({"target":target,"rule_id":offered["rule_id"],"rule":offered}),
        );
    }
    if case == "revoke" {
        let expected: Vec<Value> = initial_rules
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["rule_id"].as_str() != rule.as_deref())
            .cloned()
            .collect();
        assert!(
            evidence["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["data"]["op"] == "approval_rules"
                    && v["data"]["session_id"] == session
                    && v["data"]["rules"] == json!(expected)),
            "specific rule removal preserving unrelated rules not observed"
        );
    }
    evidence["phase"] = json!("completed");
    evidence["pending_after"] = json!([]);
    save_evidence(path, &evidence);
    println!("LIVE: genuine Codex approval case {case} completed; exact receipts and cards retained privately");
}

#[test]
fn auto_allow_evidence_requires_the_current_turn_and_a_new_message() {
    let card = json!({"data":{"op":"message","messageId":"new-card","requestId":"this-request",
        "parts":[{"kind":"approval","state":"auto_allowed","rule_id":"offered-rule"}]}});
    assert!(new_auto_cards(
        &[card.clone()],
        &[],
        "offered-rule",
        "this-request",
        None
    ));
    assert!(!new_auto_cards(
        &[card.clone()],
        &[],
        "offered-rule",
        "different-request",
        None
    ));
    assert!(!new_auto_cards(
        &[card.clone()],
        &[card],
        "offered-rule",
        "this-request",
        None
    ));
}
