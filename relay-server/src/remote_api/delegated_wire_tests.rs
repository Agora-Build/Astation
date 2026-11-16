use super::*;
use atem_client::control::{ControlSync, ToHost, ToStation};

const ORIGIN: &str = "https://station-dev.agora.build";

#[tokio::test]
async fn real_socket_announces_empty_feed_then_serves_correlated_calls_without_a_mac() {
    let store = RecoveryStore::memory();
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let app = state(store);
    let (base, server) = spawn_relay(app).await;
    let mut socket = connect_atem(&base, "phone", "host-a").await;
    prove(&mut socket, &f.keys, &f.host_key, &f.log, "host-a").await;
    let heads = next_client_json(&mut socket).await;
    let ToHost::Heads(heads) = ToHost::decode(heads.to_string().as_bytes()).unwrap() else {
        panic!("heads")
    };
    assert_eq!(heads.feeds.len(), 1);
    assert_eq!(heads.feeds[0].origin, ORIGIN);
    assert_eq!(heads.feeds[0].head, 0);
    assert_eq!(heads.membership, f.log.head());
    let request = ControlSync {
        request_id: uuid::Uuid::new_v4().to_string(),
        origin: ORIGIN.into(),
        feed_id: Some(heads.feeds[0].feed_id.clone()),
        after: 0,
    };
    send_json(&mut socket, request.to_json().unwrap()).await;
    let response = next_client_json(&mut socket).await;
    let ToHost::ControlSyncResult(page) = ToHost::decode(response.to_string().as_bytes()).unwrap()
    else {
        panic!("page")
    };
    assert!(page.answers(&request).is_ok());
    assert!(page.records.is_empty());
    send_json(
        &mut socket,
        json!({"type":"relay","op":"membership_fetch","after":0}),
    )
    .await;
    let response = next_client_json(&mut socket).await;
    let ToHost::MembershipFetchResult(page) =
        ToHost::decode(response.to_string().as_bytes()).unwrap()
    else {
        panic!("membership")
    };
    assert_eq!(page.head, f.log.head());
    assert_eq!(page.entries.len(), 2);
    server.abort();
}

#[tokio::test]
async fn stale_feed_and_cross_account_ack_disclose_no_metadata_and_do_not_close_current_link() {
    let store = RecoveryStore::memory();
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
    f.publish(&store).await;
    let (base, server) = spawn_relay(state(store)).await;
    let mut socket = connect_atem(&base, "phone", "host-a").await;
    prove(&mut socket, &f.keys, &f.host_key, &f.log, "host-a").await;
    let heads = next_client_json(&mut socket).await;
    let feed = heads["feeds"][0]["feed_id"].as_str().unwrap();
    send_json(
        &mut socket,
        json!({"type":"relay","op":"control_sync",
        "request_id":uuid::Uuid::new_v4().to_string(), "origin":ORIGIN,
        "feed_id":uuid::Uuid::new_v4().to_string(), "after":0}),
    )
    .await;
    assert_eq!(
        next_client_json(&mut socket).await,
        json!({"type":"relay","op":"control_sync_refused","code":"forbidden"})
    );
    send_json(
        &mut socket,
        json!({"type":"relay","op":"control_ack",
        "account_id":"other-account", "genesis_hash":f.log.genesis_hash().to_hex(),
        "host_id":"host-a", "host_trust_gen":1, "origin":ORIGIN,
        "feed_id":feed, "cursor":0, "results":[]}),
    )
    .await;
    assert_eq!(
        next_client_json(&mut socket).await,
        json!({"type":"relay","op":"control_ack_refused","code":"forbidden"})
    );
    let call = json!({"type":"relay","op":"membership_fetch","after":1});
    assert!(matches!(
        ToStation::decode(call.to_string().as_bytes()),
        Ok(ToStation::MembershipFetch(_))
    ));
    send_json(&mut socket, call).await;
    let page = next_client_json(&mut socket).await;
    assert_eq!(page["op"], "membership_fetch_result");
    assert_eq!(page["entries"].as_array().unwrap().len(), 1);
    server.abort();
}
