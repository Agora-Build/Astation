use super::super::{now, Operation, RecoveryStore};
use super::*;
use crate::remote_api::{host_route_tests::proof, push_ingress::tests::Fixture};
use atem_client::{
    control::{
        build_control, principal_key_of, ControlAbout, ControlAction, ControlBody, ControlFeed,
        ControlPrincipal, ControlSigner, ControlSync, ToHost,
    },
    host_route::HostChallenge,
    membership::{service_add, sign_entry, HostNow, ServiceScope},
    KeyId, KeyProvider,
};
use axum::http::StatusCode;
use serde_json::json;

#[cfg(feature = "delegated-host-work")]
#[path = "delegated_restore_tests.rs"]
mod recovery_fence;

#[cfg(feature = "delegated-host-work")]
#[path = "delegated_recovery_plan_tests.rs"]
mod recovery_plan;

#[cfg(feature = "delegated-host-work")]
#[path = "delegated_recovery_review_tests.rs"]
mod recovery_review;

#[cfg(feature = "delegated-host-work")]
#[path = "delegated_recovered_stops_tests.rs"]
mod recovered_stops;

#[cfg(feature = "delegated-host-work")]
#[path = "delegated_native_recovery_tests.rs"]
mod native_recovery;

#[cfg(feature = "delegated-host-work")]
#[path = "delegated_recovery_signatures_tests.rs"]
mod recovery_signatures;

const ORIGIN: &str = "https://station-dev.agora.build";

pub(crate) fn fixture() -> Fixture {
    let mut f = Fixture::new(now().wall_ms);
    let key = KeyId::new("service");
    f.keys.insert_ed25519(key.clone(), &[9; 32]);
    let action = service_add(
        "svc-test",
        f.keys.public_key(&key).unwrap(),
        &ServiceScope::new(["host-a"]),
        f.created + 86_400_000,
        f.created,
    )
    .unwrap();
    let entry = sign_entry(
        &f.keys,
        &KeyId::new("manager"),
        f.log.draft("phone", f.created, &action),
    )
    .unwrap();
    let result = f.log.evaluate_objects(
        &[entry.object().clone()],
        &HostNow {
            wall_ms: f.created,
            mono_ms: 0,
            boot_id: "test".into(),
        },
    );
    assert_eq!(result.appended, 1);
    f.log = result.next;
    f
}

#[test]
fn delegated_recovery_inspection_never_ticks_reports_or_exposes_record_bodies() {
    let f = fixture();
    let mut feed = Stored::new(ORIGIN, &f.log).unwrap();
    let held = record(
        &f,
        &feed,
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Hold,
    );
    feed.publish(
        ORIGIN,
        &f.log,
        &held,
        f.created,
        &["host-a".into()],
        f.created,
    )
    .unwrap();
    let ledger = feed
        .ledger(ORIGIN, &f.log)
        .unwrap()
        .stop_reporting("report-client")
        .unwrap()
        .next;
    feed.ledger = ledger.to_json();
    let before = serde_json::to_value(&feed).unwrap();
    let report = feed.recovery_inspection(ORIGIN, &f.log).unwrap();
    assert_eq!(report["head"], 1);
    assert_eq!(report["record_verification"]["valid"], 1);
    assert_eq!(report["signing_watermarks"]["principals"], 1);
    assert_eq!(report["signing_watermarks"]["highest_issued_at"], f.created);
    assert_eq!(report["reporting_stopped"], true);
    assert_eq!(report["ready_reports"], 0);
    assert_eq!(serde_json::to_value(&feed).unwrap(), before);
    for private in [
        "svc-test",
        "host-a",
        "signature",
        "report-client",
        "records",
        "ledger",
    ] {
        assert!(
            !report.to_string().contains(&format!("\"{private}\"")),
            "{private}"
        );
    }
    assert!(feed
        .recovery_inspection("https://other.example", &f.log)
        .is_err());
    feed.records[0]["signature"] = json!("tampered");
    assert!(feed.recovery_inspection(ORIGIN, &f.log).is_err());
}

