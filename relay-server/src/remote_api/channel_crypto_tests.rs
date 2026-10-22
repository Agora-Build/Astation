//! Real cryptography through the independent WebSocket, with no room-owning Mac.
use super::*;
use crate::relay::tests::{connect_atem, next_client_json, send_json, spawn_relay};
use atem_client::channel::responder::{HostContext, Responder};
use atem_client::connect::{Connector, Event, Identity};
use atem_client::membership::Admission;
use atem_client::principal::Authority;
use atem_client::session::r9::{Hello, Welcome, R9_FEATURES};
use atem_client::session::revision::KNOWN_FEATURES;
use atem_client::{KeyId, KeyProvider, SignedObject, SoftwareKeys};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

fn signed_entry(keys: &SoftwareKeys, key: &KeyId, body: Value) -> Entry {
    let signed = SignedObject::sign(keys, key, body).unwrap();
    Entry::parse_bytes(&serde_json::to_vec(&signed.to_json()).unwrap()).unwrap()
}

#[tokio::test]
async fn independent_native_verifies_host_and_exchanges_encrypted_registry_without_mac() {
    let mut keys = SoftwareKeys::new();
    let phone = KeyId::new("phone-auth");
    let host_key = KeyId::new("host-channel");
    let enc = KeyId::new("phone-push");
    let recovery = KeyId::new("recovery");
    keys.insert_p256(phone.clone(), &[1; 32]).unwrap();
    keys.insert_ed25519(host_key.clone(), &[2; 32]);
    keys.insert_x25519(enc.clone(), &[3; 32]);
    keys.insert_ed25519(recovery.clone(), &[4; 32]);
    let clock = now();
    let genesis = signed_entry(
        &keys,
        &phone,
        json!({
            "type":"atem-membership-entry", "v":1, "action":"genesis", "account_id":"account-test",
            "seq":1, "prev_hash":"0".repeat(64), "signed_at":clock.wall_ms, "signer":"phone-a",
            "member":{"device_id":"phone-a", "kind":"native", "roles":["control","manage","view"],
                "auth_key":keys.public_key(&phone).unwrap().to_json(), "enc_key":keys.public_key(&enc).unwrap().to_json()},
            "recovery_key":keys.public_key(&recovery).unwrap().to_json()
        }),
    );
    let hash = genesis.hash();
    let host_entry = signed_entry(
        &keys,
        &phone,
        json!({
            "type":"atem-membership-entry", "v":1, "action":"add_host", "account_id":"account-test",
            "genesis_hash":hash.to_hex(), "seq":2, "prev_hash":hash.to_hex(), "signed_at":clock.wall_ms,
            "signer":"phone-a", "host":{"host_id":"host-a", "host_trust_gen":1,
                "host_key":keys.public_key(&host_key).unwrap().to_json()}
        }),
    );
    let entries = [genesis, host_entry];
    let log = Membership::verify_chain("account-test", &hash, &entries, &clock)
        .unwrap()
        .membership;
    let mut state = crate::tests::test_state();
    state.accounts = Arc::new(crate::account_store::InMemoryAccountStore::with_verifier(
        state.knowledge.clone(),
        state.vault.clone(),
        Arc::new(super::tests::TestAccountVerifier),
    ));
    state.recovery = RecoveryStore::memory();
    for entry in &entries {
        let expected = Head {
            seq: entry.seq - 1,
            hash: entry.prev_hash,
        };
        assert_eq!(
            state
                .recovery
                .perform(
                    &hash.to_hex(),
                    "alice",
                    Operation::Append {
                        entry: entry.clone(),
                        expected
                    }
                )
                .await
                .0,
            StatusCode::OK
        );
    }
    state
        .relay
        .ensure_room("phone-a", "identity", chrono::Utc::now().timestamp())
        .await
        .unwrap();
    let (base, server) = spawn_relay(state).await;
    // Only the host opens the legacy routing link. No native owner is online.
    let mut host = connect_atem(&base, "phone-a", "host-a").await;
    let url = base.replace(
        "/ws",
        &format!(
            "/api/remote/v1/channels?genesis={}&host=host-a",
            hash.to_hex()
        ),
    );
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("authorization", "Bearer alice".parse().unwrap());
    let mut client = tokio_tungstenite::connect_async(request).await.unwrap().0;
    send_json(
        &mut client,
        json!({"type":"channel","event":"open","channel":"phone_1","transport":"relay"}),
    )
    .await;
    let handle = next_client_json(&mut host).await["channel"]
        .as_str()
        .unwrap()
        .to_owned();
    let context = HostContext {
        log: &log,
        host_id: "host-a",
        host_trust_gen: 1,
        provider: &keys,
        key: &host_key,
    };
    let (connecting, init) = Connector::new("host-a").start(&log, clock.mono_ms).unwrap();
    send_json(&mut client, json!({"type":"channel","event":"frame","channel":"phone_1","frame":serde_json::from_slice::<Value>(&init).unwrap()})).await;
    let routed = next_client_json(&mut host).await;
    assert_eq!(routed["channel"], handle);
    let (waiting, accept) = Responder::on_init(
        &context,
        &serde_json::to_vec(&routed["frame"]).unwrap(),
        clock.mono_ms,
    )
    .unwrap();
    send_json(&mut host, json!({"type":"channel","event":"frame","channel":handle,"frame":serde_json::from_slice::<Value>(&accept).unwrap()})).await;
    let accepted = next_client_json(&mut client).await;
    let (await_welcome, finish) = connecting
        .on_accept(
            &serde_json::to_vec(&accepted["frame"]).unwrap(),
            &log,
            &keys,
            &Identity::native("phone-a", phone),
            clock.mono_ms,
        )
        .unwrap();
    let finish_json: Value = serde_json::from_slice(&finish).unwrap();
    assert!(finish_json.get("principal").is_none());
    send_json(
        &mut client,
        json!({"type":"channel","event":"frame","channel":"phone_1","frame":finish_json}),
    )
    .await;
    let finished = next_client_json(&mut host).await;
    let opened = waiting
        .on_finish(
            &serde_json::to_vec(&finished["frame"]).unwrap(),
            clock.mono_ms,
        )
        .unwrap();
    let hello = Hello::parse(opened.hello()).unwrap();
    let membership = hello.membership.as_ref().unwrap();
    let evaluation = log.evaluate(&membership.entries, &clock);
    let Admission::Member { state, .. } = evaluation.admission("phone-a", membership.more, &clock)
    else {
        panic!("not admitted");
    };
    let authority = Authority::of_member(
        &hello.proof.principal,
        &state.member,
        "host-a",
        clock.wall_ms,
    )
    .unwrap();
    let mut host_channel = opened
        .key(&hello.proof)
        .admit(&authority.key, authority.channel_deadline_ms(&clock))
        .unwrap();
    let runtime = uuid::Uuid::new_v4().to_string();
    let welcome = Welcome {
        id: uuid::Uuid::new_v4().to_string(),
        re: hello.id,
        account_id: log.account_id().into(),
        atem_device_id: "host-a".into(),
        host_trust_gen: 1,
        runtime_gen: runtime.clone(),
        controller_session: uuid::Uuid::new_v4().to_string(),
        attachment_gen: uuid::Uuid::new_v4().to_string(),
        client_kind: authority.client_kind,
        permissions: authority.permissions.iter().copied().collect(),
        authorization_ms_left: 86_400_000,
        server_time: clock.wall_ms,
        revision: 9,
        features: KNOWN_FEATURES
            .iter()
            .chain(R9_FEATURES.iter())
            .map(|s| s.to_string())
            .collect(),
        principal: authority.name(),
        scope: authority.scope,
        head: log.head(),
        pending_recovery: vec![],
        channel_id: host_channel.channel_id().to_owned(),
    };
    let record = host_channel
        .seal(&welcome.to_bytes(), clock.mono_ms)
        .unwrap();
    send_json(&mut host, json!({"type":"channel","event":"frame","channel":handle,"frame":serde_json::from_slice::<Value>(&record).unwrap()})).await;
    let welcomed = next_client_json(&mut client).await;
    let mut attached = await_welcome
        .on_frame(
            &serde_json::to_vec(&welcomed["frame"]).unwrap(),
            &log,
            clock.mono_ms,
        )
        .unwrap();
    let (id, list) = attached.list(clock.mono_ms).unwrap();
    assert!(!String::from_utf8_lossy(&list).contains("\"list\""));
    send_json(&mut client, json!({"type":"channel","event":"frame","channel":"phone_1","frame":serde_json::from_slice::<Value>(&list).unwrap()})).await;
    let routed = next_client_json(&mut host).await;
    let plain = host_channel
        .open(
            &serde_json::to_vec(&routed["frame"]).unwrap(),
            clock.mono_ms,
        )
        .unwrap();
    let request: Value = serde_json::from_slice(&plain).unwrap();
    assert_eq!(request["data"]["op"], "list");
    assert_eq!(request["data"]["id"], id);
    let sessions = json!({"type":"session","data":{"v":1,"op":"sessions","id":uuid::Uuid::new_v4().to_string(),
        "re":id,"runtime_gen":runtime,"runtime_epoch":1,"seq":1,"sessions":[]}});
    let reply = host_channel
        .seal(&serde_json::to_vec(&sessions).unwrap(), clock.mono_ms)
        .unwrap();
    send_json(&mut host, json!({"type":"channel","event":"frame","channel":handle,"frame":serde_json::from_slice::<Value>(&reply).unwrap()})).await;
    let routed = next_client_json(&mut client).await;
    let events = attached
        .on_frame(
            &serde_json::to_vec(&routed["frame"]).unwrap(),
            clock.mono_ms,
        )
        .unwrap();
    assert!(events.iter().any(|e| matches!(e, Event::Registry(_))));
    // Replayed ciphertext never becomes a second session update.
    assert!(attached
        .on_frame(
            &serde_json::to_vec(&routed["frame"]).unwrap(),
            clock.mono_ms
        )
        .is_err());
    send_json(
        &mut host,
        json!({"type":"channel","event":"close","channel":handle,"reason":"closed"}),
    )
    .await;
    assert_eq!(next_client_json(&mut client).await["event"], "close");
    crate::relay::tests::assert_silent(&mut host, 150).await;
    server.abort();
}
