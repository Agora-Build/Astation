use super::*;
use crate::integration_portal::tests::Fixture as Portal;
use crate::station_integrations::tests::OWNER;

// Keep the exact stored reports. A retry uses the same body and a later
// native transition must also wait for an intervening admin release.
async fn transitions(runtime: &StationIntegrations, account: &str, genesis: &str) -> Vec<Value> {
    let binding = &runtime.binding;
    let mut reports = Vec::new();
    for (version, state) in [(1_i64, "bound"), (2, "released"), (3, "bound")] {
        let report = json!({"reportId":format!("binding_changed:{account}-{version}"), "state":"binding_changed",
            "account":OWNER,"accountId":account,"genesisHash":genesis,"bindingId":"binding-id",
            "bindingState":state,"version":version});
        if state == "released" {
            sqlx::query("INSERT INTO station_binding_release_requests
                (issuer,portal_origin,station_origin,release_id,account,account_id,genesis,binding_id,version)
                VALUES($1,$2,$3,$4,$5,$4,$6,'binding-id',1)")
                .bind(&binding.issuer).bind(&binding.portal_origin).bind(&binding.station_origin)
                .bind(account).bind(OWNER).bind(genesis).execute(&runtime.policies.0).await.unwrap();
            sqlx::query(
                "INSERT INTO station_applied_binding_releases
                (issuer,portal_origin,station_origin,release_id,account_id,genesis,version,report)
                VALUES($1,$2,$3,$4,$4,$5,2,$6)",
            )
            .bind(&binding.issuer)
            .bind(&binding.portal_origin)
            .bind(&binding.station_origin)
            .bind(account)
            .bind(genesis)
            .bind(&report)
            .execute(&runtime.policies.0)
            .await
            .unwrap();
        } else {
            sqlx::query("INSERT INTO station_native_binding_transitions
                (issuer,portal_origin,station_origin,account_id,genesis,version,nonce,proof_hash,report,retired_routes)
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'[]')")
                .bind(&binding.issuer).bind(&binding.portal_origin).bind(&binding.station_origin)
                .bind(account).bind(genesis).bind(version).bind(uuid::Uuid::new_v4().to_string())
                .bind(&[0u8; 32][..]).bind(&report).execute(&runtime.policies.0).await.unwrap();
        }
        reports.push(report);
    }
    reports
}

#[tokio::test]
#[ignore = "requires isolated Postgres"]
async fn postgres_delegated_binding_delivery_orders_native_and_release_reports_across_replicas() {
    let mut portal = Portal::new().await;
    portal.binding.station_origin = "https://station-dev.agora.build".into();
    let (db, mut runtime, _) = super::super::tests::fixture().await;
    let station = Arc::get_mut(&mut runtime).unwrap();
    station.binding = portal.binding.clone();
    station.portal = portal.client();
    station
        .app
        .recovery
        .configure_delegated(&station.binding.station_origin, 1)
        .await
        .unwrap();
    station.initialize_report_control(None).await.unwrap();
    let reports = transitions(station, "acct-first", &"a".repeat(64)).await;

    portal.set_status(503);
    station.deliver_reports(ReportQueue::Ownership).await;
    assert_eq!(*portal.shared.reports.lock().await, reports[..1]);
    station.deliver_reports(ReportQueue::Ownership).await;
    assert_eq!(
        *portal.shared.reports.lock().await,
        reports[..1],
        "later versions cannot pass a delayed retry"
    );

    let other = transitions(station, "acct-second", &"b".repeat(64)).await;
    portal.set_status(409);
    // A permanent refusal settles this report. It may advance this list only.
    station.deliver_reports(ReportQueue::Ownership).await;
    assert_eq!(portal.shared.reports.lock().await[1..], other);
    let refused: Vec<String> = sqlx::query_scalar("SELECT report_outcome FROM station_native_binding_transitions
        WHERE account_id='acct-second' UNION ALL SELECT report_outcome FROM station_applied_binding_releases
        WHERE account_id='acct-second'").fetch_all(&db.pool).await.unwrap();
    assert_eq!(refused, ["refused"; 3]);

    sqlx::query("UPDATE station_native_binding_transitions SET report_due=now() WHERE account_id='acct-first' AND version=1")
        .execute(&db.pool).await.unwrap();
    portal.set_status(403);
    station.deliver_reports(ReportQueue::Ownership).await;
    let stopped = portal.shared.reports.lock().await.clone();
    assert_eq!(stopped.last(), Some(&reports[0]));
    let reopened = db.reconnect(4).await;
    station.policies = PolicyStore(reopened.clone());
    station.initialize_report_control(None).await.unwrap();
    portal.set_status(200);
    station.deliver_reports(ReportQueue::Ownership).await;
    assert_eq!(*portal.shared.reports.lock().await, stopped);
    station
        .initialize_report_control(Some(&uuid::Uuid::new_v4().to_string()))
        .await
        .unwrap();
    tokio::join!(
        station.deliver_reports(ReportQueue::Ownership),
        station.deliver_reports(ReportQueue::Ownership)
    );
    assert_eq!(portal.shared.reports.lock().await[stopped.len()..], reports);
    let remaining: i64 = sqlx::query_scalar("SELECT count(*) FROM station_pending_binding_reports")
        .fetch_one(&reopened)
        .await
        .unwrap();
    assert_eq!(remaining, 0);
    reopened.close().await;
    db.cleanup().await;
}