#[test]
fn delegated_recovery_review_preserves_host_interrupts_and_never_trusts_unknown_authority() {
    let mut f = fixture();
    let action = atem_client::membership::host_sender_revoke("host-a", false, f.created).unwrap();
    let entry = sign_entry(&f.keys, &KeyId::new("manager"), f.log.draft("phone", f.created, &action)).unwrap();
    let next = f.log.evaluate_objects(&[entry.object().clone()], &HostNow {
        wall_ms: f.created, mono_ms: 0, boot_id: "test".into(),
    });
    assert_eq!(next.appended, 1);
    f.log = next.next;
    let mut feed = Stored::new(ORIGIN, &f.log).unwrap();
    let record = ControlRecord::from_signed(build_control(&f.keys, &KeyId::new("manager"), &ControlBody {
        account_id: f.log.account_id().into(), genesis_hash: f.log.genesis_hash(), feed: None,
        principal: ControlPrincipal::Host("host-a".into()), principal_key: None,
        signer: ControlSigner::Member("phone".into()),
        action: ControlAction::InterruptRunning { revoke_seq: Some(f.log.head().seq) },
        record_id: uuid::Uuid::new_v4().to_string(), issued_at: f.created + 1,
        about: ControlAbout { integration_id: None, by: "owner".into() },
    }).unwrap()).unwrap();
    feed.publish(ORIGIN, &f.log, &record, f.created, &["host-a".into()], f.created).unwrap();
    let before = serde_json::to_value(&feed).unwrap();
    let review = feed.recovery_review(ORIGIN, &f.log).unwrap();
    assert_eq!(review["records"][0]["requirement"], "retain_host_record");
    assert_eq!(review["records"][0]["interrupt_running"], true);
    assert_eq!(review["records"][0]["revoke_seq"], f.log.head().seq);
    assert_eq!(serde_json::to_value(&feed).unwrap(), before);
    feed.records[0]["body"]["signer"] = json!("member:unknown-manager");
    let unknown = feed.recovery_review(ORIGIN, &f.log).unwrap();
    assert_eq!(unknown["records"][0]["requirement"], "authority_review");
    assert_eq!(unknown["records"][0]["verification"], "pending:signer_unknown");
}

fn root(f: &Fixture) -> Root {
    Root {
        account: f.log.account_id().into(),
        membership: f.log.to_stored(),
        blobs: Default::default(),
        push: Default::default(),
        routes: Default::default(),
        proxies: Default::default(),
        enrollments: Default::default(),
        verifier_reports: Default::default(),
        delegated: Default::default(),
    }
}

fn record(f: &Fixture, feed: &Stored, id: &str, action: ControlAction) -> ControlRecord {
    let key = KeyId::new("service");
    let object = build_control(
        &f.keys,
        &key,
        &ControlBody {
            account_id: f.log.account_id().into(),
            genesis_hash: f.log.genesis_hash(),
            feed: Some(ControlFeed {
                origin: ORIGIN.into(),
                feed_id: feed.feed_id.clone(),
            }),
            principal: ControlPrincipal::Service("svc-test".into()),
            principal_key: Some(principal_key_of(&f.keys.public_key(&key).unwrap()).unwrap()),
            signer: ControlSigner::Principal,
            action,
            record_id: id.into(),
            issued_at: f.created,
            about: ControlAbout {
                integration_id: Some("i-01234567890123456789012345".into()),
                by: "owner".into(),
            },
        },
    )
    .unwrap();
    ControlRecord::parse(object.to_json().to_string().as_bytes()).unwrap()
}

fn sync(feed: Option<&Stored>, after: u64) -> ToStation {
    ToStation::ControlSync(ControlSync {
        request_id: uuid::Uuid::new_v4().to_string(),
        origin: ORIGIN.into(),
        feed_id: feed.map(|f| f.feed_id.clone()),
        after,
    })
}

async fn admit(store: &RecoveryStore, f: &Fixture, connection: &str) -> HostBinding {
    let challenge = HostChallenge::new("phone");
    store
        .admit_host(
            &proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string(),
            challenge.nonce,
            "phone",
            "host-a",
            crate::cluster::ConnRef::new(connection, "local"),
        )
        .await
        .unwrap()
        .0
}

fn ack(f: &Fixture, feed: &Stored, cursor: u64, results: Value) -> ControlAck {
    let ToStation::ControlAck(ack) = ToStation::decode(
        json!({
            "type":"relay", "op":"control_ack", "account_id":f.log.account_id(),
            "genesis_hash":f.log.genesis_hash().to_hex(), "host_id":"host-a", "host_trust_gen":1,
            "origin":ORIGIN, "feed_id":feed.feed_id, "cursor":cursor, "results":results,
        })
        .to_string()
        .as_bytes(),
    )
    .unwrap() else {
        unreachable!()
    };
    ack
}

