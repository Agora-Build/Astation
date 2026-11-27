use super::{proof, state};
use crate::{
    cluster::ConnRef,
    integration_checkpoint::{Binding, PortalCheckpoint},
    integration_feed::PolicyStore,
    relay::tests::{connect_atem, next_client_json, send_json, spawn_relay},
    remote_api::{
        push_ingress::tests::Fixture,
        recovery::{HostRouteError, ProxyBinding, RecoveryStore},
    },
    station_integrations::tests::{attach_test_room_owner, OWNER},
};
use atem_client::host_route::{
    host_route_message, sign_host_route_as, HostChallenge, HostRouteBody, RelayReply, RouteKind,
};
use serde_json::json;

const ORIGIN: &str = "https://station-dev.agora.build";
const DISABLED: &str = "service suspended: account disabled at Agora.Build";
const NO_OWNER: &str = "service suspended: no Agora.Build owner at this Station";

fn test_portal() -> crate::integration_feed::FeedBinding {
    crate::integration_feed::FeedBinding {
        issuer: "https://auth.example".into(),
        portal_origin: "https://portal.example".into(),
        station_origin: ORIGIN.into(),
        report_client_id: "s-01234567890123456789012345".into(),
    }
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_proved_relay_and_proxy_receive_only_confirmed_suspensions() {
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let store = RecoveryStore::postgres(db.pool.clone());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    attach_test_room_owner(&store, ORIGIN).await;
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let policy = PolicyStore(db.pool.clone());
    let portal = test_portal();
    let mut previous = policy.load(&portal).await.unwrap();
    let (base, server) = spawn_relay(state(store.clone())).await;
    for (expected, fresh) in [(DISABLED, true), (DISABLED, false), (NO_OWNER, true)] {
        let now = chrono::Utc::now().timestamp_millis();
        let mut snapshot: PortalCheckpoint = previous.portal_snapshot.clone().unwrap();
        if expected == DISABLED {
            snapshot.accounts.as_mut().unwrap().disabled = vec![OWNER.into()];
        } else {
            snapshot.bindings = Some(vec![Binding {
                account: OWNER.into(),
                account_id: f.log.account_id().into(),
                genesis_hash: f.log.genesis_hash().to_hex(),
                binding_id: "binding-a".into(),
                binding_state: "released".into(),
                version: 2,
            }]);
        }
        let mut next = previous.apply_checkpoint(snapshot, now / 1000).unwrap();
        next.record_completed_read(if fresh { now } else { now - 61_000 }, now);
        policy.commit(&previous, &next).await.unwrap();
        previous = next;
        let c = HostChallenge::new("phone");
        let signed = host_route_message(
            &sign_host_route_as(
                RouteKind::Proxy,
                &f.keys,
                &f.host_key,
                &HostRouteBody::at(&f.log, "host-a", "host-a", &c),
            )
            .unwrap(),
        )
        .to_string();
        let result = store
            .admit_proxy(
                &signed,
                c.nonce,
                "phone",
                "host-a",
                ConnRef::new("proxy", "replica"),
                ProxyBinding {
                    session: "session".into(),
                    generation: "generation".into(),
                    native: ConnRef::new("native", "replica"),
                },
                "alice",
            )
            .await;
        if !fresh {
            assert!(matches!(result, Err(HostRouteError::Unavailable)));
            continue;
        }
        let Err(HostRouteError::Suspended(frame)) = result else {
            panic!("expected a verified proxy refusal")
        };
        let refusal = RelayReply::suspended(expected).unwrap().to_json();
        assert_eq!(frame, refusal);
        for valid_nonce in [false, true] {
            let mut socket = connect_atem(&base, "phone", "host-a").await;
            let mut challenge =
                HostChallenge::parse(next_client_json(&mut socket).await.to_string().as_bytes())
                    .unwrap();
            if !valid_nonce {
                challenge.nonce[0] ^= 1;
            }
            send_json(
                &mut socket,
                proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a"),
            )
            .await;
            let reply = next_client_json(&mut socket).await;
            if valid_nonce {
                assert_eq!(reply, refusal);
            } else {
                assert_eq!(reply["op"], "host_route_refused");
                assert_ne!(reply["code"], "service_suspended");
                assert!(reply.get("text").is_none());
            }
        }
    }
    let saved: serde_json::Value =
        sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
            .bind(f.log.genesis_hash().to_hex())
            .fetch_one(&db.pool)
            .await
            .unwrap();
    for key in ["routes", "proxies"] {
        assert_eq!(saved[key], json!({}));
    }
    server.abort();
    db.cleanup().await;
}

async fn open_client(
    base: &str,
    fixture: &Fixture,
    principal: &str,
    channel: &str,
) -> super::TestSocket {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    let url = base.replace(
        "/ws",
        &format!(
            "/api/remote/v1/channels?genesis={}&host=host-a",
            fixture.log.genesis_hash().to_hex()
        ),
    );
    let mut request = url.into_client_request().unwrap();
    request.headers_mut().insert(
        "authorization",
        format!("Bearer {principal}").parse().unwrap(),
    );
    let mut client = tokio_tungstenite::connect_async(request).await.unwrap().0;
    send_json(
        &mut client,
        json!({"type":"channel","event":"open","channel":channel,"transport":"relay"}),
    )
    .await;
    client
}

#[tokio::test]
#[ignore = "requires isolated Postgres and Redis"]
async fn postgres_delegated_suspension_closes_cross_replica_channels_before_the_routed_notice() {
    use crate::cluster::redis::{connect_cluster, test_support};
    let _redis = test_support::REDIS_LOCK.lock().await;
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 5).await;
    let store = RecoveryStore::postgres(db.pool.clone());
    let peer_store = RecoveryStore::postgres(db.reconnect(5).await);
    for store in [&store, &peer_store] {
        store.configure_delegated(ORIGIN, 1).await.unwrap();
        attach_test_room_owner(store, ORIGIN).await;
    }
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let other = Fixture::new(f.created - 1);
    other.publish_for(&store, "bob").await;
    sqlx::query("INSERT INTO account_identities (issuer,subject,principal) VALUES ($1,$2,'bob')")
        .bind(test_portal().issuer)
        .bind("ab01234567890123456789012346")
        .execute(&db.pool)
        .await
        .unwrap();
    let mut replicas = Vec::new();
    for s in [&store, &peer_store] {
        let mut app = state(s.clone());
        let cluster = connect_cluster(
            &test_support::test_url(),
            app.identity.clone(),
            std::time::Duration::from_secs(10),
        )
        .await
        .unwrap();
        app.relay = cluster.relay.clone();
        let (url, server) = spawn_relay(app).await;
        replicas.push((url, server, cluster));
    }
    let host_base = &replicas[0].0;
    let client_base = &replicas[1].0;
    let client_hub = &replicas[1].2.relay;
    let mut old_host = connect_atem(host_base, "phone", "routed-a").await;
    super::prove(&mut old_host, &f.keys, &f.host_key, &f.log, "routed-a").await;
    assert_eq!(next_client_json(&mut old_host).await["op"], "heads");
    let mut old_client = open_client(client_base, &f, "alice", "old").await;
    let old_open = next_client_json(&mut old_host).await;
    let old_binding = client_hub
        .channels()
        .host_binding(old_open["channel"].as_str().unwrap())
        .unwrap();
    let mut host = connect_atem(host_base, "phone", "routed-a").await;
    super::prove(&mut host, &f.keys, &f.host_key, &f.log, "routed-a").await;
    assert_eq!(next_client_json(&mut host).await["op"], "heads");
    let mut other_host = connect_atem(host_base, "phone", "routed-b").await;
    super::prove(
        &mut other_host,
        &other.keys,
        &other.host_key,
        &other.log,
        "routed-b",
    )
    .await;
    assert_eq!(next_client_json(&mut other_host).await["op"], "heads");
    let mut other_client = open_client(client_base, &other, "bob", "unchanged").await;
    let other_open = next_client_json(&mut other_host).await;
    let mut client = open_client(client_base, &f, "alice", "client_1").await;
    let open = next_client_json(&mut host).await;
    assert_eq!(open["event"], "open");
    let handle = open["channel"].as_str().unwrap();
    let binding = client_hub.channels().host_binding(handle).unwrap();
    assert_ne!(binding.connection.replica, client_hub.replica_id());
    let mut second = open_client(client_base, &f, "alice", "client_2").await;
    let second_open = next_client_json(&mut host).await;
    let mut already_closed = open_client(client_base, &f, "alice", "ended").await;
    let ended = next_client_json(&mut host).await;
    send_json(
        &mut host,
        json!({"type":"channel","event":"close","channel":ended["channel"],"reason":"closed"}),
    )
    .await;
    assert_eq!(
        next_client_json(&mut already_closed).await["channel"],
        "ended"
    );
    let peer = PolicyStore(db.reconnect(2).await);
    let previous = peer.load(&test_portal()).await.unwrap();
    let mut snapshot = previous.portal_snapshot.clone().unwrap();
    snapshot.accounts.as_mut().unwrap().disabled = vec![OWNER.into()];
    let now = chrono::Utc::now().timestamp_millis();
    let mut stopped = previous.apply_checkpoint(snapshot, now / 1000).unwrap();
    stopped.record_completed_read(now, now);
    peer.commit(&previous, &stopped).await.unwrap();
    assert!(store
        .with_host_suspension(&old_binding, |_| async {
            panic!("disclosed suspension to replaced host")
        })
        .await
        .is_none());
    send_json(
        &mut old_client,
        json!({"type":"channel","event":"frame","channel":"old","frame":{"probe":true}}),
    )
    .await;
    crate::relay::tests::assert_closed(&mut old_client).await;
    // A host frame already in the broker must pass the current policy on
    // its way out of the queue. The client must see only its terminal close.
    let queued = json!({"type":"channel","event":"frame","channel":handle,"frame":{"probe":true}});
    assert!(client_hub
        .channels()
        .reply(handle, &binding.connection, &queued.to_string()));
    assert_eq!(
        next_client_json(&mut client).await,
        json!({"type":"channel","event":"close","channel":"client_1","reason":"service_suspended"})
    );
    crate::relay::tests::assert_closed(&mut client).await;
    // The routed host detects the policy change while the remote client
    // owns the broker routes. Only its two still-open wire handles close.
    send_json(&mut host, queued).await;
    let mut expected =
        std::collections::BTreeSet::from([handle, second_open["channel"].as_str().unwrap()]);
    for _ in 0..2 {
        let close = next_client_json(&mut host).await;
        assert_eq!(close["reason"], "service_suspended");
        assert!(expected.remove(close["channel"].as_str().unwrap()));
    }
    assert_eq!(
        next_client_json(&mut host).await,
        atem_client::station_notice::ServiceSuspended::new(DISABLED)
            .unwrap()
            .to_json()
    );
    crate::relay::tests::assert_closed(&mut host).await;
    send_json(
        &mut second,
        json!({"type":"channel","event":"frame","channel":"client_2","frame":{"probe":true}}),
    )
    .await;
    assert_eq!(
        next_client_json(&mut second).await["reason"],
        "service_suspended"
    );
    send_json(&mut other_host, json!({"type":"channel","event":"frame","channel":other_open["channel"],"frame":{"unrelated":true}})).await;
    assert_eq!(
        next_client_json(&mut other_client).await,
        json!({"type":"channel","event":"frame","channel":"unchanged","frame":{"unrelated":true}})
    );
    drop((
        host,
        client,
        second,
        other_host,
        other_client,
        already_closed,
    ));
    for (_, server, cluster) in replicas {
        server.abort();
        cluster.abort();
    }
    peer.0.close().await;
    peer_store.pool().unwrap().close().await;
    db.cleanup().await;
}
