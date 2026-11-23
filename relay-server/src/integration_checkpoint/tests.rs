use super::*;
use crate::integration_feed::{PolicyCheckpoint, PolicyStore};
use serde_json::json;

const OWNER: &str = "ab01234567890123456789012345";
const OTHER: &str = "ab11234567890123456789012345";
const ID: &str = "i-01234567890123456789012345";

fn binding(built_in: bool) -> FeedBinding {
    FeedBinding {
        issuer: "https://auth.example".into(),
        portal_origin: "https://portal.example".into(),
        station_origin: if built_in {
            "https://station-dev.agora.build"
        } else {
            "https://custom.example"
        }
        .into(),
        report_client_id: "s-01234567890123456789012345".into(),
    }
}

fn source(built_in: bool) -> Value {
    let mut source = json!({"changes":[], "cursor":12, "checkpoint": {
        "at":"2026-11-23T00:00:00.000Z", "integrations":[{
            "id":ID, "ownerAccount":OWNER, "state":"ready", "scopes":["agent.view"],
            "r9Svc":"a".repeat(64), "expiresAt":"2099-01-01T00:00:00.000Z", "quotaPerSecond":200 }] }});
    if built_in {
        source["checkpoint"]["accounts"] = json!({"complete":true,"disabled":[OTHER]});
        source["checkpoint"]["bindings"] = json!([{"account":OWNER,"accountId":"acct-1",
            "genesisHash":"b".repeat(64),"bindingId":"bind-1","version":3,"bindingState":"bound"}]);
    }
    source
}

fn parse(value: &Value, binding: &FeedBinding) -> Result<PortalCheckpoint, ()> {
    PortalCheckpoint::parse(&serde_json::to_vec(value).unwrap(), binding)
}

#[test]
fn exact_checkpoint_retains_accounts_bindings_and_unknown_legacy_revocation_time() {
    let mut value = source(true);
    let row = &mut value["checkpoint"]["integrations"][0];
    row["state"] = json!("revoked");
    row["revokedAt"] = Value::Null;
    row["interruptRunning"] = json!(true);
    let checkpoint = parse(&value, &binding(true)).unwrap();
    assert_eq!(checkpoint.cursor, 12);
    assert_eq!(checkpoint.integrations[ID].revoked_at, None);
    assert_eq!(
        checkpoint.integrations[ID].policy.interrupt_running,
        Some(true)
    );
    let accounts = checkpoint.accounts.unwrap();
    assert!(accounts.enabled(OWNER));
    assert!(!accounts.enabled(OTHER));
    assert!(!accounts.enabled("invalid"));
    let rows = checkpoint.bindings.unwrap();
    assert_eq!(
        (rows[0].version, rows[0].binding_state.as_str()),
        (3, "bound")
    );
}

#[test]
fn incomplete_accounts_never_mean_an_absent_account_is_enabled() {
    let mut value = source(true);
    value["checkpoint"]["accounts"]["complete"] = json!(false);
    let checkpoint = parse(&value, &binding(true)).unwrap();
    assert!(!checkpoint.accounts.unwrap().enabled(OWNER));
    for replacement in [
        Value::Null,
        json!({"disabled":[]}),
        json!({"complete":true}),
        json!({"complete":"true","disabled":[]}),
    ] {
        value["checkpoint"]["accounts"] = replacement;
        assert!(parse(&value, &binding(true)).is_err());
    }
}

#[test]
fn custom_checkpoints_cannot_carry_builtin_account_or_binding_data() {
    assert!(parse(&source(false), &binding(false)).is_ok());
    assert!(parse(&source(true), &binding(false)).is_err());
    assert!(parse(&source(false), &binding(true)).is_err());
    let mut value = source(false);
    value["checkpoint"]["accounts"] = Value::Null;
    assert!(parse(&value, &binding(false)).is_err());
}

#[test]
fn legacy_partial_ambiguous_and_duplicate_snapshots_are_refused() {
    let mut variants = vec![json!({"changes":[],"cursor":0,"integrations":[]})];
    for (path, replacement) in [
        ("cursor", json!(9_007_199_254_740_992_u64)),
        ("changes", json!([{"id":12,"kind":"integration_paused"}])),
    ] {
        let mut value = source(true);
        value[path] = replacement;
        variants.push(value);
    }
    let mut value = source(true);
    value["checkpoint"]["nextCursor"] = json!("next");
    variants.push(value);
    let mut value = source(true);
    value["checkpoint"]["at"] = json!("2026-11-23T00:00:00Z");
    variants.push(value);
    let mut value = source(true);
    value["checkpoint"]["integrations"][0]["state"] = json!("revoked");
    variants.push(value);
    let mut value = source(true);
    let row = value["checkpoint"]["integrations"][0].clone();
    value["checkpoint"]["integrations"]
        .as_array_mut()
        .unwrap()
        .push(row);
    variants.push(value);
    for value in variants {
        assert!(parse(&value, &binding(true)).is_err(), "{value}");
    }
    let raw = serde_json::to_string(&source(true)).unwrap();
    assert!(PortalCheckpoint::parse(
        raw.replace("\"complete\":true", "\"complete\":false,\"complete\":true")
            .as_bytes(),
        &binding(true)
    )
    .is_err());
    assert!(
        PortalCheckpoint::parse(&vec![b' '; MAX_CHECKPOINT_BYTES + 1], &binding(true)).is_err()
    );
}

