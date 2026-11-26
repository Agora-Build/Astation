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

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_migration_retains_account_floors_from_rotated_credentials() {
    let db = crate::test_database::TestDatabase::new("RECOVERY_TEST_DATABASE_URL", 2).await;
    sqlx::raw_sql(include_str!("../../migrations/0012_station_integration_policy.sql"))
        .execute(&db.pool).await.unwrap();
    let first = binding(true);
    let mut second = first.clone();
    second.report_client_id = "s-11234567890123456789012345".into();
    for (binding, policy) in [
        (first, json!({"cursor":1,"portal_snapshot":{"cursor":20,
            "accounts":{"complete":true,"disabled":[OTHER]}}})),
        (second, json!({"cursor":8,"availability":{"cursor":8,"complete":false,"disabled":[OWNER]}})),
        (binding(false), json!({"cursor":99})),
    ] {
        sqlx::query("INSERT INTO station_integration_policy(binding,checkpoint) VALUES ($1,$2)")
            .bind(binding.storage_key().unwrap()).bind(policy.to_string()).execute(&db.pool).await.unwrap();
    }
    sqlx::raw_sql(include_str!("../../migrations/0030_delegated_availability_fences.sql"))
        .execute(&db.pool).await.unwrap();
    let floors: Vec<(String,i64)> = sqlx::query_as(
        "SELECT account,minimum_cursor FROM station_delegated_availability_fences ORDER BY account",
    ).fetch_all(&db.pool).await.unwrap();
    assert_eq!(floors, vec![("".into(),20), (OWNER.into(),9), (OTHER.into(),21)]);
    db.cleanup().await;
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
fn checkpoint_preserves_revocation_time_and_interrupt_across_restarts() {
    let config = binding(false);
    let mut value = source(false);
    let row = &mut value["checkpoint"]["integrations"][0];
    row["state"] = json!("revoking");
    row["interruptRunning"] = json!(false);
    row["revokedAt"] = json!("2026-11-22T23:58:00.000Z");
    let first = PolicyCheckpoint::empty(config.clone()).unwrap()
        .apply_checkpoint(parse(&value, &config).unwrap(), 100).unwrap();
    let row = &mut value["checkpoint"]["integrations"][0];
    row["state"] = json!("revoked");
    row["interruptRunning"] = json!(true);
    let final_state = first.apply_checkpoint(parse(&value, &config).unwrap(), 101).unwrap();
    let reloaded: PolicyCheckpoint = serde_json::from_value(serde_json::to_value(&final_state).unwrap()).unwrap();
    for (field, regression) in [
        ("state", json!("revoking")),
        ("interruptRunning", json!(false)),
        ("revokedAt", Value::Null),
        ("revokedAt", json!("2026-11-23T00:00:00.000Z")),
    ] {
        let mut changed = value.clone();
        changed["cursor"] = json!(13);
        changed["checkpoint"]["integrations"][0][field] = regression;
        assert!(reloaded.apply_checkpoint(parse(&changed, &config).unwrap(), 102).is_err(), "{field}");
    }
    assert!(reloaded.apply_checkpoint(parse(&source(false), &config).unwrap(), 102).is_err());
    assert!(reloaded.apply_checkpoint(parse(&value, &config).unwrap(), 102).is_ok());

    // The first exact checkpoint must also preserve stops received on the ordinary feed.
    let mut live_only = PolicyCheckpoint::empty(config.clone()).unwrap();
    live_only.integrations.insert(ID.into(), reloaded.portal_snapshot.as_ref().unwrap().integrations[ID].policy.clone());
    let mut missing = source(false);
    missing["checkpoint"]["integrations"] = json!([]);
    assert!(live_only.apply_checkpoint(parse(&missing, &config).unwrap(), 103).is_err());
    assert!(live_only.apply_checkpoint(parse(&source(false), &config).unwrap(), 103).is_err());
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

#[test]
fn built_in_account_changes_follow_the_checkpoint_across_pages_restart_and_reset() {
    let config = binding(true);
    let mut saved = PolicyCheckpoint::empty(config.clone()).unwrap();
    let apply = |saved: &PolicyCheckpoint, changes: Vec<Value>, now| {
        let end = changes.last().and_then(|c| c["id"].as_u64()).unwrap_or(saved.cursor);
        let mut page = json!({"changes":changes, "cursor":end});
        if saved.cursor == 0 { page["integrations"] = json!([]); }
        saved.apply(saved.cursor, serde_json::from_value(page).unwrap(), now).unwrap()
    };
    let change = |id, kind, account: Value| json!({"id":id,"kind":kind,"integrationId":null,
        "reason":"agora_build","state":null,"account":account});
    // Ordinary traffic cannot establish a complete account baseline by itself.
    saved = apply(&saved, vec![change(3, "accounts_baseline", Value::Null)], 100);
    assert!(!saved.allows_delegated_release(OWNER));
    saved = saved.apply_checkpoint(parse(&source(true), &config).unwrap(), 101).unwrap();
    assert!(!saved.allows_delegated_release(OWNER));
    // Replaying a disabled event before the cut cannot override the newer checkpoint.
    saved = apply(&saved, vec![change(12, "account_disabled", json!(OWNER))], 102);
    assert!(saved.allows_delegated_release(OWNER));
    assert!(!saved.allows_delegated_release(OTHER));
    saved = apply(&saved, vec![change(14, "account_disabled", json!(OWNER)),
        change(16, "accounts_incomplete", Value::Null), change(18, "account_enabled", json!(OWNER))], 103);
    saved = serde_json::from_slice(&serde_json::to_vec(&saved).unwrap()).unwrap();
    assert!(!saved.allows_delegated_release(OWNER));
    saved = apply(&saved, vec![change(21, "accounts_baseline", Value::Null)], 104);
    assert!(saved.allows_delegated_release(OWNER));
    assert!(!saved.allows_delegated_release(OTHER));
    let full = (22..522).map(|id| json!({"id":id,"kind":"station_registered"})).collect();
    saved = apply(&saved, full, 105);
    assert!(!saved.allows_delegated_release(OWNER));
    saved = apply(&saved, vec![], 106);
    assert!(saved.allows_delegated_release(OWNER));
    let restart = saved.apply(0, serde_json::from_value(json!({"integrations":[],"changes":[],"cursor":0})).unwrap(), 107).unwrap();
    assert!(!restart.allows_delegated_release(OWNER));
    let mut missing_room = change(523, "account_enabled", json!(OTHER));
    missing_room.as_object_mut().unwrap().remove("integrationId");
    assert!(!apply(&saved, vec![missing_room], 107).allows_delegated_release(OTHER));
    let repeated = r#"{"changes":[{"id":523,"kind":"account_enabled","integrationId":null,"state":null,"reason":"agora_build","account":"one","account":"two"}],"cursor":523}"#;
    assert!(serde_json::from_str::<crate::integration_feed::FeedPage>(repeated).is_err());
    let malformed = apply(&saved, vec![change(523, "account_disabled", Value::Null)], 107);
    let baseline = apply(&malformed, vec![change(524, "accounts_baseline", Value::Null)], 108);
    assert!(!baseline.allows_delegated_release(OWNER));
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_rotated_report_client_cannot_release_from_an_older_binding() {
    let db = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let writer = PolicyStore(db.pool.clone());
    let replica = db.reconnect(2).await;
    let first = binding(true);
    let mut rotated = first.clone();
    rotated.report_client_id = "s-11234567890123456789012345".into();
    let genesis = "b".repeat(64);
    let cut = |prior: &PolicyCheckpoint, rows: Value| {
        let mut source = source(true);
        source["cursor"] = json!(0);
        source["checkpoint"]["bindings"] = rows;
        prior
            .apply_checkpoint(parse(&source, &prior.binding).unwrap(), 101)
            .unwrap()
    };
    let bootstrap = |config: &FeedBinding| {
        PolicyCheckpoint::empty(config.clone())
            .unwrap()
            .apply(
                0,
                serde_json::from_value(json!({"changes":[],"cursor":0,"integrations":[]})).unwrap(),
                100,
            )
            .unwrap()
    };
    let rows = source(true)["checkpoint"]["bindings"].clone();
    let initial = bootstrap(&first);
    let new_client = bootstrap(&rotated);
    writer
        .commit(&writer.load(&first).await.unwrap(), &initial)
        .await
        .unwrap();
    writer
        .commit(&writer.load(&rotated).await.unwrap(), &new_client)
        .await
        .unwrap();
    let bound = cut(&initial, rows.clone());
    let missing = cut(&new_client, json!([]));
    writer.commit(&initial, &bound).await.unwrap();
    writer.commit(&new_client, &missing).await.unwrap();

    async fn allowed(pool: &sqlx::PgPool, policy: &PolicyCheckpoint, genesis: &str) -> bool {
        let mut tx = pool.begin().await.unwrap();
        policy
            .allows_list_release_in(&mut tx, OWNER, "acct-1", genesis)
            .await
            .unwrap()
    }
    assert!(!allowed(&replica, &missing, &genesis).await);
    let same = cut(&missing, rows.clone());
    writer.commit(&missing, &same).await.unwrap();
    assert!(allowed(&replica, &same, &genesis).await);
    let mut tx = replica.begin().await.unwrap();
    assert!(same
        .allows_list_release_in(&mut tx, OWNER, "acct-1", &genesis)
        .await
        .unwrap());
    let mut changed = rows.clone();
    changed[0]["bindingState"] = json!("released");
    changed[0]["version"] = json!(4);
    let released = cut(&bound, changed);
    let commit = writer.commit(&bound, &released);
    tokio::pin!(commit);
    // A commit under the first credential must wait for a signature under the second.
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(150), &mut commit)
            .await
            .is_err()
    );
    tx.commit().await.unwrap();
    commit.await.unwrap();
    let rotated_reader = PolicyStore(replica.clone());
    let saved = rotated_reader.load(&rotated).await.unwrap();
    assert!(!allowed(&replica, &saved, &genesis).await);
    assert!(allowed(&replica, &saved, &"c".repeat(64)).await);

    let mut separate = rotated.clone();
    separate.portal_origin = "https://other-portal.example".into();
    let separate_initial = bootstrap(&separate);
    writer
        .commit(&writer.load(&separate).await.unwrap(), &separate_initial)
        .await
        .unwrap();
    let independent = cut(&separate_initial, json!([]));
    writer
        .commit(&separate_initial, &independent)
        .await
        .unwrap();
    assert!(allowed(&replica, &independent, &genesis).await);

    let mut conflict = rows.clone();
    conflict[0]["version"] = json!(4);
    let competing = cut(&saved, conflict.clone());
    writer.commit(&saved, &competing).await.unwrap();
    assert!(!allowed(&replica, &competing, &genesis).await);
    conflict[0]["version"] = json!(5);
    let later = cut(&competing, conflict);
    writer.commit(&competing, &later).await.unwrap();
    assert!(allowed(&replica, &later, &genesis).await);
    drop(rotated_reader);
    replica.close().await;
    db.cleanup().await;
}