pub(crate) async fn pending_report(store: &RecoveryStore) -> Fixture {
    let f = fixture();
    f.publish(store).await;
    let (status, reply) = store
        .delegated_operation(&f.log.genesis_hash().to_hex(), "alice", Command::Ensure)
        .await;
    assert_eq!(status, StatusCode::OK);
    let mut local = root(&f);
    ensure(&mut local, ORIGIN, &f.log).unwrap();
    local.delegated.get_mut(ORIGIN).unwrap().feed_id =
        reply.0["feeds"][0]["feed_id"].as_str().unwrap().into();
    let record = record(
        &f,
        &local.delegated[ORIGIN],
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Revoke {
            interrupt_running: false,
        },
    );
    let (status, _) = store
        .delegated_operation(
            &f.log.genesis_hash().to_hex(),
            "alice",
            Command::Publish {
                record,
                revoked_at: f.created,
                covered: vec![],
            },
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    f
}

#[test]
fn report_backoff_and_stop_resume_are_durable_for_the_exact_client_history() {
    let f = fixture();
    let mut root = root(&f);
    ensure(&mut root, ORIGIN, &f.log).unwrap();
    let r = record(
        &f,
        &root.delegated[ORIGIN],
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Revoke {
            interrupt_running: false,
        },
    );
    publish(&mut root, ORIGIN, &f.log, &r, f.created, &[], f.created).unwrap();
    let feed = root.delegated.get_mut(ORIGIN).unwrap();
    let first = feed
        .update_ledger(ORIGIN, &f.log, LedgerUpdate::Tick, f.created)
        .unwrap();
    let id = first["reports"][0]["report_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let after_retry = feed
        .update_ledger(
            ORIGIN,
            &f.log,
            LedgerUpdate::Retry {
                id: id.clone(),
                retry_after_ms: Some(60_000),
            },
            f.created,
        )
        .unwrap();
    assert_eq!(after_retry["reports"], json!([]));
    let mut feed: Stored = serde_json::from_value(serde_json::to_value(feed).unwrap()).unwrap();
    assert_eq!(
        feed.update_ledger(ORIGIN, &f.log, LedgerUpdate::Tick, f.created + 59_999)
            .unwrap()["reports"],
        json!([])
    );
    assert_eq!(
        feed.update_ledger(ORIGIN, &f.log, LedgerUpdate::Tick, f.created + 60_000)
            .unwrap()["reports"],
        first["reports"]
    );
    let old = "s-01234567890123456789012345".to_string();
    let new = "s-11234567890123456789012345".to_string();
    let stopped = vec![
        ReportControlEvent::Resume(old.clone()),
        ReportControlEvent::Stop(old.clone()),
    ];
    assert_eq!(
        feed.reporting_control(ORIGIN, &f.log, &stopped, f.created + 60_000)
            .unwrap()["reports"],
        json!([])
    );
    let mut same = stopped.clone();
    same.push(ReportControlEvent::Resume(old));
    assert_eq!(
        feed.reporting_control(ORIGIN, &f.log, &same, f.created + 60_000)
            .unwrap()["reports"],
        first["reports"]
    );
    let mut other = same.clone();
    other.push(ReportControlEvent::Stop(new.clone()));
    other.push(ReportControlEvent::Resume(
        "s-21234567890123456789012345".into(),
    ));
    let dropped = feed
        .reporting_control(ORIGIN, &f.log, &other, f.created + 60_000)
        .unwrap();
    assert_eq!(dropped["reports"], json!([]));
    assert_eq!(dropped["dropped_reports"], json!([id]));
    assert!(feed.delivery.is_empty());
    assert!(feed
        .reporting_control(ORIGIN, &f.log, &same, f.created + 60_000)
        .is_err());
    let mut corrupt = other;
    corrupt[0] = ReportControlEvent::Resume(new);
    assert!(feed
        .reporting_control(ORIGIN, &f.log, &corrupt, f.created + 60_000)
        .is_err());
}

#[test]
fn empty_own_feed_is_durable_and_uses_the_exact_membership_head() {
    let f = fixture();
    let mut root = root(&f);
    ensure(&mut root, ORIGIN, &f.log).unwrap();
    let first = heads(&root, ORIGIN, &f.log, f.created).unwrap();
    assert_eq!(first["feeds"].as_array().unwrap().len(), 1);
    assert_eq!(first["feeds"][0]["head"], 0);
    assert_eq!(first["membership"], f.log.head().to_json());
    let mut restarted: Root = serde_json::from_slice(&serde_json::to_vec(&root).unwrap()).unwrap();
    ensure(&mut restarted, ORIGIN, &f.log).unwrap();
    assert_eq!(first, heads(&restarted, ORIGIN, &f.log, f.created).unwrap());
    assert!(matches!(
        ToHost::decode(first.to_string().as_bytes()),
        Ok(ToHost::Heads(_))
    ));
}

#[tokio::test]
async fn native_status_counts_all_effects_not_cursor_and_survives_restart() {
    let f = fixture();
    let store = RecoveryStore::memory();
    f.publish(&store).await;
    let binding = admit(&store, &f, "native-status").await;
    let mut root = root(&f);
    ensure(&mut root, ORIGIN, &f.log).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let service = record(&f, &root.delegated[ORIGIN], &id,
        ControlAction::Revoke { interrupt_running: true });
    let mut body = service.body().clone();
    body.signer = ControlSigner::Member("phone".into());
    let native = build_control(&f.keys, &KeyId::new("manager"), &body).unwrap();
    let native = ControlRecord::from_signed(native).unwrap();
    publish(&mut root, ORIGIN, &f.log, &native, f.created, &["host-a".into()], f.created).unwrap();
    let unknown = uuid::Uuid::new_v4().to_string();
    let status = |root: &Root| root.delegated[ORIGIN]
        .native_status(ORIGIN, &f.log, &[id.clone(), unknown.clone()]).unwrap();
    assert_eq!(status(&root)["records"][0]["state"], "awaiting_application");
    assert_eq!(status(&root)["records"][1]["state"], "unknown");
    let cursor = ack(&f, &root.delegated[ORIGIN], 1, json!([]));
    acknowledge(&mut root, ORIGIN, &f.log, &binding, &cursor, f.created).unwrap();
    assert_eq!(status(&root)["records"][0]["state"], "awaiting_application");
    let refused = ack(&f, &root.delegated[ORIGIN], 1, json!([
        {"record_id":id,"effects":[
            {"effect":"revocation","result":"refused","why":"removed_manager"},
            {"effect":"interrupt","result":"refused","why":"removed_manager"}]}]));
    acknowledge(&mut root, ORIGIN, &f.log, &binding, &refused, f.created).unwrap();
    assert_eq!(status(&root)["records"][0]["state"], "awaiting_application");
    for (result, expected) in [("pending", "awaiting_application"), ("applied", "effects_reported")] {
        let ack = ack(&f, &root.delegated[ORIGIN], 1, json!([
            {"record_id":id,"effects":[
                {"effect":"revocation","result":"applied"},
                {"effect":"interrupt","result":result}]}]));
        acknowledge(&mut root, ORIGIN, &f.log, &binding, &ack, f.created).unwrap();
        let restarted: Root = serde_json::from_slice(&serde_json::to_vec(&root).unwrap()).unwrap();
        assert_eq!(status(&restarted)["records"][0]["state"], expected);
        assert_eq!(status(&restarted)["head"], f.log.head().to_json());
    }
}

#[test]
fn publication_conflicts_and_signature_failures_never_become_visible() {
    let f = fixture();
    let mut root = root(&f);
    ensure(&mut root, ORIGIN, &f.log).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let cover = record(&f, &root.delegated[ORIGIN], &id, ControlAction::Cover);
    assert!(publish(&mut root, ORIGIN, &f.log, &cover, f.created, &[], f.created).unwrap());
    assert!(!publish(&mut root, ORIGIN, &f.log, &cover, f.created, &[], f.created).unwrap());
    let conflict = record(&f, &root.delegated[ORIGIN], &id, ControlAction::Hold);
    assert!(publish(
        &mut root,
        ORIGIN,
        &f.log,
        &conflict,
        f.created,
        &[],
        f.created
    )
    .is_err());
    assert_eq!(root.delegated[ORIGIN].records.len(), 1);
    let mut wire = cover.object().to_json();
    wire["body"]["record_id"] = json!(uuid::Uuid::new_v4().to_string());
    let tampered = ControlRecord::parse(wire.to_string().as_bytes()).unwrap();
    assert!(publish(
        &mut root,
        ORIGIN,
        &f.log,
        &tampered,
        f.created,
        &[],
        f.created
    )
    .is_err());
    assert_eq!(root.delegated[ORIGIN].records.len(), 1);
}

#[test]
fn signing_time_reservations_survive_restart_and_clock_rollback() {
    let f = fixture();
    let mut root = root(&f);
    ensure(&mut root, ORIGIN, &f.log).unwrap();
    assert_eq!(
        reserve(&mut root, ORIGIN, &f.log, "service:svc-test", 100).unwrap(),
        100
    );
    let mut root: Root = serde_json::from_slice(&serde_json::to_vec(&root).unwrap()).unwrap();
    assert_eq!(
        reserve(&mut root, ORIGIN, &f.log, "service:svc-test", 99).unwrap(),
        101
    );
    assert_eq!(
        reserve(&mut root, ORIGIN, &f.log, "service:svc-test", 101).unwrap(),
        102
    );
}

#[test]
fn membership_freeze_blocks_new_authority_but_keeps_committed_report_settlement() {
    let f = fixture();
    let mut root = root(&f);
    ensure(&mut root, ORIGIN, &f.log).unwrap();
    let r = record(
        &f,
        &root.delegated[ORIGIN],
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Revoke {
            interrupt_running: false,
        },
    );
    publish(&mut root, ORIGIN, &f.log, &r, f.created, &[], f.created).unwrap();
    let id = root.delegated[ORIGIN]
        .ledger(ORIGIN, &f.log)
        .unwrap()
        .pending_reports()[0]
        .report_id
        .clone();
    let genesis = Membership::from_genesis(
        f.log.account_id(),
        &f.log.genesis_hash(),
        f.log.entries()[0].clone(),
    )
    .unwrap();
    let fork = sign_entry(
        &f.keys,
        &KeyId::new("manager"),
        genesis.draft(
            "phone",
            f.created + 1,
            &atem_client::membership::Action::AddHost {
                host: atem_client::membership::entry::HostRecord {
                    host_id: "host-b".into(),
                    host_trust_gen: 1,
                    host_key: f.keys.public_key(&f.host_key).unwrap(),
                },
            },
        ),
    )
    .unwrap();
    let frozen = f
        .log
        .evaluate_objects(
            &[fork.object().clone()],
            &HostNow {
                wall_ms: f.created + 1,
                mono_ms: 1,
                boot_id: "test".into(),
            },
        )
        .next;
    assert!(frozen.frozen().is_some());
    assert!(apply(
        &mut root,
        &frozen,
        ORIGIN,
        None,
        Command::Reserve {
            principal: "service:svc-test".into()
        },
        f.created
    )
    .is_err());
    let settled = apply(
        &mut root,
        &frozen,
        ORIGIN,
        None,
        Command::Ledger(LedgerUpdate::Confirm(id)),
        f.created,
    )
    .unwrap();
    assert_eq!(settled["reports"], json!([]));
}

#[test]
fn pages_keep_correlation_and_do_not_turn_a_lower_head_into_progress() {
    let f = fixture();
    let mut root = root(&f);
    ensure(&mut root, ORIGIN, &f.log).unwrap();
    for _ in 0..70 {
        let r = record(
            &f,
            &root.delegated[ORIGIN],
            &uuid::Uuid::new_v4().to_string(),
            ControlAction::Cover,
        );
        publish(&mut root, ORIGIN, &f.log, &r, f.created, &[], f.created).unwrap();
    }
    let call = sync(Some(&root.delegated[ORIGIN]), 0);
    let page = response(&root, ORIGIN, &f.log, &call, f.created)
        .unwrap()
        .unwrap();
    let ToHost::ControlSyncResult(parsed) = ToHost::decode(page.to_string().as_bytes()).unwrap()
    else {
        unreachable!()
    };
    let ToStation::ControlSync(request) = call else {
        unreachable!()
    };
    assert!(parsed.answers(&request).is_ok());
    assert_eq!(parsed.records.len(), 64);
    assert!(page.to_string().len() <= 262144);
    let retry = sync(Some(&root.delegated[ORIGIN]), 0);
    let ToStation::ControlSync(retry) = retry else {
        unreachable!()
    };
    assert!(parsed.answers(&retry).is_err());
    let beyond = sync(Some(&root.delegated[ORIGIN]), 100);
    let page = response(&root, ORIGIN, &f.log, &beyond, f.created)
        .unwrap()
        .unwrap();
    assert_eq!(page["after"], 100);
    assert_eq!(page["head"], 70);
    assert_eq!(page["records"], json!([]));
}

#[test]
fn wrong_origin_and_feed_get_only_the_metadata_free_refusal() {
    let f = fixture();
    let mut root = root(&f);
    ensure(&mut root, ORIGIN, &f.log).unwrap();
    for (origin, feed_id) in [
        ("https://other.example", None),
        (ORIGIN, Some(uuid::Uuid::new_v4().to_string())),
    ] {
        let call = ToStation::ControlSync(ControlSync {
            request_id: uuid::Uuid::new_v4().to_string(),
            origin: origin.into(),
            feed_id,
            after: 0,
        });
        let fault = response(&root, ORIGIN, &f.log, &call, f.created).unwrap_err();
        assert_eq!(
            fault.refusal().unwrap(),
            json!({"type":"relay","op":"control_sync_refused","code":"forbidden"})
        );
    }
}

#[tokio::test]
async fn ack_is_atomic_cursor_alone_counts_nothing_and_restart_replays_one_report() {
    let f = fixture();
    let store = RecoveryStore::memory();
    f.publish(&store).await;
    let binding = admit(&store, &f, "current").await;
    let mut root = root(&f);
    ensure(&mut root, ORIGIN, &f.log).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let record = record(
        &f,
        &root.delegated[ORIGIN],
        &id,
        ControlAction::Revoke {
            interrupt_running: false,
        },
    );
    publish(
        &mut root,
        ORIGIN,
        &f.log,
        &record,
        f.created,
        &["host-a".into()],
        f.created,
    )
    .unwrap();
    let cursor_only = ack(&f, &root.delegated[ORIGIN], 1, json!([]));
    acknowledge(&mut root, ORIGIN, &f.log, &binding, &cursor_only, f.created).unwrap();
    assert!(root.delegated[ORIGIN]
        .ledger(ORIGIN, &f.log)
        .unwrap()
        .pending_reports()
        .is_empty());
    let second_id = uuid::Uuid::new_v4().to_string();
    let second = self::record(
        &f,
        &root.delegated[ORIGIN],
        &second_id,
        ControlAction::Revoke {
            interrupt_running: false,
        },
    );
    publish(
        &mut root,
        ORIGIN,
        &f.log,
        &second,
        f.created,
        &["host-a".into()],
        f.created,
    )
    .unwrap();
    let before = serde_json::to_value(&root).unwrap();
    let invalid = ack(
        &f,
        &root.delegated[ORIGIN],
        1,
        json!([
        {"record_id":id,"effects":[{"effect":"revocation","result":"applied"}]},
        {"record_id":second_id,"effects":[{"effect":"interrupt","result":"applied"}]}]),
    );
    assert!(acknowledge(&mut root, ORIGIN, &f.log, &binding, &invalid, f.created).is_err());
    assert_eq!(serde_json::to_value(&root).unwrap(), before);
    let valid = ack(
        &f,
        &root.delegated[ORIGIN],
        1,
        json!([
        {"record_id":id,"effects":[{"effect":"revocation","result":"applied"}]}]),
    );
    acknowledge(&mut root, ORIGIN, &f.log, &binding, &valid, f.created).unwrap();
    let reports = root.delegated[ORIGIN]
        .ledger(ORIGIN, &f.log)
        .unwrap()
        .pending_reports();
    assert_eq!(reports.len(), 1);
    let mut restarted: Root = serde_json::from_slice(&serde_json::to_vec(&root).unwrap()).unwrap();
    acknowledge(
        &mut restarted,
        ORIGIN,
        &f.log,
        &binding,
        &valid,
        f.created + 1,
    )
    .unwrap();
    assert_eq!(
        restarted.delegated[ORIGIN]
            .ledger(ORIGIN, &f.log)
            .unwrap()
            .pending_reports(),
        reports
    );
    let mut cross_account = valid.clone();
    cross_account.account_id = "other-account".into();
    let before = serde_json::to_value(&restarted).unwrap();
    let fault = acknowledge(
        &mut restarted,
        ORIGIN,
        &f.log,
        &binding,
        &cross_account,
        f.created,
    )
    .unwrap_err();
    assert_eq!(
        fault.refusal().unwrap(),
        json!({"type":"relay","op":"control_ack_refused","code":"forbidden"})
    );
    assert_eq!(serde_json::to_value(&restarted).unwrap(), before);
}

#[cfg(feature = "delegated-host-work")]
#[tokio::test]
async fn a_replaced_association_cannot_read_or_commit_evidence() {
    let f = fixture();
    let store = RecoveryStore::memory();
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    f.publish(&store).await;
    let old = admit(&store, &f, "old").await;
    assert!(store.prepare_delegated(&old).await);
    let current = admit(&store, &f, "replacement").await;
    let mut wrote = false;
    let reply = store
        .with_delegated_response(&old, None, |_| {
            wrote = true;
            std::future::ready(())
        })
        .await;
    assert!(reply.is_none());
    assert!(!wrote);
    assert!(store.prepare_delegated(&current).await);
    assert!(!store.prepare_delegated(&old).await);
}

#[test]
fn shared_station_wire_goldens_use_the_actual_strict_readers() {
    let vectors: Value = serde_json::from_str(include_str!(
        "fixtures/delegated/r9-vectors-station-calls.json"
    ))
    .unwrap();
    let wire = |v: &Value| -> String {
        if let Some(w) = v["wire"].as_str() {
            return w.into();
        }
        let fill = &v["wire_fill"];
        format!(
            "{}{}{}",
            fill["prefix"].as_str().unwrap(),
            fill["fill"]
                .as_str()
                .unwrap()
                .repeat(fill["count"].as_u64().unwrap() as usize),
            fill["suffix"].as_str().unwrap()
        )
    };
    for v in vectors["calls"]
        .as_array()
        .unwrap()
        .iter()
        .chain(vectors["at_the_bound"].as_array().unwrap())
    {
        let text = wire(v);
        if v["direction"] == "to_station" {
            ToStation::decode(text.as_bytes()).unwrap();
        } else {
            ToHost::decode(text.as_bytes()).unwrap();
        }
    }
    for v in vectors["invalid"].as_array().unwrap() {
        let text = wire(v);
        if v["reader"] == "to_station" {
            assert!(ToStation::decode(text.as_bytes()).is_err(), "{}", v["name"]);
        } else {
            assert!(ToHost::decode(text.as_bytes()).is_err(), "{}", v["name"]);
        }
    }
}

#[cfg(feature = "delegated-host-work")]
#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_replicas_create_one_feed_and_restart_preserves_records() {
    let database =
        crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 8).await;
    let a = RecoveryStore::postgres(database.pool.clone());
    let b = RecoveryStore::postgres(database.reconnect(4).await);
    let (one, two) = tokio::join!(a.configure_delegated(ORIGIN, 1), b.configure_delegated(ORIGIN, 1));
    one.unwrap();
    two.unwrap();
    let f = fixture();
    f.publish(&a).await;
    let binding = admit(&a, &f, "shared").await;
    let (one, two) = tokio::join!(a.prepare_delegated(&binding), b.prepare_delegated(&binding));
    assert!(one && two);
    let read = |result: Result<Option<Value>, Fault>| std::future::ready(result.unwrap().unwrap());
    let first = a
        .with_delegated_response(&binding, None, read)
        .await
        .unwrap();
    let second = b
        .with_delegated_response(&binding, None, read)
        .await
        .unwrap();
    assert_eq!(first["feeds"][0]["feed_id"], second["feeds"][0]["feed_id"]);
    let encoded: Value =
        sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
            .bind(f.log.genesis_hash().to_hex())
            .fetch_one(&database.pool)
            .await
            .unwrap();
    let saved: Root = serde_json::from_value(encoded).unwrap();
    let r = record(
        &f,
        &saved.delegated[ORIGIN],
        &uuid::Uuid::new_v4().to_string(),
        ControlAction::Cover,
    );
    let append = || Operation::Delegated {
        origin: ORIGIN.into(),
        binding: None,
        command: Command::Publish {
            record: r.clone(),
            revoked_at: f.created,
            covered: vec![],
        },
    };
    let (one, two) = tokio::join!(
        a.perform(&binding.genesis, "alice", append()),
        b.perform(&binding.genesis, "alice", append())
    );
    assert_eq!(one.0, StatusCode::OK);
    assert_eq!(two.0, StatusCode::OK);
    assert_ne!(one.1 .0["appended"], two.1 .0["appended"]);
    drop(a);
    drop(b);
    let restarted = RecoveryStore::postgres(database.reconnect(4).await);
    restarted.configure_delegated(ORIGIN, 1).await.unwrap();
    let heads = restarted
        .with_delegated_response(&binding, None, read)
        .await
        .unwrap();
    assert_eq!(heads["feeds"][0]["head"], 1);
    assert_eq!(heads["feeds"][0]["feed_id"], first["feeds"][0]["feed_id"]);
    let denied = restarted
        .perform(&binding.genesis, "other-owner", append())
        .await;
    assert_eq!(denied.0, StatusCode::NOT_FOUND);
    drop(restarted);
    database.cleanup().await;
}

