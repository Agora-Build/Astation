use super::*;
use crate::remote_api::recovery::delegated::{
    Command, LedgerUpdate, ReportControlEvent, ServiceDesired,
};
use crate::remote_api::recovery::delegated_recovery::plan::reporting_history::reconcile_report_restart;
use atem_client::control::{AckLedger, ReportAnswer, ReportIntent};
use super::binding_reports::BindingReport;

#[derive(Clone, Copy)]
enum ReportQueue<'a> {
    Revocation { genesis: &'a str, owner: &'a str },
    Ownership,
}


enum PendingReport<'a> {
    Revocation { genesis: &'a str, owner: &'a str, intent: ReportIntent },
    Ownership(BindingReport),
}

impl StationIntegrations {
    pub(super) async fn reconcile_delegated_services(&self) {
        let Ok(checkpoint) = self.policies.load(&self.binding).await else {
            return;
        };
        let candidates: Vec<_> = checkpoint
            .integrations
            .iter()
            .filter(|(_, policy)| policy.r9_svc.is_some())
            .map(|(id, _)| id)
            .collect();
        if candidates.is_empty() {
            return;
        }
        let start = self
            .control_offset
            .fetch_add(8, std::sync::atomic::Ordering::Relaxed)
            % candidates.len();
        for offset in 0..candidates.len().min(8) {
            let id = candidates[(start + offset) % candidates.len()];
            let _ = tokio::time::timeout(
                Duration::from_secs(10),
                self.reconcile_delegated_service(id),
            )
            .await;
        }
    }

    async fn reconcile_delegated_service(&self, id: &str) -> Result<(), ()> {
        let context = self.context(id).await.map_err(|_| ())?;
        let principal = self.owner_principal(&context.owner).await.map_err(|_| ())?;
        let mut tx = self.policies.0.begin().await.map_err(|_| ())?;
        // Serialize with authenticated policy replacement. A delayed resume
        // cannot sign a release after a newer pause or revoke was committed.
        let saved: String = sqlx::query_scalar(
            "SELECT checkpoint FROM station_integration_policy WHERE binding=$1 FOR UPDATE",
        )
        .bind(serde_json::to_string(&self.binding).map_err(|_| ())?)
        .fetch_one(&mut *tx)
        .await
        .map_err(|_| ())?;
        let checkpoint: crate::integration_feed::PolicyCheckpoint =
            serde_json::from_str(&saved).map_err(|_| ())?;
        if checkpoint.binding != self.binding {
            return Err(());
        }
        let policy = checkpoint.owned(id, &context.owner, chrono::Utc::now().timestamp())?;
        // Expiry changes API access only and cannot release an earlier hold.
        let Some(desired) = ServiceDesired::from_policy(policy) else { return Ok(()) };
        let signer = crate::service_keys::load_approved_in(
            &mut tx,
            &self.vault,
            &context,
            policy.r9_svc.as_deref().ok_or(())?,
        )
        .await?;
        let recovery = &self.app.recovery;
        let published = recovery
            .reconcile_service_in(&mut tx, &principal, &context, &signer, desired, &checkpoint)
            .await?;
        tx.commit().await.map_err(|_| ())?;
        if published {
            recovery.notify_delegated_change();
        }
        Ok(())
    }

    pub(super) async fn run_delegated_reports(self: Arc<Self>) {
        let resume = std::env::var("STATION_DELEGATED_REPORT_RESUME_CLIENT")
            .ok()
            .filter(|client| client == &self.binding.report_client_id)
            .and_then(|_| std::env::var("STATION_DELEGATED_REPORT_RESUME_ID").ok());
        if self
            .initialize_report_control(resume.as_deref())
            .await
            .is_err()
        {
            tracing::error!(
                "delegated reporting disabled: cannot initialize durable report-client fence"
            );
            return;
        }
        let mut after = String::new();
        loop {
            if self.app.recovery.active_delegated_binding().is_some_and(|fence| fence.origin == self.binding.station_origin)
                && crate::integration_checkpoint::PortalCheckpoint::built_in(&self.binding) {
                self.deliver_reports(ReportQueue::Ownership).await;
            }
            let Some(accounts) = self.app.recovery.delegated_accounts(&after).await else {
                tokio::time::sleep(Duration::from_secs(5)).await;
                continue;
            };
            if accounts.is_empty() {
                after.clear();
                tokio::time::sleep(Duration::from_secs(5)).await;
                continue;
            }
            for (genesis, owner) in accounts {
                after = genesis.clone();
                let _ = tokio::time::timeout(
                    Duration::from_secs(30),
                    self.deliver_delegated_reports(&genesis, &owner),
                )
                .await;
            }
            tokio::task::yield_now().await;
        }
    }

    async fn initialize_report_control(&self, resume: Option<&str>) -> Result<(), ()> {
        let resume = resume
            .map(uuid::Uuid::parse_str)
            .transpose()
            .map_err(|_| ())?;
        let key = self.binding.report_control_binding();
        let mut tx = self.policies.0.begin().await.map_err(|_| ())?;
        self.app.recovery.lock_delegated_recovery(&mut tx).await.map_err(|_| ())?;
        let initial = vec![ReportControlEvent::Resume(
            self.binding.report_client_id.clone(),
        )];
        sqlx::query("INSERT INTO station_delegated_reporting(binding,events) VALUES ($1,$2) ON CONFLICT DO NOTHING")
            .bind(&key).bind(serde_json::to_value(&initial).map_err(|_| ())?)
            .execute(&mut *tx).await.map_err(|_| ())?;
        let (value, in_flight): (Value, Option<String>) = sqlx::query_as(
            "SELECT events,in_flight FROM station_delegated_reporting WHERE binding=$1 FOR UPDATE",
        )
        .bind(&key)
        .fetch_one(&mut *tx)
        .await
        .map_err(|_| ())?;
        let mut events: Vec<ReportControlEvent> = serde_json::from_value(value).map_err(|_| ())?;
        let needs_resume = reconcile_report_restart(
            &mut tx, &self.binding, &events, in_flight.as_deref(),
        ).await.map_err(|_| ())?;
        let fresh_resume = if let Some(id) = resume {
            sqlx::query("INSERT INTO station_delegated_report_resumptions(binding,resume_id) VALUES ($1,$2::uuid) ON CONFLICT DO NOTHING")
                .bind(&key).bind(id.to_string()).execute(&mut *tx).await.map_err(|_| ())?.rows_affected() == 1
        } else {
            false
        };
        if needs_resume && !fresh_resume && events.last() == initial.last() {
            return Err(());
        }
        if fresh_resume {
            if let Some(ReportControlEvent::Resume(old)) = events.last().cloned() {
                events.push(ReportControlEvent::Stop(old));
            }
            events.extend(initial);
            sqlx::query(
                "UPDATE station_delegated_reporting SET events=$1,in_flight=NULL WHERE binding=$2",
            )
            .bind(serde_json::to_value(events).map_err(|_| ())?)
            .bind(&key)
            .execute(&mut *tx)
            .await
            .map_err(|_| ())?;
        }
        tx.commit().await.map_err(|_| ())
    }

    async fn deliver_delegated_reports(&self, genesis: &str, owner: &str) {
        self.deliver_reports(ReportQueue::Revocation { genesis, owner }).await;
    }