#[test]
fn invalid_binding_versions_ownership_grammar_and_duplicate_keys_are_refused() {
    for (key, value) in [
        ("version", json!(0)),
        ("version", json!(9_007_199_254_740_992_u64)),
        ("version", json!(1.5)),
        ("account", json!("acct-1")),
        ("accountId", json!("a/b")),
        ("bindingId", json!("x".repeat(129))),
        ("genesisHash", json!("B".repeat(64))),
        ("bindingState", json!("pending")),
        ("unknown", json!(true)),
    ] {
        let mut source = source(true);
        source["checkpoint"]["bindings"][0][key] = value;
        assert!(parse(&source, &binding(true)).is_err(), "{key}");
    }
    let mut value = source(true);
    let mut duplicate = value["checkpoint"]["bindings"][0].clone();
    duplicate["account"] = json!(OTHER);
    value["checkpoint"]["bindings"]
        .as_array_mut()
        .unwrap()
        .push(duplicate);
    assert!(parse(&value, &binding(true)).is_err());
}

#[test]
fn equal_feed_cursor_does_not_hide_binding_changes_or_allow_version_rollback() {
    let config = binding(true);
    let first = PolicyCheckpoint::empty(config.clone())
        .unwrap()
        .apply_checkpoint(parse(&source(true), &config).unwrap(), 100)
        .unwrap();
    let mut value = source(true);
    value["checkpoint"]["bindings"][0]["version"] = json!(4);
    value["checkpoint"]["bindings"][0]["bindingState"] = json!("unbound");
    let next = first
        .apply_checkpoint(parse(&value, &config).unwrap(), 101)
        .unwrap();
    assert_eq!(first.cursor, next.cursor);
    assert_eq!(next.revision, first.revision + 1);
    assert_ne!(first.portal_snapshot, next.portal_snapshot);
    assert!(next
        .apply_checkpoint(parse(&source(true), &config).unwrap(), 102)
        .is_err());
    value["checkpoint"]["bindings"][0]["bindingId"] = json!("different-at-same-version");
    assert!(next
        .apply_checkpoint(parse(&value, &config).unwrap(), 102)
        .is_err());
    value["checkpoint"]["bindings"] = json!([]);
    assert!(next
        .apply_checkpoint(parse(&value, &config).unwrap(), 102)
        .is_err());
    assert!(first
        .apply_checkpoint(parse(&source(false), &binding(false)).unwrap(), 101)
        .is_err());
    let polled = next
        .apply(
            0,
            serde_json::from_value(json!({"changes":[],"cursor":0,"integrations":[]})).unwrap(),
            103,
        )
        .unwrap();
    assert_eq!(polled.portal_snapshot, next.portal_snapshot);
    assert_eq!(polled.portal_snapshot_revision, None);
    assert!(polled
        .apply_checkpoint(parse(&source(true), &config).unwrap(), 104)
        .is_err());
    let mut missing = source(true);
    missing["checkpoint"]["integrations"] = json!([]);
    assert!(first
        .apply_checkpoint(parse(&missing, &config).unwrap(), 105)
        .is_err());
    let emptied = first
        .apply(
            0,
            serde_json::from_value(json!({"changes":[],"cursor":0,"integrations":[]})).unwrap(),
            106,
        )
        .unwrap();
    let mut swapped = source(true);
    swapped["checkpoint"]["integrations"][0]["ownerAccount"] = json!(OTHER);
    assert!(emptied
        .apply_checkpoint(parse(&swapped, &config).unwrap(), 107)
        .is_err());
}

#[test]
fn collecting_a_source_never_refreshes_or_replaces_live_execution_policy() {
    let config = binding(true);
    let raw = source(true);
    let mut live_row = raw["checkpoint"]["integrations"][0].clone();
    live_row["state"] = json!("paused");
    let live = PolicyCheckpoint::empty(config.clone())
        .unwrap()
        .apply(
            0,
            serde_json::from_value(json!({"changes":[],"cursor":0,"integrations":[live_row]}))
                .unwrap(),
            100,
        )
        .unwrap();
    let collected = live
        .apply_checkpoint(parse(&raw, &config).unwrap(), 221)
        .unwrap();
    assert_eq!(collected.cursor, live.cursor);
    assert_eq!(collected.integrations, live.integrations);
    assert_eq!(collected.denied, live.denied);
    assert_eq!(collected.received_at, live.received_at);
    assert!(collected.current(ID, OWNER, 221).is_err());
    assert_eq!(
        collected.portal_snapshot.as_ref().unwrap().integrations[ID]
            .policy
            .state,
        "ready"
    );
}