#[cfg(feature = "delegated-host-work")]
#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_failed_ack_commit_leaks_no_evidence_and_retry_settles_once() {
    let database =
        crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    let f = fixture();
    f.publish(&store).await;
    let binding = admit(&store, &f, "proved").await;
    assert!(store.prepare_delegated(&binding).await);
    let saved: Value =
        sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
            .bind(&binding.genesis)
            .fetch_one(&database.pool)
            .await
            .unwrap();
    let root: Root = serde_json::from_value(saved).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let record = record(
        &f,
        &root.delegated[ORIGIN],
        &id,
        ControlAction::Revoke {
            interrupt_running: false,
        },
    );
    assert_eq!(
        store
            .delegated_operation(
                &binding.genesis,
                "alice",
                Command::Publish {
                    record,
                    revoked_at: f.created,
                    covered: vec!["host-a".into()]
                }
            )
            .await
            .0,
        StatusCode::OK
    );
    let ack = ack(
        &f,
        &root.delegated[ORIGIN],
        1,
        json!([
        {"record_id":id,"effects":[{"effect":"revocation","result":"applied"}]}]),
    );
    sqlx::query("CREATE FUNCTION fail_ack_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test ACK commit failure'; END $$")
        .execute(&database.pool).await.unwrap();
    sqlx::query("CREATE CONSTRAINT TRIGGER fail_ack_commit AFTER UPDATE ON remote_recovery_roots DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_ack_commit()")
        .execute(&database.pool).await.unwrap();
    assert_eq!(
        store.acknowledge_delegated(&binding, ack.clone()).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    let saved: Value =
        sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
            .bind(&binding.genesis)
            .fetch_one(&database.pool)
            .await
            .unwrap();
    let root: Root = serde_json::from_value(saved).unwrap();
    assert!(root.delegated[ORIGIN]
        .ledger(ORIGIN, &f.log)
        .unwrap()
        .pending_reports()
        .is_empty());
    sqlx::query("DROP TRIGGER fail_ack_commit ON remote_recovery_roots")
        .execute(&database.pool)
        .await
        .unwrap();
    assert_eq!(
        store.acknowledge_delegated(&binding, ack.clone()).await.0,
        StatusCode::OK
    );
    let first = store
        .delegated_operation(
            &binding.genesis,
            "alice",
            Command::Ledger(LedgerUpdate::Tick),
        )
        .await
        .1
         .0;
    assert_eq!(first["reports"].as_array().unwrap().len(), 1);
    assert_eq!(
        store.acknowledge_delegated(&binding, ack).await.0,
        StatusCode::OK
    );
    assert_eq!(
        store
            .delegated_operation(
                &binding.genesis,
                "alice",
                Command::Ledger(LedgerUpdate::Tick)
            )
            .await
            .1
             .0["reports"],
        first["reports"]
    );
    drop(store);
    database.cleanup().await;
}

