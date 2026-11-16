use super::*;
use crate::{
    relay::tests::{
        connect_astation, connect_atem, next_client_json, send_json, spawn_relay, TestKey,
        TestSocket,
    },
    remote_api::{host_route_tests, push_ingress::tests::Fixture, recovery::RecoveryStore},
};
use atem_client::{
    control::{ControlSync, ToHost},
    host_route::{host_route_message, sign_host_route_as, HostChallenge, HostRouteBody, RouteKind},
};
use serde_json::json;
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message as ClientMessage};

const ORIGIN: &str = "https://station-dev.agora.build";

struct Test {
    state: AppState,
    fixture: Fixture,
    key: TestKey,
    base: String,
    server: tokio::task::JoinHandle<()>,
    native: TestSocket,
}

impl Drop for Test {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl Test {
    async fn new() -> Self {
        let mut state = crate::tests::test_state();
        state.recovery = RecoveryStore::memory();
        state.recovery.configure_delegated(ORIGIN, 1).await.unwrap();
        let fixture = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
        fixture.publish(&state.recovery).await;
        state.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
            state.knowledge.clone(),
            state.vault.clone(),
            Arc::new(crate::remote_api::recovery::tests::TestAccountVerifier),
        ));
        state
            .accounts
            .register("phone", "alice", "Native", chrono::Utc::now().timestamp())
            .await
            .unwrap();
        state
            .identity
            .bind("paired-session", "phone", chrono::Utc::now().timestamp())
            .await
            .unwrap();
        let key = TestKey::generate();
        state
            .identity
            .register_key_if_absent("phone", &key.public_hex(), chrono::Utc::now().timestamp())
            .await
            .unwrap();
        let (base, server) = spawn_relay(state.clone()).await;
        let (mut native, challenge) = connect_astation(&base, "phone").await;
        send_json(&mut native, key.relay_auth(&challenge, "phone")).await;
        assert_eq!(next_client_json(&mut native).await["status"], "verified");
        Self {
            state,
            fixture,
            key,
            base,
            server,
            native,
        }
    }

    fn request(
        &self,
        token: Option<&str>,
        session: &str,
    ) -> tokio_tungstenite::tungstenite::http::Request<()> {
        let mut request = format!(
            "{}/proxy?room=phone&atem_id=host-a&session_id={session}&generation={}",
            self.base,
            Uuid::new_v4()
        )
        .into_client_request()
        .unwrap();
        if let Some(token) = token {
            request
                .headers_mut()
                .insert("Authorization", format!("Bearer {token}").parse().unwrap());
        }
        request
    }

    async fn proxy(&self, kind: RouteKind) -> TestSocket {
        let (mut socket, _) =
            tokio_tungstenite::connect_async(self.request(Some("alice"), "paired-session"))
                .await
                .unwrap();
        let challenge = next_client_json(&mut socket).await;
        assert_eq!(challenge["type"], "relayAuthChallenge");
        send_json(
            &mut socket,
            self.key
                .relay_auth(challenge["challenge"].as_str().unwrap(), "phone"),
        )
        .await;
        assert_eq!(next_client_json(&mut socket).await["status"], "verified");
        let challenge =
            HostChallenge::parse(next_client_json(&mut socket).await.to_string().as_bytes())
                .unwrap();
        let object = sign_host_route_as(
            kind,
            &self.fixture.keys,
            &self.fixture.host_key,
            &HostRouteBody::at(&self.fixture.log, "host-a", "host-a", &challenge),
        )
        .unwrap();
        send_json(&mut socket, host_route_message(&object)).await;
        socket
    }
}

