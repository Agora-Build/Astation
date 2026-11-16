//! Account-private native carriage. Only a current manager's signature can
//! publish a control record; these endpoints never accept host ACK evidence.
use super::{
    delegated::{Command, OwnerCommand},
    error, read, subject, Reply,
};
use crate::AppState;
use atem_client::{
    canonical::StrictValue,
    control::{ControlPrincipal, ControlRecord, ToStation},
    membership::Head,
};
use axum::{
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
};

async fn access(state: &AppState, headers: &HeaderMap) -> Result<String, Reply> {
    let owner = subject(state, headers).await?;
    if !state.recovery.delegated_enabled() {
        return Err(error(
            StatusCode::SERVICE_UNAVAILABLE,
            "delegated_host_work_not_verified",
        ));
    }
    Ok(owner)
}

fn invalid() -> Reply {
    error(StatusCode::BAD_REQUEST, "invalid_control_request")
}

fn fields(value: &StrictValue, keys: &[&str]) -> bool {
    value.value().as_object().is_some_and(|object| {
        object.len() == keys.len() && keys.iter().all(|key| object.contains_key(*key))
    })
}

pub(crate) async fn heads(
    State(state): State<AppState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
) -> Reply {
    let owner = match access(&state, &headers).await {
        Ok(owner) => owner,
        Err(reply) => return reply,
    };
    state
        .recovery
        .delegated_operation(&genesis, &owner, Command::Owner(OwnerCommand::Heads))
        .await
}

pub(crate) async fn sync(
    State(state): State<AppState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let owner = match access(&state, &headers).await {
        Ok(owner) => owner,
        Err(reply) => return reply,
    };
    let value = match read(body).await {
        Ok(value) => value,
        Err(reply) => return reply,
    };
    let Ok(ToStation::ControlSync(call)) = ToStation::decode(value.value().to_string().as_bytes())
    else {
        return invalid();
    };
    state
        .recovery
        .delegated_operation(&genesis, &owner, Command::Owner(OwnerCommand::Sync(call)))
        .await
}

pub(crate) async fn reserve(
    State(state): State<AppState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let owner = match access(&state, &headers).await {
        Ok(owner) => owner,
        Err(reply) => return reply,
    };
    let value = match read(body).await {
        Ok(value) => value,
        Err(reply) => return reply,
    };
    if !fields(&value, &["principal", "manager", "expected"]) {
        return invalid();
    }
    let parsed = (|| {
        Some((
            ControlPrincipal::parse(value.value()["principal"].as_str()?)?,
            value.value()["manager"].as_str()?.to_owned(),
            Head::from_json(&value.value()["expected"])?,
        ))
    })();
    let Some((principal, manager, expected)) = parsed else {
        return invalid();
    };
    state
        .recovery
        .delegated_operation(
            &genesis,
            &owner,
            Command::Owner(OwnerCommand::Reserve {
                principal,
                manager,
                expected,
            }),
        )
        .await
}