#[cfg(feature = "delegated-host-work")]
#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_report_scan_is_bounded_and_selects_only_this_stations_feeds() {
    let database =
        crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
    let store = RecoveryStore::postgres(database.pool.clone());
    store.configure_delegated(ORIGIN, 1).await.unwrap();
    let other_station = RecoveryStore::postgres(database.reconnect(2).await);
    other_station
        .configure_delegated("https://another.example", 1).await
        .unwrap();
    let mut expected = Vec::new();
    for index in 0..35 {
        let f = fixture();
        let owner = format!("owner-{index}");
        for entry in f.log.entries() {
            assert_eq!(
                store
                    .append_test_entry(
                        &f.log.genesis_hash().to_hex(),
                        &owner,
                        entry.clone(),
                        atem_client::membership::Head {
                            seq: entry.seq - 1,
                            hash: entry.prev_hash
                        }
                    )
                    .await,
                StatusCode::OK
            );
        }
        let (status, _) = store
            .delegated_operation(&f.log.genesis_hash().to_hex(), &owner, Command::Ensure)
            .await;
        assert_eq!(status, StatusCode::OK);
        expected.push((f.log.genesis_hash().to_hex(), owner));
    }
    let without_feed = fixture();
    without_feed.publish(&store).await;
    let other_root = fixture();
    other_root.publish(&other_station).await;
    assert_eq!(
        other_station
            .delegated_operation(
                &other_root.log.genesis_hash().to_hex(),
                "alice",
                Command::Ensure
            )
            .await
            .0,
        StatusCode::OK
    );
    expected.sort();
    let first = store.delegated_accounts("").await.unwrap();
    assert_eq!(first, expected[..32]);
    let second = store
        .delegated_accounts(&first.last().unwrap().0)
        .await
        .unwrap();
    assert_eq!(second, expected[32..]);
    assert!(store
        .delegated_accounts(&second.last().unwrap().0)
        .await
        .unwrap()
        .is_empty());
    drop(other_station);
    drop(store);
    database.cleanup().await;
}