#[tokio::test]
async fn native_proxy_requires_current_account_pairing_and_registered_native_key() {
    let t = Test::new().await;
    for request in [
        t.request(None, "paired-session"),
        t.request(Some("mallory"), "paired-session"),
        t.request(Some("alice"), "unbound-session"),
    ] {
        assert!(tokio_tungstenite::connect_async(request).await.is_err());
    }
    let (mut socket, _) =
        tokio_tungstenite::connect_async(t.request(Some("alice"), "paired-session"))
            .await
            .unwrap();
    let challenge = next_client_json(&mut socket).await;
    send_json(
        &mut socket,
        TestKey::generate().relay_auth(challenge["challenge"].as_str().unwrap(), "phone"),
    )
    .await;
    assert!(matches!(
        socket.next().await,
        Some(Ok(ClientMessage::Close(_))) | None
    ));
    assert!(t
        .state
        .relay
        .inner
        .proxy_authorities
        .lock()
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn proxy_proof_kind_is_mandatory_and_does_not_create_a_relay_route() {
    let t = Test::new().await;
    let mut wrong = t.proxy(RouteKind::Relay).await;
    assert_eq!(
        next_client_json(&mut wrong).await["op"],
        "host_route_refused"
    );
    assert!(t.state.relay.inner.host_routes.lock().unwrap().is_empty());
    let mut proxy = t.proxy(RouteKind::Proxy).await;
    assert_eq!(next_client_json(&mut proxy).await["op"], "host_route_ok");
    assert_eq!(next_client_json(&mut proxy).await["op"], "heads");
    assert!(t
        .state
        .relay
        .room("phone")
        .await
        .unwrap()
        .unwrap()
        .atems
        .is_empty());
}

#[tokio::test]
async fn proxy_and_real_relay_coexist_with_control_feed_and_opaque_r9_routing() {
    let mut t = Test::new().await;
    let mut relay = connect_atem(&t.base, "phone", "host-a").await;
    // The owner-present connection may announce itself before its host proof.
    let _ = next_client_json(&mut t.native).await;
    host_route_tests::prove(
        &mut relay,
        &t.fixture.keys,
        &t.fixture.host_key,
        &t.fixture.log,
        "host-a",
    )
    .await;
    let _ = next_client_json(&mut relay).await;
    let relay_connection =
        t.state.relay.room("phone").await.unwrap().unwrap().atems["host-a"].clone();
    let mut proxy = t.proxy(RouteKind::Proxy).await;
    assert_eq!(next_client_json(&mut proxy).await["op"], "host_route_ok");
    let heads = next_client_json(&mut proxy).await;
    let ToHost::Heads(heads) = ToHost::decode(heads.to_string().as_bytes()).unwrap() else {
        panic!("heads")
    };
    let call = ControlSync {
        request_id: Uuid::new_v4().to_string(),
        origin: ORIGIN.into(),
        feed_id: Some(heads.feeds[0].feed_id.clone()),
        after: 0,
    };
    send_json(&mut proxy, call.to_json().unwrap()).await;
    assert_eq!(
        next_client_json(&mut proxy).await["op"],
        "control_sync_result"
    );
    assert_eq!(
        t.state.relay.room("phone").await.unwrap().unwrap().atems["host-a"],
        relay_connection
    );
    let (_, target, _, _) = crate::remote_api::recovery::host_target(
        &t.state,
        &t.fixture.log.genesis_hash().to_hex(),
        "alice",
        "host-a",
    )
    .await
    .unwrap();
    assert_eq!(
        target, relay_connection,
        "A proxy cannot hide the live independent relay"
    );
    let binding = t
        .state
        .relay
        .inner
        .host_routes
        .lock()
        .unwrap()
        .values()
        .find(|b| b.proxy.is_some())
        .unwrap()
        .clone();
    let (handle, mut replies, _) = t
        .state
        .relay
        .channels()
        .register(
            t.state.relay.replica_id(),
            "alice",
            binding.connection.clone(),
            "phone_1",
        )
        .unwrap();
    t.state.relay.channels().bind_host(&handle, binding.clone());
    let open =
        json!({"type":"channel","event":"open","channel":handle,"transport":"relay"}).to_string();
    assert!(
        t.state
            .relay
            .deliver_channel(&binding.connection, open.clone())
            .await
    );
    assert_eq!(next_client_json(&mut proxy).await["channel"], handle);
    let opaque = format!(
        r#"{{"type":"channel","event":"frame","channel":"{handle}","frame":{{"n":1e3,"ct":"\u0061"}}}}"#
    );
    proxy.send(ClientMessage::Text(opaque)).await.unwrap();
    let reply = tokio::time::timeout(Duration::from_secs(2), replies.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(reply.text.contains(r#""n":1e3,"ct":"\u0061""#));
    assert!(reply.text.contains(r#""channel":"phone_1""#));
    // Unbinding makes queued work unusable before it can enter the socket.
    t.state
        .identity
        .unbind("paired-session", "phone")
        .await
        .unwrap();
    assert!(
        !t.state
            .relay
            .deliver_channel(&binding.connection, open)
            .await
    );
    assert!(
        t.state
            .recovery
            .with_host_route(&binding, || async { () })
            .await
            .is_some(),
        "the native guard fences traffic even before asynchronous durable retirement"
    );
    assert_eq!(
        t.state.relay.room("phone").await.unwrap().unwrap().atems["host-a"],
        relay_connection
    );
}

#[tokio::test]
async fn disconnected_saved_relay_does_not_hide_a_current_local_proxy() {
    let mut t = Test::new().await;
    let mut relay = connect_atem(&t.base, "phone", "host-a").await;
    let _ = next_client_json(&mut t.native).await;
    host_route_tests::prove(
        &mut relay,
        &t.fixture.keys,
        &t.fixture.host_key,
        &t.fixture.log,
        "host-a",
    )
    .await;
    let _ = next_client_json(&mut relay).await;
    let mut proxy = t.proxy(RouteKind::Proxy).await;
    let _ = next_client_json(&mut proxy).await;
    let _ = next_client_json(&mut proxy).await;
    relay.close(None).await.unwrap();
    tokio::time::timeout(Duration::from_secs(2), async {
        while t
            .state
            .relay
            .room("phone")
            .await
            .unwrap()
            .unwrap()
            .atems
            .contains_key("host-a")
        {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let (_, target, binding, _) = crate::remote_api::recovery::host_target(
        &t.state,
        &t.fixture.log.genesis_hash().to_hex(),
        "alice",
        "host-a",
    )
    .await
    .unwrap();
    let binding = binding.unwrap();
    assert!(
        binding.proxy.is_some(),
        "The disconnected relay remains saved but is not selected"
    );
    assert_eq!(target, binding.connection);
    assert!(
        t.state
            .relay
            .deliver_channel(
                &target,
                json!({"type":"channel","event":"open","channel":"fallback_1","transport":"relay"})
                    .to_string()
            )
            .await
    );
    assert_eq!(next_client_json(&mut proxy).await["channel"], "fallback_1");
}

#[tokio::test]
async fn public_r9_websocket_routes_to_local_proxy_and_keeps_ciphertext_private_to_its_channel() {
    let t = Test::new().await;
    let mut proxy = t.proxy(RouteKind::Proxy).await;
    let _ = next_client_json(&mut proxy).await;
    let _ = next_client_json(&mut proxy).await;
    let url = t.base.replace(
        "/ws",
        &format!(
            "/api/remote/v1/channels?genesis={}&host=host-a",
            t.fixture.log.genesis_hash().to_hex()
        ),
    );
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("authorization", "Bearer mallory".parse().unwrap());
    let Err(tokio_tungstenite::tungstenite::Error::Http(response)) =
        tokio_tungstenite::connect_async(request.clone()).await
    else {
        panic!("Cross-account public route accepted");
    };
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    request
        .headers_mut()
        .insert("authorization", "Bearer alice".parse().unwrap());
    let (mut client, _) = tokio_tungstenite::connect_async(request).await.unwrap();
    send_json(
        &mut client,
        json!({"type":"channel","event":"open","channel":"mobile_1","transport":"relay"}),
    )
    .await;
    let open = next_client_json(&mut proxy).await;
    assert_eq!(open["event"], "open");
    let handle = open["channel"].as_str().unwrap();
    let reply = format!(
        r#"{{"type":"channel","event":"frame","channel":"{handle}","frame":{{"n":1e3,"ct":"\u0061"}}}}"#
    );
    proxy.send(ClientMessage::Text(reply)).await.unwrap();
    let raw = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let Some(Ok(ClientMessage::Text(text))) = client.next().await {
                break text;
            }
        }
    })
    .await
    .unwrap();
    assert!(raw.contains(r#""n":1e3,"ct":"\u0061""#));
    assert!(raw.contains(r#""channel":"mobile_1""#));
    send_json(
        &mut client,
        json!({"type":"channel","event":"close","channel":"mobile_1","reason":"closed"}),
    )
    .await;
    let close = next_client_json(&mut proxy).await;
    assert_eq!(close["channel"], handle);
    assert_eq!(close["event"], "close");
    assert!(
        t.state
            .relay
            .room("phone")
            .await
            .unwrap()
            .unwrap()
            .atems
            .is_empty(),
        "No fake relay participant was published"
    );
}

#[tokio::test]
async fn proxy_reconnect_retires_old_calls_and_refuses_cross_account_and_old_native_sessions() {
    let t = Test::new().await;
    let mut first = t.proxy(RouteKind::Proxy).await;
    let _ = next_client_json(&mut first).await;
    let _ = next_client_json(&mut first).await;
    let previous = t
        .state
        .relay
        .inner
        .host_routes
        .lock()
        .unwrap()
        .values()
        .find(|b| b.proxy.is_some())
        .unwrap()
        .clone();
    let mut second = t.proxy(RouteKind::Proxy).await;
    let _ = next_client_json(&mut second).await;
    let _ = next_client_json(&mut second).await;
    assert!(t
        .state
        .recovery
        .with_host_route(&previous, || async { panic!("stale proxy") })
        .await
        .is_none());
    let current = t
        .state
        .relay
        .inner
        .host_routes
        .lock()
        .unwrap()
        .values()
        .find(|b| b.proxy.is_some() && b.connection != previous.connection)
        .unwrap()
        .clone();
    t.state.recovery.retire_proxy(&previous).await;
    assert!(
        t.state
            .recovery
            .with_host_route(&current, || async { () })
            .await
            .is_some(),
        "old cleanup cannot retire the replacement"
    );
    let invalid = json!({"type":"relay","op":"control_sync","request_id":Uuid::new_v4().to_string(),
        "origin":"https://other.example","after":0});
    send_json(&mut second, invalid).await;
    assert_eq!(
        next_client_json(&mut second).await,
        json!({"type":"relay","op":"control_sync_refused","code":"forbidden"})
    );
    let replacement = ConnRef::new("replacement-native", t.state.relay.replica_id());
    t.state
        .relay
        .directory()
        .leave_astation("phone", &current.proxy.as_ref().unwrap().native.conn)
        .await
        .unwrap();
    let _ = t
        .state
        .relay
        .directory()
        .claim_owner(
            "phone",
            &replacement,
            "test",
            chrono::Utc::now().timestamp(),
            PendingCaps::NONE,
        )
        .await
        .unwrap();
    assert!(!t.state.relay.proxy_current(&current.connection.conn).await);
    assert!(!t.state.relay.delegated_heads(&current).await);
    let reply =
        crate::remote_api::recovery::host_target(&t.state, &current.genesis, "mallory", "host-a")
            .await;
    assert!(matches!(reply, Err((StatusCode::NOT_FOUND, _))));
}

#[tokio::test]
async fn native_proxy_writer_drops_already_queued_ciphertext_when_pairing_is_removed() {
    let t = Test::new().await;
    let mut socket = t.proxy(RouteKind::Proxy).await;
    let _ = next_client_json(&mut socket).await;
    let _ = next_client_json(&mut socket).await;
    let old = t
        .state
        .relay
        .inner
        .host_routes
        .lock()
        .unwrap()
        .values()
        .find(|b| b.proxy.is_some())
        .unwrap()
        .clone();
    let authority = t
        .state
        .relay
        .inner
        .proxy_authorities
        .lock()
        .unwrap()
        .get(&old.connection.conn)
        .unwrap()
        .clone();
    let id = "queued-native-proxy";
    let mut outbox = t
        .state
        .relay
        .local()
        .register(id, "phone", SocketRole::NativeProxy);
    let challenge = HostChallenge::new("phone");
    let proof = host_route_message(
        &sign_host_route_as(
            RouteKind::Proxy,
            &t.fixture.keys,
            &t.fixture.host_key,
            &HostRouteBody::at(&t.fixture.log, "host-a", "host-a", &challenge),
        )
        .unwrap(),
    );
    let (binding, _) = t
        .state
        .recovery
        .admit_proxy(
            &proof.to_string(),
            challenge.nonce,
            "phone",
            "host-a",
            t.state.relay.me(id),
            old.proxy.unwrap(),
            "alice",
        )
        .await
        .unwrap();
    t.state.relay.track_host_route(binding.clone());
    t.state
        .relay
        .inner
        .proxy_authorities
        .lock()
        .unwrap()
        .insert(id.into(), authority);
    let frame =
        json!({"type":"channel","event":"frame","channel":"ciphertext","frame":{"ct":"opaque"}})
            .to_string();
    assert!(
        t.state
            .relay
            .deliver_channel(&binding.connection, frame)
            .await
    );
    let queued = outbox.frames.recv().await.unwrap();
    outbox.sent(&queued);
    t.state
        .identity
        .unbind("paired-session", "phone")
        .await
        .unwrap();
    let mut sink: Vec<Message> = Vec::new();
    assert!(write_socket_frame(&mut sink, queued, Some(&t.state.relay)).await);
    assert!(
        sink.is_empty(),
        "The actual writer must recheck native authority, even after queue acceptance"
    );
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_proxy_and_relay_bindings_survive_replica_reload_and_retire_independently(
) {
    let database =
        crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let first = RecoveryStore::postgres(database.pool.clone());
    let second = RecoveryStore::postgres(database.pool.clone());
    first.configure_delegated(ORIGIN, 1).await.unwrap();
    second.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&first).await;
    let challenge = HostChallenge::new("phone");
    let (relay, _) = first
        .admit_host(
            &host_route_tests::proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a")
                .to_string(),
            challenge.nonce,
            "phone",
            "host-a",
            ConnRef::new("relay", "r1"),
        )
        .await
        .unwrap();
    let proxy = ProxyBinding {
        session: "paired-session".into(),
        generation: Uuid::new_v4().to_string(),
        native: ConnRef::new("native", "r1"),
    };
    let message = host_route_message(
        &sign_host_route_as(
            RouteKind::Proxy,
            &f.keys,
            &f.host_key,
            &HostRouteBody::at(&f.log, "host-a", "host-a", &challenge),
        )
        .unwrap(),
    )
    .to_string();
    assert!(first
        .admit_proxy(
            &message,
            challenge.nonce,
            "phone",
            "host-a",
            ConnRef::new("forged", "r1"),
            proxy.clone(),
            "mallory"
        )
        .await
        .is_err());
    let (old, _) = first
        .admit_proxy(
            &message,
            challenge.nonce,
            "phone",
            "host-a",
            ConnRef::new("proxy-old", "r1"),
            proxy.clone(),
            "alice",
        )
        .await
        .unwrap();
    assert!(second
        .with_host_route(&relay, || async { () })
        .await
        .is_some());
    assert!(second
        .with_host_route(&old, || async { () })
        .await
        .is_some());
    let (new, _) = second
        .admit_proxy(
            &message,
            challenge.nonce,
            "phone",
            "host-a",
            ConnRef::new("proxy-new", "r2"),
            proxy,
            "alice",
        )
        .await
        .unwrap();
    first.retire_proxy(&old).await;
    assert!(first.with_host_route(&old, || async { () }).await.is_none());
    assert!(first.with_host_route(&new, || async { () }).await.is_some());
    assert!(first
        .with_host_route(&relay, || async { () })
        .await
        .is_some());
    assert_eq!(
        first
            .append_test_entry(&relay.genesis, "alice", f.remove_host(), f.log.head())
            .await,
        StatusCode::OK
    );
    assert!(second
        .with_host_route(&new, || async { () })
        .await
        .is_none());
    assert!(second
        .with_host_route(&relay, || async { () })
        .await
        .is_none());
    drop(first);
    drop(second);
    database.cleanup().await;
}