#[tokio::test]
async fn authenticated_http_requires_explicit_checkpoint_and_reuses_only_the_report_token() {
    let mut fixture = crate::integration_portal::tests::Fixture::new().await;
    let client = fixture.client();
    assert_eq!(
        client.checkpoint().await,
        Err(crate::integration_portal::PortalError::Contract)
    );
    *fixture.shared.feed.lock().await = Some(source(false));
    let snapshot = client.checkpoint().await.unwrap();
    assert_eq!(snapshot.binding, fixture.binding);
    assert_eq!(snapshot.cursor, 12);
    assert!(fixture.shared.cursors.lock().await.is_empty());
    fixture.set_status(401);
    assert_eq!(
        client.checkpoint().await,
        Err(crate::integration_portal::PortalError::Denied)
    );
    fixture.set_status(200);
    client.checkpoint().await.unwrap();
}

#[tokio::test]
#[ignore]
async fn postgres_delegated_portal_checkpoint_survives_restart_and_cas_refuses_stale_binding_source(
) {
    let database =
        crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = PolicyStore(database.pool.clone());
    let config = binding(true);
    let old = store.load(&config).await.unwrap();
    let first = old
        .apply_checkpoint(parse(&source(true), &config).unwrap(), 100)
        .unwrap();
    store.commit(&old, &first).await.unwrap();
    let replica = PolicyStore(database.reconnect(2).await);
    assert_eq!(replica.load(&config).await.unwrap(), first);
    let mut value = source(true);
    value["checkpoint"]["bindings"][0]["version"] = json!(4);
    let next = first
        .apply_checkpoint(parse(&value, &config).unwrap(), 101)
        .unwrap();
    store.commit(&first, &next).await.unwrap();
    let stale = first
        .apply_checkpoint(parse(&source(true), &config).unwrap(), 101)
        .unwrap();
    assert!(replica.commit(&first, &stale).await.is_err());
    assert_eq!(replica.load(&config).await.unwrap(), next);
    for (key, value) in [
        ("portal_snapshot_revision", json!(999)),
        ("portal_snapshot", Value::Null),
    ] {
        let mut corrupt = serde_json::to_value(&next).unwrap();
        corrupt[key] = value;
        sqlx::query("UPDATE station_integration_policy SET checkpoint=$1")
            .bind(serde_json::to_string(&corrupt).unwrap())
            .execute(&database.pool)
            .await
            .unwrap();
        assert!(replica.load(&config).await.is_err());
    }
    replica.0.close().await;
    database.cleanup().await;
}

#[tokio::test]
#[ignore]
async fn postgres_delegated_portal_http_collection_preserves_source_on_errors_and_fences_denied_tokens(
) {
    let database =
        crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = PolicyStore(database.pool.clone());
    let mut fixture = crate::integration_portal::tests::Fixture::new().await;
    let client = fixture.client();
    *fixture.shared.feed.lock().await = Some(source(false));
    client.collect_checkpoint(&store, None).await.unwrap();
    let first = store.load(&fixture.binding).await.unwrap();
    assert_eq!(first.cursor, 0);
    assert_eq!(first.portal_snapshot.as_ref().unwrap().cursor, 12);
    assert!(first.denied);
    assert_eq!(first.received_at, 0);
    assert!(first.portal_snapshot.is_some());
    fixture.set_status(503);
    assert_eq!(
        client.collect_checkpoint(&store, None).await,
        Err(crate::integration_portal::PortalError::Unavailable)
    );
    assert_eq!(store.load(&fixture.binding).await.unwrap(), first);
    fixture.set_status(200);
    *fixture.shared.feed.lock().await = Some(json!({"changes":[], "cursor":0, "integrations":[]}));
    assert_eq!(
        client.collect_checkpoint(&store, None).await,
        Err(crate::integration_portal::PortalError::Contract)
    );
    assert_eq!(store.load(&fixture.binding).await.unwrap(), first);
    fixture.set_status(401);
    assert_eq!(
        client.collect_checkpoint(&store, None).await,
        Err(crate::integration_portal::PortalError::Denied)
    );
    let denied = store.load(&fixture.binding).await.unwrap();
    assert!(denied.denied);
    assert_eq!(denied.portal_snapshot, first.portal_snapshot);
    assert_eq!(denied.portal_snapshot_revision, None);
    let stale = first
        .apply_checkpoint(
            parse(&source(false), &fixture.binding).unwrap(),
            first.received_at,
        )
        .unwrap();
    assert!(store.commit(&first, &stale).await.is_err());
    fixture.set_status(200);
    *fixture.shared.feed.lock().await = Some(source(false));
    client.collect_checkpoint(&store, None).await.unwrap();
    assert!(store.load(&fixture.binding).await.unwrap().denied);
    database.cleanup().await;
}