    async fn deliver_reports(&self, queue: ReportQueue<'_>) {
        // Re-read after each settlement: a final cannot overtake a per-host
        // report, including when another replica settles that report first.
        for _ in 0..8 {
            let Ok(mut tx) = self.policies.0.begin().await else {
                return;
            };
            if self.app.recovery.lock_delegated_recovery(&mut tx).await.is_err() {
                return;
            }
            let key = self.binding.report_control_binding();
            let Ok((value, in_flight)) = sqlx::query_as::<_, (Value, Option<String>)>(
                "SELECT events,in_flight FROM station_delegated_reporting WHERE binding=$1 FOR UPDATE")
                .bind(&key).fetch_one(&mut *tx).await else { return };
            // A lost response may have been a 403. Never send again after an
            // interrupted delivery until a new, explicit operator resume.
            if in_flight.is_some() {
                return;
            }
            let Ok(mut events) = serde_json::from_value::<Vec<ReportControlEvent>>(value) else {
                return;
            };
            let resumed = events.last() == Some(&ReportControlEvent::Resume(self.binding.report_client_id.clone()));
            let pending = match queue {
                ReportQueue::Revocation { genesis, owner } => {
                    let Ok((status, Json(snapshot))) = self.app.recovery.delegated_operation_in(
                        &mut tx, genesis, owner, Command::ReportingControl(events.clone())).await else { return };
                    if status != StatusCode::OK { return; }
                    let Ok(ledger) = AckLedger::from_json(&snapshot["ledger"]) else { return };
                    let due = ledger.pending_reports().into_iter().find(|intent| {
                        snapshot["reports"].as_array().is_some_and(|reports| reports.iter()
                            .any(|value| value["report_id"] == intent.report_id))
                    });
                    let Some(intent) = due.filter(|_| resumed && ledger.stopped_client_id().is_none()) else {
                        let _ = tx.commit().await;
                        return;
                    };
                    PendingReport::Revocation { genesis, owner, intent }
                }
                ReportQueue::Ownership => {
                    if !resumed { return; }
                    let Ok(Some(report)) = BindingReport::next(&mut tx, &self.binding).await else { return };
                    PendingReport::Ownership(report)
                }
            };
            let claim = uuid::Uuid::new_v4().to_string();
            if sqlx::query("UPDATE station_delegated_reporting SET in_flight=$1 WHERE binding=$2")
                .bind(&claim)
                .bind(&key)
                .execute(&mut *tx)
                .await
                .is_err()
            {
                return;
            }
            if tx.commit().await.is_err() {
                return;
            }

            // Persist the marker before network I/O, then lock it through
            // settlement so an operator resume cannot race an active request.
            let Ok(mut tx) = self.policies.0.begin().await else {
                return;
            };
            if self.app.recovery.lock_delegated_recovery(&mut tx).await.is_err() {
                return;
            }
            let Ok(saved_claim) = sqlx::query_scalar::<_, Option<String>>(
                "SELECT in_flight FROM station_delegated_reporting WHERE binding=$1 FOR UPDATE",
            )
            .bind(&key)
            .fetch_one(&mut *tx)
            .await
            else {
                return;
            };
            if saved_claim.as_ref() != Some(&claim) {
                return;
            }
            let result = match &pending {
                PendingReport::Revocation { intent, .. } => self.portal.delegated_report(
                    &crate::integration_portal::delegated_report_body(intent)).await,
                PendingReport::Ownership(report) => self.portal.delegated_report(&report.body).await,
            };
            if result.answer == ReportAnswer::StopReporting {
                tracing::error!(client_id = %self.binding.report_client_id, "delegated reporting stopped by Portal");
                events.push(ReportControlEvent::Stop(self.binding.report_client_id.clone()));
                if sqlx::query("UPDATE station_delegated_reporting SET events=$1,in_flight=NULL WHERE binding=$2")
                    .bind(serde_json::to_value(&events).unwrap()).bind(&key)
                    .execute(&mut *tx).await.is_err() || tx.commit().await.is_err() { return; }
                if let ReportQueue::Revocation { genesis, owner } = queue {
                    let _ = self.app.recovery.delegated_operation(genesis, owner, Command::ReportingControl(events)).await;
                }
                return;
            }
            match pending {
                PendingReport::Ownership(report) => {
                    if result.answer == ReportAnswer::Refuse {
                        tracing::error!(report_id = %report.body["reportId"], "ownership report permanently refused");
                    }
                    if report.settle(&mut tx, &self.binding, &result).await.is_err() { return; }
                }
                PendingReport::Revocation { genesis, owner, intent } => {
                    let update = match result.answer {
                        ReportAnswer::Confirm => LedgerUpdate::Confirm(intent.report_id),
                        ReportAnswer::Refuse => {
                            tracing::error!(report_id = %intent.report_id, "delegated report permanently refused");
                            LedgerUpdate::Refuse(intent.report_id)
                        }
                        ReportAnswer::Retry => LedgerUpdate::Retry { id: intent.report_id, retry_after_ms: result.retry_after_ms },
                        ReportAnswer::StopReporting => unreachable!("client stop settled above"),
                    };
                    let Ok((StatusCode::OK, _)) = self.app.recovery
                        .delegated_operation_in(&mut tx, genesis, owner, Command::Ledger(update)).await else { return };
                }
            }
            if sqlx::query("UPDATE station_delegated_reporting SET in_flight=NULL WHERE binding=$1")
                .bind(&key)
                .execute(&mut *tx)
                .await
                .is_err()
            {
                return;
            }
            if tx.commit().await.is_err() {
                return;
            }
            if matches!(
                result.answer,
                ReportAnswer::Retry | ReportAnswer::StopReporting
            ) {
                return;
            }
        }
    }
}

#[cfg(all(test, feature = "delegated-host-work"))]
#[path = "binding_report_tests.rs"]
mod binding_report_tests;

#[cfg(all(test, feature = "delegated-host-work"))]
#[path = "signing_ceiling_tests.rs"]
mod signing_ceiling_tests;

#[cfg(all(test, feature = "delegated-host-work"))]
mod tests {
    use super::super::tests::{ID, OWNER};
    use super::*;
    use crate::remote_api::recovery::delegated::tests::pending_report;

    pub(super) async fn policy(
        runtime: &StationIntegrations,
        state: &str,
        fingerprint: &str,
        interrupt: Option<bool>,
    ) {
        let previous = runtime.policies.load(&runtime.binding).await.unwrap();
        let mut next = previous.clone();
        next.revision += 1;
        next.received_at = chrono::Utc::now().timestamp();
        let policy = next.integrations.get_mut(ID).unwrap();
        policy.state = state.into();
        policy.r9_svc = Some(fingerprint.into());
        policy.interrupt_running = interrupt;
        runtime.policies.commit(&previous, &next).await.unwrap();
    }