pub(crate) async fn publish(
    State(state): State<AppState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Reply {
    let owner = match access(&state, &headers).await {
        Ok(owner) => owner,
        Err(reply) => return reply,
    };
    let value = match read(body).await {
        Ok(value) => value,
        Err(reply) => return reply,
    };
    if !fields(&value, &["record", "expected"]) {
        return invalid();
    }
    let parsed = (|| {
        Some((
            ControlRecord::parse(value.get("record")?.value().to_string().as_bytes()).ok()?,
            Head::from_json(&value.value()["expected"])?,
        ))
    })();
    let Some((record, expected)) = parsed else {
        return invalid();
    };
    state
        .recovery
        .delegated_operation(
            &genesis,
            &owner,
            Command::Owner(OwnerCommand::Publish { record, expected }),
        )
        .await
}

#[cfg(all(test, feature = "delegated-host-work"))]
mod tests {
    use super::*;
    use atem_client::{
        control::{
            build_control, principal_key_of, ControlAbout, ControlAction, ControlBody, ControlFeed,
            ControlPrincipal, ControlSigner, ToHost,
        },
        KeyId, KeyProvider,
    };
    use axum::{body::to_bytes, http::Request};
    use serde_json::{json, Value};
    use tower::ServiceExt;

    const ORIGIN: &str = "https://station-dev.agora.build";

    async fn app(enabled: bool) -> (AppState, crate::remote_api::push_ingress::tests::Fixture) {
        let mut app = crate::tests::test_state();
        app.recovery = super::super::RecoveryStore::memory();
        app.accounts =
            std::sync::Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
                app.knowledge.clone(),
                app.vault.clone(),
                std::sync::Arc::new(super::super::tests::TestAccountVerifier),
            ));
        if enabled {
            app.recovery.configure_delegated(ORIGIN, 1).await.unwrap();
        }
        let f = super::super::delegated::tests::fixture();
        f.publish(&app.recovery).await;
        (app, f)
    }

    async fn http(
        app: &AppState,
        genesis: &str,
        path: &str,
        owner: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut request = Request::builder()
            .method(if body.is_some() { "POST" } else { "GET" })
            .uri(format!("/api/remote/v1/logs/{genesis}/control{path}"))
            .extension(axum::extract::ConnectInfo(
                "127.0.0.1:40001".parse::<std::net::SocketAddr>().unwrap(),
            ));
        if let Some(owner) = owner {
            request = request.header("authorization", format!("Bearer {owner}"));
        }
        let response = crate::router(app.clone())
            .oneshot(
                request
                    .header("content-type", "application/json")
                    .body(Body::from(body.map(|v| v.to_string()).unwrap_or_default()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.headers()["cache-control"], "no-store");
        let code = response.status();
        let value = serde_json::from_slice(&to_bytes(response.into_body(), 262_144).await.unwrap())
            .unwrap();
        (code, value)
    }

    #[tokio::test]
    async fn delegated_native_http_gates_storage_and_cannot_submit_host_evidence() {
        let (app, f) = app(false).await;
        let genesis = f.log.genesis_hash().to_hex();
        assert_eq!(
            http(&app, &genesis, "", None, None).await.0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            http(&app, &genesis, "", Some("alice"), None).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        app.recovery.configure_delegated(ORIGIN, 1).await.unwrap();
        assert_eq!(
            http(&app, &genesis, "", Some("mallory"), None).await.0,
            StatusCode::NOT_FOUND
        );
        let (status, heads) = http(&app, &genesis, "", Some("alice"), None).await;
        assert_eq!(status, StatusCode::OK);
        assert!(matches!(
            ToHost::decode(heads.to_string().as_bytes()).unwrap(),
            ToHost::Heads(_)
        ));
        let call = json!({"type":"relay","op":"control_sync", "origin":ORIGIN,
            "request_id":uuid::Uuid::new_v4().to_string(),"feed_id":heads["feeds"][0]["feed_id"],"after":0});
        let (status, result) =
            http(&app, &genesis, "/sync", Some("alice"), Some(call.clone())).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(result["request_id"], call["request_id"]);
        assert_eq!(result["records"], json!([]));
        for op in ["control_ack", "membership_fetch"] {
            assert_eq!(
                http(
                    &app,
                    &genesis,
                    "/sync",
                    Some("alice"),
                    Some(json!({"type":"relay","op":op,"after":0}))
                )
                .await
                .0,
                StatusCode::BAD_REQUEST
            );
        }
    }

    #[tokio::test]
    async fn delegated_native_http_requires_current_manager_signature_and_exact_reviewed_head() {
        let (app, mut f) = app(true).await;
        let genesis = f.log.genesis_hash().to_hex();
        let heads = http(&app, &genesis, "", Some("alice"), None).await.1;
        let reserve = json!({"principal":"service:svc-test","manager":"phone","expected":f.log.head().to_json()});
        let (status, reserved) = http(
            &app,
            &genesis,
            "/reservations",
            Some("alice"),
            Some(reserve.clone()),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let second = http(
            &app,
            &genesis,
            "/reservations",
            Some("alice"),
            Some(reserve.clone()),
        )
        .await
        .1;
        assert!(second["issued_at"].as_u64().unwrap() > reserved["issued_at"].as_u64().unwrap());
        for (field, value) in [
            ("manager", json!("missing")),
            ("principal", json!("service:missing")),
            ("expected", json!({"seq":1,"hash":"0".repeat(64)})),
        ] {
            let mut invalid = reserve.clone();
            invalid[field] = value;
            assert_eq!(
                http(
                    &app,
                    &genesis,
                    "/reservations",
                    Some("alice"),
                    Some(invalid)
                )
                .await
                .0,
                StatusCode::BAD_REQUEST
            );
        }
        let mut body = ControlBody {
            account_id: f.log.account_id().into(),
            genesis_hash: f.log.genesis_hash(),
            feed: Some(ControlFeed {
                origin: ORIGIN.into(),
                feed_id: heads["feeds"][0]["feed_id"].as_str().unwrap().into(),
            }),
            principal: ControlPrincipal::Service("svc-test".into()),
            principal_key: Some(
                principal_key_of(&f.keys.public_key(&KeyId::new("service")).unwrap()).unwrap(),
            ),
            signer: ControlSigner::Principal,
            action: ControlAction::Revoke {
                interrupt_running: false,
            },
            record_id: uuid::Uuid::new_v4().to_string(),
            issued_at: reserved["issued_at"].as_u64().unwrap(),
            about: ControlAbout {
                integration_id: Some("i-01234567890123456789012345".into()),
                by: "owner".into(),
            },
        };
        let signed_service = build_control(&f.keys, &KeyId::new("service"), &body).unwrap();
        let request = |record: Value| json!({"record":record,"expected":f.log.head().to_json()});
        assert_eq!(
            http(
                &app,
                &genesis,
                "/records",
                Some("alice"),
                Some(request(signed_service.to_json()))
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
        body.signer = ControlSigner::Member("phone".into());
        let signed = build_control(&f.keys, &KeyId::new("manager"), &body).unwrap();
        let mut forged = signed.to_json();
        forged["body"]["interrupt_running"] = json!(true);
        assert_eq!(
            http(
                &app,
                &genesis,
                "/records",
                Some("alice"),
                Some(request(forged))
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
        let mut wrong_head = request(signed.to_json());
        wrong_head["expected"]["seq"] = json!(1);
        assert_eq!(
            http(&app, &genesis, "/records", Some("alice"), Some(wrong_head))
                .await
                .0,
            StatusCode::BAD_REQUEST
        );
        for appended in [true, false] {
            let (status, result) = http(
                &app,
                &genesis,
                "/records",
                Some("alice"),
                Some(request(signed.to_json())),
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(
                result,
                json!({"appended":appended,"record_id":body.record_id})
            );
        }
        body.action = ControlAction::Revoke {
            interrupt_running: true,
        };
        let conflict = build_control(&f.keys, &KeyId::new("manager"), &body).unwrap();
        assert_eq!(
            http(
                &app,
                &genesis,
                "/records",
                Some("alice"),
                Some(request(conflict.to_json()))
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            http(&app, &genesis, "", Some("alice"), None).await.1["feeds"][0]["head"],
            1
        );
        // A new manager replaces the old one; a valid old signature cannot be
        // published even when its caller supplies the new head.
        f.keys.insert_ed25519(KeyId::new("next"), &[23; 32]);
        let mut next_member = f.log.member("phone").unwrap().member.clone();
        next_member.device_id = "next".into();
        next_member.auth_key = f.keys.public_key(&KeyId::new("next")).unwrap();
        let add = atem_client::membership::sign_entry(
            &f.keys,
            &KeyId::new("manager"),
            f.log.draft(
                "phone",
                f.created,
                &atem_client::membership::Action::Add {
                    member: next_member,
                },
            ),
        )
        .unwrap();
        assert_eq!(
            app.recovery
                .append_test_entry(&genesis, "alice", add, f.log.head())
                .await,
            StatusCode::OK
        );
        let log = app
            .recovery
            .integration_log(&genesis, "alice")
            .await
            .unwrap();
        let remove = atem_client::membership::sign_entry(
            &f.keys,
            &KeyId::new("next"),
            log.draft(
                "next",
                f.created,
                &atem_client::membership::Action::Remove {
                    device_id: "phone".into(),
                },
            ),
        )
        .unwrap();
        assert_eq!(
            app.recovery
                .append_test_entry(&genesis, "alice", remove, log.head())
                .await,
            StatusCode::OK
        );
        let current = app
            .recovery
            .integration_log(&genesis, "alice")
            .await
            .unwrap();
        let stale = json!({"record":signed.to_json(),"expected":current.head().to_json()});
        assert_eq!(
            http(&app, &genesis, "/records", Some("alice"), Some(stale))
                .await
                .0,
            StatusCode::BAD_REQUEST
        );
    }
}
