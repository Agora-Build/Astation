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
    let portal = crate::integration_feed::FeedBinding {
        issuer: "https://auth.example".into(),
        portal_origin: "https://portal.example".into(),
        station_origin: ORIGIN.into(),
        report_client_id: "s-01234567890123456789012345".into(),
    };
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