    pub(super) async fn feed(runtime: &StationIntegrations, genesis: &str) -> Vec<Value> {
        let state: Value =
            sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
                .bind(genesis)
                .fetch_one(&runtime.policies.0)
                .await
                .unwrap();
        state["delegated"][&runtime.binding.station_origin]["records"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_coverage_ends_only_with_this_snapshots_verified_revoke() {
        use super::super::tests::{append_body, fixture, request};
        use crate::integration_checkpoint::PortalCheckpoint;
        use crate::remote_api::recovery::delegated_recovery::{plan, Binding};

        let (db, runtime, fixture) = fixture().await;
        let genesis = fixture.log.genesis_hash().to_hex();
        let origin = &runtime.binding.station_origin;
        runtime.app.recovery.configure_delegated(origin, 1).await.unwrap();
        let draft = runtime.prepare(ID, OWNER, request(&fixture)).await.unwrap();
        let key = draft["fingerprint"].as_str().unwrap();
        append_body(&runtime, &fixture, serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap()).await;
        policy(&runtime, "ready", key, None).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        policy(&runtime, "revoking", key, Some(false)).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        policy(&runtime, "revoked", key, Some(true)).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        let history = feed(&runtime, &genesis).await;
        assert_eq!(history[1]["body"]["action"], "revoke");
        assert_eq!(history[2]["body"]["action"], "interrupt_running");

        let fence = Binding::new(origin, 2).unwrap();
        fence.initialize(&db.pool, true).await.unwrap();
        let previous = runtime.policies.load(&runtime.binding).await.unwrap();
        let source = json!({"changes":[],"cursor":previous.cursor,"checkpoint":{
            "at":"2026-11-23T10:00:00.000Z","integrations":[{
                "id":ID,"ownerAccount":OWNER,"state":"revoked","scopes":["agent.view"],"r9Svc":key,
                "interruptRunning":true,"revokedAt":null,"expiresAt":"2099-01-01T00:00:00.000Z","quotaPerSecond":10
            }]}});
        let checkpoint = PortalCheckpoint::parse(&serde_json::to_vec(&source).unwrap(), &runtime.binding).unwrap();
        let next = previous.apply_checkpoint(checkpoint, previous.received_at).unwrap();
        runtime.policies.commit_for_recovery(&previous, &next, Some(&fence)).await.unwrap();
        let replica = db.reconnect(2).await;
        let review = || plan::prepare_with_sources(&replica, &fence, &genesis, None, Some(&runtime.binding), None);
        let before = review().await.unwrap();
        assert_eq!(before["portal_service_evidence"]["services"][0]["snapshot_review"],
            json!({"status":"coverage_unresolved","fresh_stop_actions":[]}));
        let hash = before["reconstruction_hash"].as_str().unwrap();
        let staged = plan::snapshot_stops::stage(&db.pool, &fence, &genesis, hash).await.unwrap();
        assert_eq!(staged["stop_count"], 2);
        let after = review().await.unwrap();
        assert_eq!(after["portal_service_evidence"]["services"][0]["snapshot_review"],
            json!({"status":"coverage_ended","coverage_end":{"reason":"snapshot_revoke",
                "record_id":history[1]["body"]["record_id"]},"fresh_stop_actions":[]}));
        assert_eq!(after["recovery_ready"], false);

        let plan_id = staged["plan_id"].as_str().unwrap();
        sqlx::query("UPDATE station_delegated_snapshot_stops SET reconstruction_hash=$2 WHERE plan_id=$1")
            .bind(plan_id).bind("0".repeat(64)).execute(&db.pool).await.unwrap();
        assert_eq!(review().await.unwrap()["portal_service_evidence"], before["portal_service_evidence"]);
        // Retaining the revoke alone must not hide the missing interrupt.
        sqlx::query("UPDATE station_delegated_snapshot_stops SET reconstruction_hash=$2,records=$3 WHERE plan_id=$1")
            .bind(plan_id).bind(hash).bind(json!([history[1]])).execute(&db.pool).await.unwrap();
        assert!(review().await.is_err());
        replica.close().await;
        drop(runtime);
        db.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_recovery_fences_http_and_preserves_reports_and_client_stops() {
        use crate::remote_api::recovery::delegated_recovery::Binding;
        let (database, mut runtime, _) = super::super::tests::fixture().await;
        let mut portal = crate::integration_portal::tests::Fixture::new().await;
        let local = Arc::get_mut(&mut runtime).unwrap();
        local.binding = portal.binding.clone();
        local.portal = portal.client();
        local.app.recovery.configure_delegated("https://station-dev.agora.build", 1).await.unwrap();
        runtime.initialize_report_control(None).await.unwrap();
        let a = pending_report(&runtime.app.recovery).await.log.genesis_hash().to_hex();
        let b = pending_report(&runtime.app.recovery).await.log.genesis_hash().to_hex();
        portal.set_status(403);
        runtime.deliver_delegated_reports(&a, "alice").await;
        let old_reports = portal.shared.reports.lock().await.clone();
        assert_eq!(old_reports.len(), 1);
        let before: Vec<(String, Value)> = sqlx::query_as("SELECT genesis_hash,state FROM remote_recovery_roots ORDER BY genesis_hash")
            .fetch_all(&database.pool).await.unwrap();
        let report_state: (Value, Option<String>) = sqlx::query_as("SELECT events,in_flight FROM station_delegated_reporting")
            .fetch_one(&database.pool).await.unwrap();
        assert!(!Binding::new("https://station-dev.agora.build", 2).unwrap().initialize(&database.pool, false).await.unwrap().ready);
        portal.set_status(200);
        assert!(runtime.initialize_report_control(Some(&uuid::Uuid::new_v4().to_string())).await.is_err());
        runtime.deliver_delegated_reports(&a, "alice").await;
        runtime.deliver_delegated_reports(&b, "alice").await;
        assert_eq!(*portal.shared.reports.lock().await, old_reports);
        let after: Vec<(String, Value)> = sqlx::query_as("SELECT genesis_hash,state FROM remote_recovery_roots ORDER BY genesis_hash")
            .fetch_all(&database.pool).await.unwrap();
        assert_eq!(after, before, "no settlement, watermark change or synthetic report receipt");
        let after_reports: (Value, Option<String>) = sqlx::query_as("SELECT events,in_flight FROM station_delegated_reporting")
            .fetch_one(&database.pool).await.unwrap();
        assert_eq!(after_reports, report_state, "recovery does not resume a stopped report client");
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_recovery_retains_the_shared_reporting_journal_across_restore() {
        use crate::remote_api::recovery::delegated_recovery::{plan::prepare_with_sources, Binding};
        let (db, runtime, _) = super::super::tests::fixture_at_station(
            "https://auth.example", None, "https://station-dev.agora.build",
        ).await;
        let origin = &runtime.binding.station_origin;
        runtime.app.recovery.configure_delegated(origin, 1).await.unwrap();
        let resume = uuid::Uuid::new_v4().to_string();
        runtime.initialize_report_control(Some(&resume)).await.unwrap();
        let a = pending_report(&runtime.app.recovery).await.log.genesis_hash().to_hex();
        let b = pending_report(&runtime.app.recovery).await.log.genesis_hash().to_hex();
        assert_ne!(a, b);
        let key = runtime.binding.report_control_binding();
        let claim = uuid::Uuid::new_v4().to_string();
        sqlx::query("UPDATE station_delegated_reporting SET in_flight=$2 WHERE binding=$1")
            .bind(&key).bind(&claim).execute(&db.pool).await.unwrap();
        let fence = Binding::new(origin, 2).unwrap();
        fence.initialize(&db.pool, true).await.unwrap();
        let replica = db.reconnect(3).await;
        let (one, two) = tokio::join!(
            prepare_with_sources(&db.pool, &fence, &a, None, Some(&runtime.binding), None),
            prepare_with_sources(&replica, &fence, &b, None, Some(&runtime.binding), None),
        );
        let report = one.unwrap()["reporting_history"].clone();
        assert_eq!(two.unwrap()["reporting_history"], report);
        assert_eq!(report["distinct_journals"], 1);
        assert_eq!(report["observed_uncertain_delivery"], true);
        assert!(!report.to_string().contains(&claim));
        assert!(!report.to_string().contains(&resume));
        let archived: Value = sqlx::query_scalar("SELECT journal FROM station_delegated_reporting_history")
            .fetch_one(&replica).await.unwrap();
        assert_eq!(archived["resume_ids"], json!([resume]));
        assert_eq!(archived["in_flight"], claim);
        let mut other = runtime.binding.clone();
        other.portal_origin = "https://another-portal.example".into();
        let separate = prepare_with_sources(&replica, &fence, &a, None, Some(&other), None).await.unwrap();
        assert_eq!(separate["reporting_history"]["distinct_journals"], 0);
        assert!(separate["reporting_history"]["current_evidence_hash"].is_null());

        sqlx::query("UPDATE station_delegated_reporting SET in_flight=NULL WHERE binding=$1")
            .bind(&key).execute(&db.pool).await.unwrap();
        let restored = crate::remote_api::recovery::delegated_recovery::plan::reporting_history::restore_stop(
            &replica, &fence, &runtime.binding, report["retained_stop_or_claim_hash"].as_str().unwrap(),
        ).await.unwrap();
        assert_eq!(restored["outstanding_delivery"], true);
        assert_eq!(restored["stopped"], false);
        let held: String = sqlx::query_scalar("SELECT in_flight FROM station_delegated_reporting WHERE binding=$1")
            .bind(&key).fetch_one(&db.pool).await.unwrap();
        assert_eq!(held, claim);

        // A later restore can retain a stop instead of the outstanding delivery.
        let events = json!([ReportControlEvent::Stop(runtime.binding.report_client_id.clone())]);
        sqlx::query("UPDATE station_delegated_reporting SET events=$2,in_flight=NULL WHERE binding=$1")
            .bind(&key).bind(events).execute(&db.pool).await.unwrap();
        let next = Binding::new(origin, 3).unwrap();
        next.initialize(&replica, true).await.unwrap();
        let review = prepare_with_sources(&replica, &next, &a, None, Some(&runtime.binding), None).await.unwrap();
        let retained = &review["reporting_history"];
        assert_eq!(retained["distinct_journals"], 2);
        assert_eq!(retained["observed_stopped_client"], true);
        assert_eq!(retained["observed_uncertain_delivery"], true);
        assert_ne!(retained["current_evidence_hash"], report["current_evidence_hash"]);
        sqlx::query("DELETE FROM station_delegated_report_resumptions WHERE binding=$1")
            .bind(&key).execute(&db.pool).await.unwrap();
        sqlx::query("DELETE FROM station_delegated_reporting WHERE binding=$1")
            .bind(&key).execute(&db.pool).await.unwrap();
        let missing = prepare_with_sources(&db.pool, &next, &a, None, Some(&runtime.binding), None).await.unwrap();
        assert!(missing["reporting_history"]["current_evidence_hash"].is_null());
        assert_eq!(missing["reporting_history"]["distinct_journals"], 2);
        assert_eq!(missing["recovery_ready"], false);
        assert!(missing["reporting_history"]["retained_stop_or_claim_hash"].is_string());
        // Neither archive contains the other's event prefix.
        let candidate = missing["reporting_history"]["retained_stop_or_claim_hash"].as_str().unwrap();
        assert!(crate::remote_api::recovery::delegated_recovery::plan::reporting_history::restore_stop(
            &replica, &next, &runtime.binding, candidate,
        ).await.is_err());
        drop((runtime, replica));
        db.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_report_restart_checks_archived_stop_claim_and_resume_ids() {
        use crate::remote_api::recovery::delegated_recovery::{plan::prepare_with_sources, Binding};
        let origin = "https://station-dev.agora.build";
        let (db, runtime, _) = super::super::tests::fixture_at_station("https://auth.example", None, origin).await;
        runtime.app.recovery.configure_delegated(origin, 1).await.unwrap();
        let genesis = pending_report(&runtime.app.recovery).await.log.genesis_hash().to_hex();
        let key = runtime.binding.report_control_binding();
        let consumed = uuid::Uuid::new_v4().to_string();
        runtime.initialize_report_control(Some(&consumed)).await.unwrap();
        let claim = uuid::Uuid::new_v4().to_string();
        sqlx::query("UPDATE station_delegated_reporting SET in_flight=$2 WHERE binding=$1")
            .bind(&key).bind(&claim).execute(&db.pool).await.unwrap();
        let fence = Binding::new(origin, 1).unwrap();
        fence.initialize(&db.pool, true).await.unwrap();
        prepare_with_sources(&db.pool, &fence, &genesis, None, Some(&runtime.binding), None).await.unwrap();
        let events: Value = sqlx::query_scalar("SELECT events FROM station_delegated_reporting WHERE binding=$1")
            .bind(&key).fetch_one(&db.pool).await.unwrap();

        // Model an already-open generation with an older live journal. This is
        // a reporter startup test, independent of the operator publication flow.
        sqlx::query("UPDATE station_delegated_recovery SET ready=true WHERE origin=$1")
            .bind(origin).execute(&db.pool).await.unwrap();
        sqlx::query("UPDATE station_delegated_reporting SET in_flight=NULL WHERE binding=$1")
            .bind(&key).execute(&db.pool).await.unwrap();
        assert!(runtime.initialize_report_control(None).await.is_err());
        assert!(runtime.initialize_report_control(Some(&consumed)).await.is_err());
        sqlx::query("DELETE FROM station_delegated_report_resumptions WHERE binding=$1")
            .bind(&key).execute(&db.pool).await.unwrap();
        assert!(runtime.initialize_report_control(Some(&consumed)).await.is_err());
        assert_eq!(sqlx::query_scalar::<_,Value>("SELECT events FROM station_delegated_reporting WHERE binding=$1")
            .bind(&key).fetch_one(&db.pool).await.unwrap(), events);
        let fresh = uuid::Uuid::new_v4().to_string();
        runtime.initialize_report_control(Some(&fresh)).await.unwrap();
        runtime.initialize_report_control(None).await.unwrap();
        // A partial restore can retain the Resume event and lose its consumed
        // ID. Restarting with that same ID must not authorize another resume.
        sqlx::query("DELETE FROM station_delegated_report_resumptions WHERE binding=$1 AND resume_id=$2::uuid")
            .bind(&key).bind(&fresh).execute(&db.pool).await.unwrap();
        assert!(runtime.initialize_report_control(None).await.is_err());
        assert!(runtime.initialize_report_control(Some(&fresh)).await.is_err());
        sqlx::query("INSERT INTO station_delegated_report_resumptions(binding,resume_id) VALUES ($1,$2::uuid)")
            .bind(&key).bind(&fresh).execute(&db.pool).await.unwrap();
        runtime.initialize_report_control(Some(&fresh)).await.unwrap();
        let consumed_ids: i64 = sqlx::query_scalar("SELECT count(*) FROM station_delegated_report_resumptions WHERE binding=$1")
            .bind(&key).fetch_one(&db.pool).await.unwrap();
        assert_eq!(consumed_ids, 2);
        let stopped = ReportControlEvent::Stop(runtime.binding.report_client_id.clone());
        sqlx::query("UPDATE station_delegated_reporting SET events=events || $2 WHERE binding=$1")
            .bind(&key).bind(json!([stopped])).execute(&db.pool).await.unwrap();
        fence.initialize(&db.pool, true).await.unwrap();
        prepare_with_sources(&db.pool, &fence, &genesis, None, Some(&runtime.binding), None).await.unwrap();
        sqlx::query("UPDATE station_delegated_recovery SET ready=true WHERE origin=$1")
            .bind(origin).execute(&db.pool).await.unwrap();
        sqlx::query("DELETE FROM station_delegated_report_resumptions WHERE binding=$1 AND resume_id=$2::uuid")
            .bind(&key).bind(&fresh).execute(&db.pool).await.unwrap();
        runtime.initialize_report_control(Some(&fresh)).await.unwrap();
        let last: Value = sqlx::query_scalar("SELECT events->-1 FROM station_delegated_reporting WHERE binding=$1")
            .bind(&key).fetch_one(&db.pool).await.unwrap();
        assert_eq!(last, json!(ReportControlEvent::Stop(runtime.binding.report_client_id.clone())));
        sqlx::query("UPDATE station_delegated_reporting SET events=$2 WHERE binding=$1")
            .bind(&key).bind(&events).execute(&db.pool).await.unwrap();
        assert!(runtime.initialize_report_control(Some(&uuid::Uuid::new_v4().to_string())).await.is_err());
        assert_eq!(sqlx::query_scalar::<_,Value>("SELECT events FROM station_delegated_reporting WHERE binding=$1")
            .bind(&key).fetch_one(&db.pool).await.unwrap(), events);
        drop(runtime);
        db.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_restore_report_stop_is_scoped_atomic_and_idempotent() {
        use crate::remote_api::recovery::delegated_recovery::{plan::{prepare_with_sources, reporting_history::restore_stop}, Binding};
        let origin = "https://station-dev.agora.build";
        let (db, runtime, _) = super::super::tests::fixture_at_station("https://auth.example", None, origin).await;
        runtime.app.recovery.configure_delegated(origin, 1).await.unwrap();
        let genesis = pending_report(&runtime.app.recovery).await.log.genesis_hash().to_hex();
        let portal = &runtime.binding;
        let key = portal.report_control_binding();
        let resume = uuid::Uuid::new_v4().to_string();
        runtime.initialize_report_control(Some(&resume)).await.unwrap();
        let fence = Binding::new(origin, 2).unwrap();
        fence.initialize(&db.pool, true).await.unwrap();
        let running = prepare_with_sources(&db.pool, &fence, &genesis, None, Some(portal), None).await.unwrap();
        let hash = running["reporting_history"]["current_evidence_hash"].as_str().unwrap();
        assert!(restore_stop(&db.pool, &fence, portal, hash).await.is_err());

        let stopped = json!([ReportControlEvent::Stop(portal.report_client_id.clone())]);
        let events: Value = sqlx::query_scalar("UPDATE station_delegated_reporting SET events=events || $2
            WHERE binding=$1 RETURNING events").bind(&key).bind(stopped).fetch_one(&db.pool).await.unwrap();
        let archive = prepare_with_sources(&db.pool, &fence, &genesis, None, Some(portal), None).await.unwrap();
        let hash = archive["reporting_history"]["current_evidence_hash"].as_str().unwrap();
        assert_eq!(archive["reporting_history"]["retained_stop_or_claim_hash"], hash);
        let mut wrong_portal = portal.clone();
        wrong_portal.portal_origin = "https://another-portal.example".into();
        assert!(restore_stop(&db.pool, &fence, &wrong_portal, hash).await.is_err());

        sqlx::query("DELETE FROM station_delegated_report_resumptions WHERE binding=$1")
            .bind(&key).execute(&db.pool).await.unwrap();
        sqlx::query("DELETE FROM station_delegated_reporting WHERE binding=$1")
            .bind(&key).execute(&db.pool).await.unwrap();
        sqlx::raw_sql("CREATE FUNCTION reject_restored_stop() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'injected commit failure'; END; $$;
            CREATE CONSTRAINT TRIGGER reject_restored_stop AFTER INSERT ON station_delegated_reporting
            DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_restored_stop()")
            .execute(&db.pool).await.unwrap();
        assert!(restore_stop(&db.pool, &fence, portal, hash).await.is_err());
        let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM station_delegated_reporting WHERE binding=$1)")
            .bind(&key).fetch_one(&db.pool).await.unwrap();
        assert!(!exists);
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_delegated_report_resumptions WHERE binding=$1")
            .bind(&key).fetch_one(&db.pool).await.unwrap();
        assert_eq!(count, 0);
        sqlx::query("DROP TRIGGER reject_restored_stop ON station_delegated_reporting")
            .execute(&db.pool).await.unwrap();
        let replica = db.reconnect(2).await;
        let (one, two) = tokio::join!(restore_stop(&db.pool, &fence, portal, hash),
            restore_stop(&replica, &fence, portal, hash));
        let receipt = one.unwrap();
        assert_eq!(two.unwrap(), receipt);
        assert_eq!(receipt["stopped"], true);
        assert_eq!(receipt["recovery_ready"], false);
        let restored: Value = sqlx::query_scalar("SELECT events FROM station_delegated_reporting WHERE binding=$1")
            .bind(&key).fetch_one(&replica).await.unwrap();
        assert_eq!(restored, events);
        let ids: Vec<String> = sqlx::query_scalar("SELECT resume_id::text FROM station_delegated_report_resumptions WHERE binding=$1")
            .bind(&key).fetch_all(&replica).await.unwrap();
        assert_eq!(ids, vec![resume]);
        assert!(restore_stop(&replica, &Binding::new(origin, 1).unwrap(), portal, hash).await.is_err());
        drop((runtime, replica));
        db.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_recovery_waits_for_in_flight_http_and_atomic_settlement() {
        use crate::remote_api::recovery::delegated_recovery::Binding;
        let (database, mut runtime, _) = super::super::tests::fixture().await;
        let mut portal = crate::integration_portal::tests::Fixture::new().await;
        let local = Arc::get_mut(&mut runtime).unwrap();
        local.binding = portal.binding.clone();
        local.portal = portal.client();
        local.app.recovery.configure_delegated("https://station-dev.agora.build", 1).await.unwrap();
        runtime.initialize_report_control(None).await.unwrap();
        let a = pending_report(&runtime.app.recovery).await.log.genesis_hash().to_hex();
        let b = pending_report(&runtime.app.recovery).await.log.genesis_hash().to_hex();
        let hold = Arc::new(tokio::sync::Semaphore::new(0));
        *portal.shared.report_hold.lock().await = Some(hold.clone());
        let delivery = {
            let runtime = runtime.clone();
            tokio::spawn(async move { runtime.deliver_delegated_reports(&a, "alice").await })
        };
        tokio::time::timeout(Duration::from_secs(3), portal.shared.report_started.notified()).await.unwrap();
        let mut fence = {
            let pool = database.pool.clone();
            tokio::spawn(async move {
                Binding::new("https://station-dev.agora.build", 2).unwrap().initialize(&pool, false).await.unwrap()
            })
        };
        assert!(tokio::time::timeout(Duration::from_millis(100), &mut fence).await.is_err());
        hold.add_permits(1);
        tokio::time::timeout(Duration::from_secs(3), delivery).await.unwrap().unwrap();
        assert!(!fence.await.unwrap().ready);
        runtime.deliver_delegated_reports(&b, "alice").await;
        assert_eq!(portal.shared.reports.lock().await.len(), 1);
        let marker: Option<String> = sqlx::query_scalar("SELECT in_flight FROM station_delegated_reporting")
            .fetch_one(&database.pool).await.unwrap();
        assert!(marker.is_none(), "the earlier request settles before the recovery fence commits");
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_builtin_release_waits_for_the_current_enabled_owner() {
        use super::super::tests::{append_body, fixture_at_station, request};
        use crate::integration_checkpoint::PortalCheckpoint;
        let (db, runtime, f) = fixture_at_station("https://auth.example", None, "https://station-dev.agora.build").await;
        let genesis = f.log.genesis_hash().to_hex();
        runtime.app.recovery.configure_delegated(&runtime.binding.station_origin, 1).await.unwrap();
        let draft = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
        let fingerprint = draft["fingerprint"].as_str().unwrap();
        append_body(&runtime, &f, serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap()).await;
        policy(&runtime, "paused", fingerprint, None).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        policy(&runtime, "ready", fingerprint, None).await;
        assert!(runtime.reconcile_delegated_service(ID).await.is_err());
        let replica = crate::integration_feed::PolicyStore(db.reconnect(2).await);
        let previous = replica.load(&runtime.binding).await.unwrap();
        let mut integration = serde_json::to_value(&previous.integrations[ID]).unwrap();
        integration["id"] = json!(ID);
        let value = json!({"changes":[],"cursor":previous.cursor,"checkpoint":{
            "at":"2026-11-24T10:00:00.000Z","integrations":[integration],
            "accounts":{"complete":true,"disabled":[OWNER]},"bindings":[],"pendingReleases":[]
        }});
        let exact = PortalCheckpoint::parse(&serde_json::to_vec(&value).unwrap(), &runtime.binding).unwrap();
        let now = chrono::Utc::now().timestamp();
        let denied = previous.apply_checkpoint(exact, now).unwrap();
        replica.commit(&previous, &denied).await.unwrap();
        assert!(runtime.reconcile_delegated_service(ID).await.is_err());
        assert_eq!(feed(&runtime, &genesis).await.len(), 2);
        let id = denied.cursor + 1;
        let mut page = json!({"changes":[{"kind":"account_enabled","id":id,"account":OWNER,
            "integrationId":null,"state":null,"reason":"agora_build"}],"cursor":id});
        if denied.cursor == 0 { page["integrations"] = value["checkpoint"]["integrations"].clone(); }
        let enabled = denied.apply(denied.cursor, serde_json::from_value(page).unwrap(), now).unwrap();
        replica.commit(&denied, &enabled).await.unwrap();
        runtime.reconcile_delegated_service(ID).await.unwrap();
        let records = feed(&runtime, &genesis).await;
        assert_eq!(records.iter().map(|r| r["body"]["action"].as_str().unwrap()).collect::<Vec<_>>(),
            ["cover", "hold", "release"]);
        // A checkpoint can change the owner without advancing the change-feed cursor.
        policy(&runtime, "paused", fingerprint, None).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        policy(&runtime, "ready", fingerprint, None).await;
        let mut current = replica.load(&runtime.binding).await.unwrap();
        let held = feed(&runtime, &genesis).await;
        let other = "ab00000000000000000000000001";
        for (version, state, owner) in [
            (1, "unbound", OWNER), (2, "released", OWNER), (3, "bound", other), (4, "bound", OWNER), (6, "bound", OWNER),
        ] {
            let mut update = value.clone();
            update["cursor"] = json!(current.cursor);
            update["checkpoint"]["accounts"]["disabled"] = json!([]);
            update["checkpoint"]["bindings"] = json!([{"account":owner,"accountId":f.log.account_id(),
                "genesisHash":genesis,"bindingId":"test-binding","version":version,"bindingState":state}]);
            let exact = PortalCheckpoint::parse(&serde_json::to_vec(&update).unwrap(), &runtime.binding).unwrap();
            let next = current.apply_checkpoint(exact, chrono::Utc::now().timestamp()).unwrap();
            replica.commit(&current, &next).await.unwrap();
            current = next;
            if version == 4 {
                let mut rotated = runtime.binding.clone();
                rotated.report_client_id = "s-11234567890123456789012345".into();
                update["checkpoint"]["bindings"][0]["version"] = json!(5);
                update["checkpoint"]["bindings"][0]["bindingState"] = json!("released");
                let source = PortalCheckpoint::parse(&serde_json::to_vec(&update).unwrap(), &rotated).unwrap();
                let before = replica.load(&rotated).await.unwrap();
                replica.commit(&before, &before.apply_checkpoint(source, now).unwrap()).await.unwrap();
            }
            if version == 6 {
                let mut rotated = runtime.binding.clone();
                rotated.report_client_id = "s-11234567890123456789012345".into();
                let before = replica.load(&rotated).await.unwrap();
                let cut = current.cursor + 1;
                update["cursor"] = json!(cut);
                update["checkpoint"]["accounts"]["disabled"] = json!([OWNER]);
                let source = PortalCheckpoint::parse(&serde_json::to_vec(&update).unwrap(), &rotated).unwrap();
                let disabled = before.apply_checkpoint(source, now).unwrap();
                replica.commit(&before, &disabled).await.unwrap();
                replica.deny(&rotated).await.unwrap();
                assert!(runtime.reconcile_delegated_service(ID).await.is_err());
                assert_eq!(feed(&runtime, &genesis).await, held);
                let before = replica.load(&runtime.binding).await.unwrap();
                let change = |id, kind| json!({"id":id,"kind":kind,"account":OWNER,
                    "integrationId":null,"state":null,"reason":"agora_build"});
                let page = json!({"changes":[change(cut, "account_disabled"),change(cut+1, "account_enabled")],
                    "cursor":cut+1});
                let mut enabled = before.apply(before.cursor, serde_json::from_value(page).unwrap(), now).unwrap();
                replica.commit(&before, &enabled).await.unwrap();
                // The owner is enabled, but a full page or a slow response
                // supplies no fresh evidence for a new release.
                assert!(runtime.reconcile_delegated_service(ID).await.is_err());
                let before = enabled;
                let caught_up = json!({"changes":[],"cursor":before.cursor});
                enabled = before.apply(before.cursor, serde_json::from_value(caught_up.clone()).unwrap(), now).unwrap();
                let received = chrono::Utc::now().timestamp_millis();
                enabled.record_completed_read(received - 60_000, received);
                replica.commit(&before, &enabled).await.unwrap();
                assert!(runtime.reconcile_delegated_service(ID).await.is_err());
                let before = enabled;
                enabled = before.apply(before.cursor, serde_json::from_value(caught_up).unwrap(), now).unwrap();
                enabled.record_completed_read(received, received);
                replica.commit(&before, &enabled).await.unwrap();
            }
            let result = runtime.reconcile_delegated_service(ID).await;
            if version < 6 {
                assert!(result.is_err());
                assert_eq!(feed(&runtime, &genesis).await, held);
            } else {
                result.unwrap();
                let resumed = feed(&runtime, &genesis).await;
                assert_eq!(resumed.len(), held.len() + 1);
                assert_eq!(resumed.last().unwrap()["body"]["action"], "release");
            }
        }
        replica.0.close().await;
        drop(runtime);
        db.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_service_lifecycle_signs_once_and_retains_key_until_r9_removal() {
        use super::super::tests::{append_body, fixture, request, signed_action};
        use atem_client::{
            control::{verify_control, ControlCheck, ControlRecord},
            membership::Action,
        };
        let (database, runtime, f) = fixture().await;
        let genesis = f.log.genesis_hash().to_hex();
        runtime
            .app
            .recovery
            .configure_delegated(&runtime.binding.station_origin, 1).await
            .unwrap();
        let draft = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
        let fingerprint = draft["fingerprint"].as_str().unwrap();
        append_body(
            &runtime,
            &f,
            serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap(),
        )
        .await;
        policy(&runtime, "ready", fingerprint, None).await;
        let (one, two) = tokio::join!(
            runtime.reconcile_delegated_service(ID),
            runtime.reconcile_delegated_service(ID)
        );
        assert!(one.is_ok() && two.is_ok());
        let cover = feed(&runtime, &genesis).await;
        assert_eq!(cover.len(), 1);
        assert_eq!(cover[0]["body"]["action"], "cover");
        policy(&runtime, "paused", fingerprint, None).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        policy(&runtime, "expired", fingerprint, None).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        assert_eq!(
            feed(&runtime, &genesis).await.len(),
            2,
            "expiry cannot release a hold"
        );
        policy(&runtime, "ready", fingerprint, None).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        policy(&runtime, "revoking", fingerprint, Some(false)).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        runtime.report_revocations().await;
        let keys: i64 = sqlx::query_scalar("SELECT count(*) FROM station_service_keys")
            .fetch_one(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            keys, 1,
            "a Portal revoke must preserve the key for a later interrupt"
        );
        policy(&runtime, "revoked", fingerprint, Some(true)).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        runtime.reconcile_delegated_service(ID).await.unwrap();
        let records = feed(&runtime, &genesis).await;
        assert_eq!(
            records
                .iter()
                .map(|r| r["body"]["action"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["cover", "hold", "release", "revoke", "interrupt_running"]
        );
        assert_eq!(records[3]["body"]["interrupt_running"], false);
        assert_eq!(records[0], cover[0]);
        let log = runtime.recovery_log(&genesis, OWNER).await.unwrap();
        let mut previous_time = 0;
        for value in &records {
            let record = ControlRecord::parse(value.to_string().as_bytes()).unwrap();
            assert!(matches!(
                verify_control(&record, &log),
                ControlCheck::Valid(_)
            ));
            assert!(record.issued_at() > previous_time);
            previous_time = record.issued_at();
        }
        policy(&runtime, "ready", fingerprint, None).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        assert_eq!(
            feed(&runtime, &genesis).await,
            records,
            "an old active policy cannot undo a revoke"
        );
        policy(&runtime, "revoking", fingerprint, Some(true)).await;
        signed_action(
            &runtime,
            &f,
            Action::Remove {
                device_id: format!("svc-{ID}"),
            },
        )
        .await;
        runtime.report_revocations().await;
        let keys: i64 = sqlx::query_scalar("SELECT count(*) FROM station_service_keys")
            .fetch_one(&database.pool)
            .await
            .unwrap();
        assert_eq!(keys, 0);
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_clock_rollback_keeps_cover_and_hold_unpublished() {
        use super::super::tests::{append_body, fixture, request};
        let (database, runtime, f) = fixture().await;
        let genesis = f.log.genesis_hash().to_hex();
        let origin = &runtime.binding.station_origin;
        runtime.app.recovery.configure_delegated(origin, 1).await.unwrap();
        let draft = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
        append_body(&runtime, &f, serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap()).await;
        policy(&runtime, "paused", draft["fingerprint"].as_str().unwrap(), None).await;
        let owner = runtime.owner_principal(OWNER).await.unwrap();
        assert_eq!(runtime.app.recovery.delegated_operation(&genesis, &owner, Command::Ensure).await.0, StatusCode::OK);

        // A restored wall clock behind a durable reservation cannot sign either action.
        let future = chrono::Utc::now().timestamp_millis() + 3_600_000;
        let before: Value = sqlx::query_scalar("UPDATE remote_recovery_roots SET state=jsonb_set(state,             ARRAY['delegated',$2,'signing_high_water',$3],to_jsonb($4::bigint)) WHERE genesis_hash=$1 RETURNING state")
            .bind(&genesis).bind(origin).bind(format!("service:svc-{ID}")).bind(future)
            .fetch_one(&database.pool).await.unwrap();
        assert!(runtime.reconcile_delegated_service(ID).await.is_err());
        let after: Value = sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
            .bind(&genesis).fetch_one(&database.pool).await.unwrap();
        assert_eq!(before, after);
        assert!(feed(&runtime, &genesis).await.is_empty());
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_service_refuses_stale_policy_wrong_key_and_failed_publication() {
        use super::super::tests::{append_body, fixture, request};
        let (database, runtime, f) = fixture().await;
        let genesis = f.log.genesis_hash().to_hex();
        runtime
            .app
            .recovery
            .configure_delegated(&runtime.binding.station_origin, 1).await
            .unwrap();
        let draft = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
        let fingerprint = draft["fingerprint"].as_str().unwrap();
        append_body(
            &runtime,
            &f,
            serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap(),
        )
        .await;
        policy(&runtime, "ready", &"f".repeat(64), None).await;
        assert!(runtime.reconcile_delegated_service(ID).await.is_err());
        assert!(feed(&runtime, &genesis).await.is_empty());
        policy(&runtime, "ready", fingerprint, None).await;
        runtime.policies.deny(&runtime.binding).await.unwrap();
        assert!(runtime.reconcile_delegated_service(ID).await.is_err());
        let previous = runtime.policies.load(&runtime.binding).await.unwrap();
        let mut restored = previous.clone();
        restored.revision += 1;
        restored.denied = false;
        runtime.policies.commit(&previous, &restored).await.unwrap();
        sqlx::query("CREATE FUNCTION fail_delegated_publish() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test publication failure'; END $$")
            .execute(&database.pool).await.unwrap();
        sqlx::query("CREATE TRIGGER fail_delegated_publish BEFORE UPDATE ON remote_recovery_roots FOR EACH ROW EXECUTE FUNCTION fail_delegated_publish()")
            .execute(&database.pool).await.unwrap();
        assert!(runtime.reconcile_delegated_service(ID).await.is_err());
        assert!(
            feed(&runtime, &genesis).await.is_empty(),
            "failed write exposes no signed control"
        );
        sqlx::query("DROP TRIGGER fail_delegated_publish ON remote_recovery_roots")
            .execute(&database.pool)
            .await
            .unwrap();
        runtime.reconcile_delegated_service(ID).await.unwrap();
        assert_eq!(feed(&runtime, &genesis).await.len(), 1);
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_revocation_coverage_survives_scope_narrowing() {
        use super::super::tests::{append_body, fixture, request, signed_action};
        use atem_client::membership::{Action, MemberKind, RolesChange};
        let (database, runtime, f) = fixture().await;
        let genesis = f.log.genesis_hash().to_hex();
        runtime
            .app
            .recovery
            .configure_delegated(&runtime.binding.station_origin, 1).await
            .unwrap();
        let draft = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
        append_body(
            &runtime,
            &f,
            serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap(),
        )
        .await;
        let log = runtime.recovery_log(&genesis, OWNER).await.unwrap();
        let member = &log.member(&format!("svc-{ID}")).unwrap().member;
        let MemberKind::Service { scope, expires_at } = &member.kind else {
            panic!("service")
        };
        let mut expanded = scope.clone();
        expanded.hosts.push("host-b".into());
        signed_action(
            &runtime,
            &f,
            Action::SetRoles {
                device_id: member.device_id.clone(),
                change: RolesChange::Service {
                    scope: expanded,
                    expires_at: *expires_at,
                },
            },
        )
        .await;
        signed_action(
            &runtime,
            &f,
            Action::SetRoles {
                device_id: member.device_id.clone(),
                change: RolesChange::Service {
                    scope: scope.clone(),
                    expires_at: *expires_at,
                },
            },
        )
        .await;
        policy(
            &runtime,
            "revoking",
            draft["fingerprint"].as_str().unwrap(),
            Some(false),
        )
        .await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        let records = feed(&runtime, &genesis).await;
        let id = records[0]["body"]["record_id"].as_str().unwrap();
        let state: Value =
            sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
                .bind(&genesis)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(
            state["delegated"][&runtime.binding.station_origin]["ledger"]["records"][id]["covered"],
            json!(["host-a", "host-b"])
        );
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_native_revoke_cannot_be_released_and_still_gets_service_reporting()
    {
        use super::super::tests::{append_body, fixture, request, PRINCIPAL};
        use crate::remote_api::recovery::delegated::OwnerCommand;
        use atem_client::{
            control::{
                build_control, ControlAbout, ControlAction, ControlBody, ControlFeed,
                ControlPrincipal, ControlRecord, ControlSigner,
            },
            KeyId,
        };
        let (database, runtime, f) = fixture().await;
        let genesis = f.log.genesis_hash().to_hex();
        runtime
            .app
            .recovery
            .configure_delegated(&runtime.binding.station_origin, 1).await
            .unwrap();
        let draft = runtime.prepare(ID, OWNER, request(&f)).await.unwrap();
        append_body(
            &runtime,
            &f,
            serde_json::from_str(draft["bodyJSON"].as_str().unwrap()).unwrap(),
        )
        .await;
        let fingerprint = draft["fingerprint"].as_str().unwrap();
        policy(&runtime, "paused", fingerprint, None).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        let state: Value =
            sqlx::query_scalar("SELECT state FROM remote_recovery_roots WHERE genesis_hash=$1")
                .bind(&genesis)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        let log = runtime.recovery_log(&genesis, OWNER).await.unwrap();
        let signed = build_control(
            &f.keys,
            &KeyId::new("manager"),
            &ControlBody {
                account_id: log.account_id().into(),
                genesis_hash: log.genesis_hash(),
                feed: Some(ControlFeed {
                    origin: runtime.binding.station_origin.clone(),
                    feed_id: state["delegated"][&runtime.binding.station_origin]["feed_id"]
                        .as_str()
                        .unwrap()
                        .into(),
                }),
                principal: ControlPrincipal::Service(format!("svc-{ID}")),
                principal_key: Some(atem_client::Hash32::from_hex(fingerprint).unwrap()),
                signer: ControlSigner::Member("phone".into()),
                action: ControlAction::Revoke {
                    interrupt_running: false,
                },
                record_id: uuid::Uuid::new_v4().to_string(),
                issued_at: chrono::Utc::now().timestamp_millis() as u64,
                about: ControlAbout {
                    integration_id: Some(ID.into()),
                    by: "owner".into(),
                },
            },
        )
        .unwrap();
        assert_eq!(
            runtime
                .app
                .recovery
                .delegated_operation(
                    &genesis,
                    PRINCIPAL,
                    Command::Owner(OwnerCommand::Publish {
                        record: ControlRecord::from_signed(signed).unwrap(),
                        expected: log.head(),
                    })
                )
                .await
                .0,
            StatusCode::OK
        );
        policy(&runtime, "ready", fingerprint, None).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        assert_eq!(
            feed(&runtime, &genesis).await.len(),
            3,
            "Portal resume cannot release a native revoke"
        );
        policy(&runtime, "revoking", fingerprint, Some(false)).await;
        runtime.reconcile_delegated_service(ID).await.unwrap();
        let records = feed(&runtime, &genesis).await;
        assert_eq!(records.len(), 4);
        assert_eq!(records[2]["body"]["signer"], "member:phone");
        assert_eq!(records[3]["body"]["signer"], format!("service:svc-{ID}"));
        assert_eq!(
            records[3]["body"]["action"], "revoke",
            "the own-key record starts Portal revocation accounting"
        );
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_real_http_delivery_retries_the_same_report_and_settles_once() {
        let (database, mut runtime, _) = super::super::tests::fixture().await;
        let mut portal = crate::integration_portal::tests::Fixture::new().await;
        let local = Arc::get_mut(&mut runtime).unwrap();
        local.binding = portal.binding.clone();
        local.portal = portal.client();
        local
            .app
            .recovery
            .configure_delegated("https://station-dev.agora.build", 1).await
            .unwrap();
        runtime.initialize_report_control(None).await.unwrap();
        let f = pending_report(&runtime.app.recovery).await;
        let genesis = f.log.genesis_hash().to_hex();
        portal.set_status(503);
        runtime.deliver_delegated_reports(&genesis, "alice").await;
        let first = portal.shared.reports.lock().await[0].clone();
        runtime.deliver_delegated_reports(&genesis, "alice").await;
        assert_eq!(
            portal.shared.reports.lock().await.len(),
            1,
            "durable backoff"
        );
        tokio::time::sleep(Duration::from_millis(2100)).await;
        portal.set_status(200);
        runtime.deliver_delegated_reports(&genesis, "alice").await;
        let reports = portal.shared.reports.lock().await.clone();
        assert_eq!(reports, vec![first.clone(), first]);
        runtime.deliver_delegated_reports(&genesis, "alice").await;
        assert_eq!(portal.shared.reports.lock().await.len(), 2);
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_403_fences_all_accounts_and_restart_until_explicit_resume() {
        let (database, mut runtime, _) = super::super::tests::fixture().await;
        let mut portal = crate::integration_portal::tests::Fixture::new().await;
        let local = Arc::get_mut(&mut runtime).unwrap();
        local.binding = portal.binding.clone();
        local.portal = portal.client();
        local
            .app
            .recovery
            .configure_delegated("https://station-dev.agora.build", 1).await
            .unwrap();
        runtime.initialize_report_control(None).await.unwrap();
        let a = pending_report(&runtime.app.recovery)
            .await
            .log
            .genesis_hash()
            .to_hex();
        let b = pending_report(&runtime.app.recovery)
            .await
            .log
            .genesis_hash()
            .to_hex();
        portal.set_status(403);
        runtime.deliver_delegated_reports(&a, "alice").await;
        portal.set_status(200);
        runtime.deliver_delegated_reports(&b, "alice").await;
        runtime.initialize_report_control(None).await.unwrap();
        runtime.deliver_delegated_reports(&a, "alice").await;
        assert_eq!(
            portal.shared.reports.lock().await.len(),
            1,
            "403 persists for the Station, not one account"
        );
        let resume = uuid::Uuid::new_v4().to_string();
        runtime
            .initialize_report_control(Some(&resume))
            .await
            .unwrap();
        runtime.deliver_delegated_reports(&a, "alice").await;
        runtime.deliver_delegated_reports(&b, "alice").await;
        let reports = portal.shared.reports.lock().await.clone();
        assert_eq!(reports.len(), 3);
        assert_eq!(
            reports[0], reports[1],
            "same client resumes the original report ID and body"
        );
        let c = pending_report(&runtime.app.recovery)
            .await
            .log
            .genesis_hash()
            .to_hex();
        portal.set_status(403);
        runtime.deliver_delegated_reports(&c, "alice").await;
        runtime
            .initialize_report_control(Some(&resume))
            .await
            .unwrap();
        runtime.deliver_delegated_reports(&c, "alice").await;
        assert_eq!(
            portal.shared.reports.lock().await.len(),
            4,
            "reusing an old operator resume cannot undo a later 403"
        );
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_failed_stop_commit_blocks_every_replica_and_survives_restart() {
        let (database, mut runtime, _) = super::super::tests::fixture().await;
        let mut portal = crate::integration_portal::tests::Fixture::new().await;
        let local = Arc::get_mut(&mut runtime).unwrap();
        local.binding = portal.binding.clone();
        local.portal = portal.client();
        local
            .app
            .recovery
            .configure_delegated("https://station-dev.agora.build", 1).await
            .unwrap();
        runtime.initialize_report_control(None).await.unwrap();
        let a = pending_report(&runtime.app.recovery)
            .await
            .log
            .genesis_hash()
            .to_hex();
        let b = pending_report(&runtime.app.recovery)
            .await
            .log
            .genesis_hash()
            .to_hex();
        // Simulate losing the stop write after receiving the real HTTP 403.
        sqlx::query("CREATE FUNCTION fail_report_stop() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.events != OLD.events THEN RAISE EXCEPTION 'test stop failure'; END IF; RETURN NEW; END $$")
            .execute(&database.pool).await.unwrap();
        sqlx::query("CREATE CONSTRAINT TRIGGER fail_report_stop AFTER UPDATE ON station_delegated_reporting DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_report_stop()")
            .execute(&database.pool).await.unwrap();
        portal.set_status(403);
        runtime.deliver_delegated_reports(&a, "alice").await;
        assert_eq!(portal.shared.reports.lock().await.len(), 1);
        let pool = database.reconnect(4).await;
        let saved: Option<String> =
            sqlx::query_scalar("SELECT in_flight FROM station_delegated_reporting")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(
            saved.is_some(),
            "pre-HTTP marker survives failure of the later stop commit"
        );
        portal.set_status(200);
        runtime.initialize_report_control(None).await.unwrap();
        let (one, two) = tokio::join!(
            runtime.deliver_delegated_reports(&a, "alice"),
            runtime.deliver_delegated_reports(&b, "alice")
        );
        assert_eq!((one, two), ((), ()));
        assert_eq!(portal.shared.reports.lock().await.len(), 1);
        sqlx::query("DROP TRIGGER fail_report_stop ON station_delegated_reporting")
            .execute(&pool)
            .await
            .unwrap();
        runtime
            .initialize_report_control(Some(&uuid::Uuid::new_v4().to_string()))
            .await
            .unwrap();
        runtime.deliver_delegated_reports(&a, "alice").await;
        runtime.deliver_delegated_reports(&b, "alice").await;
        assert_eq!(portal.shared.reports.lock().await.len(), 3);
        pool.close().await;
        drop(runtime);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_no_http_before_marker_commit_and_no_resend_after_settlement_failure(
    ) {
        let (database, mut runtime, _) = super::super::tests::fixture().await;
        let mut portal = crate::integration_portal::tests::Fixture::new().await;
        let local = Arc::get_mut(&mut runtime).unwrap();
        local.binding = portal.binding.clone();
        local.portal = portal.client();
        local
            .app
            .recovery
            .configure_delegated("https://station-dev.agora.build", 1).await
            .unwrap();
        runtime.initialize_report_control(None).await.unwrap();
        let genesis = pending_report(&runtime.app.recovery)
            .await
            .log
            .genesis_hash()
            .to_hex();
        sqlx::query("CREATE FUNCTION fail_report_marker() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test marker failure'; END $$")
            .execute(&database.pool).await.unwrap();
        sqlx::query("CREATE CONSTRAINT TRIGGER fail_report_marker AFTER UPDATE ON station_delegated_reporting DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_report_marker()")
            .execute(&database.pool).await.unwrap();
        runtime.deliver_delegated_reports(&genesis, "alice").await;
        assert!(portal.shared.reports.lock().await.is_empty());
        sqlx::query("DROP TRIGGER fail_report_marker ON station_delegated_reporting")
            .execute(&database.pool)
            .await
            .unwrap();
        // Ledger settlement and the global clear now commit together. Losing
        // that commit retains the earlier marker until explicit operator resume.
        sqlx::query("CREATE FUNCTION fail_report_clear() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.in_flight IS NULL AND OLD.in_flight IS NOT NULL THEN RAISE EXCEPTION 'test clear failure'; END IF; RETURN NEW; END $$")
            .execute(&database.pool).await.unwrap();
        sqlx::query("CREATE CONSTRAINT TRIGGER fail_report_clear AFTER UPDATE ON station_delegated_reporting DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_report_clear()")
            .execute(&database.pool).await.unwrap();
        runtime.deliver_delegated_reports(&genesis, "alice").await;
        runtime.initialize_report_control(None).await.unwrap();
        runtime.deliver_delegated_reports(&genesis, "alice").await;
        assert_eq!(portal.shared.reports.lock().await.len(), 1);
        let claim: Option<String> =
            sqlx::query_scalar("SELECT in_flight FROM station_delegated_reporting")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert!(claim.is_some());
        drop(runtime);
        database.cleanup().await;
    }
}
