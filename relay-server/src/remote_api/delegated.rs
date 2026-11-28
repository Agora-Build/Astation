//! Durable Station control state. Membership, feeds and ACK evidence share one
//! recovery-root transaction, so another replica cannot publish a rejected record.
use super::{HostBinding, Root};
use atem_client::{
    control::{
        principal_key_of,
        relay::{MAX_FEED_RECORDS, MAX_FETCH_ENTRIES},
        verify_control, AckLedger, CallRefused, ControlAbout, ControlAck, ControlAction,
        ControlBody, ControlCheck, ControlFeed, ControlPrincipal, ControlRecord, ControlSigner,
        ControlSyncResult, FeedEntry, FeedHead, Heads, LinkAssociation, MembershipFetchResult,
        RefusalCode, RefusalReason, RefusedCall, RelayError, ToStation,
    },
    membership::{Action, Head, MemberKind, MemberStatus, Membership, RolesChange},
    station_route::normalize_relay,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[cfg(test)]
#[path = "delegated_tests.rs"]
pub(crate) mod tests;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct Stored {
    version: u8,
    feed_id: String,
    records: Vec<Value>,
    ledger: Value,
    signing_high_water: BTreeMap<String, u64>,
    #[serde(default)]
    delivery: BTreeMap<String, DeliveryRetry>,
    #[serde(default)]
    report_control_seq: usize,
    #[serde(default)]
    report_control_hash: Option<String>,
}

/// Station-local receipt of the feed active when it accepted this socket's proof.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct ProvedFeed {
    origin: String,
    feed_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DeliveryRetry {
    attempts: u32,
    not_before: u64,
}

#[derive(Debug)]
pub(crate) enum Fault {
    Forbidden(RefusedCall),
    Invalid,
    Unavailable,
}

impl Fault {
    pub(crate) fn refusal(&self) -> Option<Value> {
        let Self::Forbidden(call) = self else {
            return None;
        };
        CallRefused {
            call: *call,
            code: RefusalCode::Forbidden,
        }
        .to_json()
        .ok()
    }
}

pub(super) fn recovery_record_review(record: &ControlRecord, log: &Membership) -> Value {
    let (verification, requirement) = match verify_control(record, log) {
        ControlCheck::Valid(_) => {
            let requirement = match (record.action(), record.feed()) {
                (ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. }, None) => "retain_host_record",
                (ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. }, Some(_)) => "retain_service_stop",
                _ => "service_state_reconciliation",
            };
            ("valid".to_owned(), requirement)
        }
        ControlCheck::Refused(RefusalReason::RemovedManager) =>
            ("removed_manager".to_owned(), "fresh_manager_signature"),
        ControlCheck::Pending(reason) => (format!("pending:{}", reason.code()), "authority_review"),
        ControlCheck::Refused(reason) => (reason.code().to_owned(), "authority_review"),
    };
    serde_json::json!({
        "record_id": record.record_id(),
        "principal": record.principal().name(),
        "principal_key": record.body().principal_key.map(|key| key.to_hex()),
        "signer": record.signer().name(record.principal()),
        "action": record.action().name(),
        "interrupt_running": matches!(record.action(), ControlAction::Revoke { interrupt_running: true } | ControlAction::InterruptRunning { .. }),
        "revoke_seq": match record.action() {
            ControlAction::InterruptRunning { revoke_seq } => revoke_seq,
            _ => None,
        },
        "issued_at": record.issued_at(),
        "verification": verification,
        "requirement": requirement,
    })
}

impl Stored {
    /// Classify each retained record at the head that recovery is reviewing.
    pub(super) fn recovery_review(
        &self,
        origin: &str,
        log: &Membership,
    ) -> Result<Value, Fault> {
        let inspection = self.recovery_inspection(origin, log)?;
        if self.signing_high_water.iter().any(|(principal, value)| {
            ControlPrincipal::parse(principal).is_none()
                || *value > atem_client::canonical::MAX_SAFE_INTEGER
        }) {
            return Err(Fault::Unavailable);
        }
        let mut seen = std::collections::BTreeSet::new();
        let mut records = Vec::new();
        for value in &self.records {
            let record = ControlRecord::parse(
                &serde_json::to_vec(value).map_err(|_| Fault::Unavailable)?,
            ).map_err(|_| Fault::Unavailable)?;
            // A reset carries the exact signed revoke or interrupt from this
            // origin. Covers, holds and releases are signed for the new feed.
            let stop = matches!(record.action(), ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. });
            if record.account_id() != log.account_id()
                || record.genesis_hash() != log.genesis_hash()
                || record.feed().is_some_and(|(station, feed)| station != origin || (!stop && feed != self.feed_id))
                || !seen.insert(record.record_id().to_owned())
                || self.signing_high_water.get(&record.principal().name())
                    .is_none_or(|watermark| *watermark < record.issued_at())
            {
                return Err(Fault::Unavailable);
            }
            records.push(recovery_record_review(&record, log));
        }
        Ok(serde_json::json!({
            "retained_feed_id": self.feed_id,
            "records": records,
            "retained_signing_watermarks": self.signing_high_water,
            "inspection": inspection,
        }))
    }

    /// Read-only operator diagnostics. These counts describe retained history,
    /// not a complete post-restore snapshot or permission to reopen the fence.
    pub(super) fn recovery_inspection(
        &self,
        origin: &str,
        log: &Membership,
    ) -> Result<Value, Fault> {
        let ledger = self.ledger(origin, log)?;
        if uuid::Uuid::parse_str(&self.feed_id)
            .ok()
            .filter(|id| id.get_version_num() == 4 && id.to_string() == self.feed_id)
            .is_none()
        {
            return Err(Fault::Unavailable);
        }
        let mut verification = BTreeMap::<String, usize>::new();
        for value in &self.records {
            let record = ControlRecord::parse(
                &serde_json::to_vec(value).map_err(|_| Fault::Unavailable)?,
            )
            .map_err(|_| Fault::Unavailable)?;
            let result = match verify_control(&record, log) {
                ControlCheck::Valid(_) => "valid".to_owned(),
                ControlCheck::Pending(reason) => format!("pending:{}", reason.code()),
                ControlCheck::Refused(reason) => reason.code().to_owned(),
            };
            *verification.entry(result).or_default() += 1;
        }
        Ok(serde_json::json!({
            "feed_id": self.feed_id,
            "head": self.records.len(),
            "record_verification": verification,
            "signing_watermarks": {
                "principals": self.signing_high_water.len(),
                "highest_issued_at": self.signing_high_water.values().max(),
            },
            "native_records_awaiting_effects": ledger.resign_alerts().len(),
            "ready_reports": ledger.pending_reports().len(),
            "refused_reports": ledger.refused_reports().len(),
            "dropped_reports": ledger.dropped_reports().len(),
            "reporting_stopped": ledger.reporting_stopped(),
            "delivery_retries": self.delivery.len(),
            "report_control_seq": self.report_control_seq,
        }))
    }

    fn new(origin: &str, log: &Membership) -> Result<Self, Fault> {
        Self::empty(origin, log, uuid::Uuid::new_v4().to_string())
    }

    fn empty(origin: &str, log: &Membership, feed_id: String) -> Result<Self, Fault> {
        let ledger = AckLedger::new(origin, log.account_id(), log.genesis_hash())
            .map_err(|_| Fault::Unavailable)?;
        Ok(Self {
            version: 1,
            feed_id,
            records: Vec::new(),
            ledger: ledger.to_json(),
            signing_high_water: BTreeMap::new(),
            delivery: BTreeMap::new(),
            report_control_seq: 0,
            report_control_hash: None,
        })
    }

    fn ledger(&self, origin: &str, log: &Membership) -> Result<AckLedger, Fault> {
        let ledger = AckLedger::from_json(&self.ledger).map_err(|_| Fault::Unavailable)?;
        if self.version != 1
            || ledger.origin() != origin
            || ledger.account_id() != log.account_id()
            || ledger.genesis_hash() != log.genesis_hash()
        {
            return Err(Fault::Unavailable);
        }
        Ok(ledger)
    }

    fn heads(&self, origin: &str, log: &Membership, now: u64) -> Result<Value, Fault> {
        self.ledger(origin, log)?;
        Heads {
            feeds: vec![FeedHead {
                origin: origin.into(),
                feed_id: self.feed_id.clone(),
                head: self.records.len() as u64,
                station_time: now,
            }],
            membership: log.head(),
        }
        .to_json()
        .map_err(|_| Fault::Unavailable)
    }

    fn native_status(&self, origin: &str, log: &Membership, ids: &[String]) -> Result<Value, Fault> {
        let outstanding: std::collections::BTreeSet<_> =
            self.ledger(origin, log)?.resign_alerts().into_iter().collect();
        let mut stored = std::collections::BTreeSet::new();
        for value in &self.records {
            let record = ControlRecord::parse(
                &serde_json::to_vec(value).map_err(|_| Fault::Unavailable)?,
            ).map_err(|_| Fault::Unavailable)?;
            if matches!(record.signer(), ControlSigner::Member(_))
                && matches!(record.action(), ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. })
            {
                stored.insert(record.record_id().to_owned());
            }
        }
        // The shared ledger counts per-effect host evidence. A feed cursor or
        // an HTTP storage receipt must never stand in for that evidence.
        Ok(serde_json::json!({
            "head": log.head().to_json(),
            "records": ids.iter().map(|id| serde_json::json!({
                "record_id":id,
                "state":if !stored.contains(id) { "unknown" }
                    else if outstanding.contains(id) { "awaiting_application" }
                    else { "effects_reported" }
            })).collect::<Vec<_>>()
        }))
    }

    fn response(
        &self,
        origin: &str,
        log: &Membership,
        call: &ToStation,
        now: u64,
    ) -> Result<Option<Value>, Fault> {
        self.ledger(origin, log)?;
        match call {
            ToStation::ControlSync(call) => {
                if call.origin != origin
                    || call.feed_id.as_ref().is_some_and(|id| id != &self.feed_id)
                {
                    return Err(Fault::Forbidden(RefusedCall::ControlSync));
                }
                let mut page = ControlSyncResult {
                    request_id: call.request_id.clone(),
                    origin: origin.into(),
                    feed_id: self.feed_id.clone(),
                    after: call.after,
                    head: self.records.len() as u64,
                    station_time: now,
                    records: Vec::new(),
                };
                for (index, value) in self
                    .records
                    .iter()
                    .enumerate()
                    .skip(usize::try_from(call.after).unwrap_or(usize::MAX))
                    .take(MAX_FEED_RECORDS)
                {
                    let record = ControlRecord::parse(
                        &serde_json::to_vec(value).map_err(|_| Fault::Unavailable)?,
                    )
                    .map_err(|_| Fault::Unavailable)?;
                    page.records.push(FeedEntry::new(index as u64 + 1, &record));
                    if matches!(page.to_json(), Err(RelayError::TooLarge)) {
                        page.records.pop();
                        if page.records.is_empty() {
                            return Err(Fault::Unavailable);
                        }
                        break;
                    }
                }
                page.to_json().map(Some).map_err(|_| Fault::Unavailable)
            }
            ToStation::MembershipFetch(call) => {
                let mut page = MembershipFetchResult {
                    head: log.head(),
                    entries: Vec::new(),
                };
                for entry in log
                    .entries()
                    .iter()
                    .filter(|entry| entry.seq > call.after)
                    .take(MAX_FETCH_ENTRIES)
                {
                    page.entries.push(entry.object().clone());
                    if matches!(page.to_json(), Err(RelayError::TooLarge)) {
                        page.entries.pop();
                        if page.entries.is_empty() {
                            return Err(Fault::Unavailable);
                        }
                        break;
                    }
                }
                page.to_json().map(Some).map_err(|_| Fault::Unavailable)
            }
            ToStation::ControlAck(_) => Ok(None),
        }
    }

    fn acknowledge(
        &mut self,
        origin: &str,
        log: &Membership,
        binding: &HostBinding,
        ack: &ControlAck,
        now: u64,
    ) -> Result<(), Fault> {
        if ack.feed_id != self.feed_id {
            return Err(Fault::Forbidden(RefusedCall::ControlAck));
        }
        let link = LinkAssociation {
            account_id: log.account_id().into(),
            genesis_hash: log.genesis_hash(),
            host_id: binding.host.clone(),
            host_trust_gen: log
                .host(&binding.host)
                .ok_or(Fault::Unavailable)?
                .host_trust_gen,
            connection_id: binding.connection.conn.clone(),
        };
        let next = self
            .ledger(origin, log)?
            .ack(&link, ack, now)
            .map_err(|reason| {
                if reason.reply().is_some() {
                    Fault::Forbidden(RefusedCall::ControlAck)
                } else {
                    Fault::Invalid
                }
            })?;
        self.ledger = next.next.to_json();
        Ok(())
    }

    fn update_ledger(
        &mut self,
        origin: &str,
        log: &Membership,
        update: LedgerUpdate,
        now: u64,
    ) -> Result<Value, Fault> {
        let ledger = self.ledger(origin, log)?;
        let transition = match update {
            LedgerUpdate::Tick => ledger.tick(now),
            LedgerUpdate::Confirm(id) => {
                self.delivery.remove(&id);
                ledger.confirm(&id)
            }
            LedgerUpdate::Refuse(id) => {
                self.delivery.remove(&id);
                ledger.refuse(&id)
            }
            LedgerUpdate::Retry { id, retry_after_ms } => {
                if ledger
                    .pending_reports()
                    .iter()
                    .any(|intent| intent.report_id == id)
                {
                    let retry = self.delivery.entry(id).or_insert(DeliveryRetry {
                        attempts: 0,
                        not_before: now,
                    });
                    retry.attempts = retry.attempts.saturating_add(1);
                    let delay = retry_after_ms
                        .unwrap_or_else(|| 1000u64.saturating_mul(1 << retry.attempts.min(8)))
                        .clamp(1000, 86_400_000);
                    retry.not_before = now
                        .saturating_add(delay)
                        .min(atem_client::canonical::MAX_SAFE_INTEGER);
                }
                ledger.tick(now)
            }
        };
        self.ledger = transition.next.to_json();
        self.delivery.retain(|id, _| {
            transition
                .next
                .pending_reports()
                .iter()
                .any(|intent| &intent.report_id == id)
        });
        Ok(serde_json::json!({
            "ledger":self.ledger,
            "reports": transition.next.pending_reports().iter()
                .filter(|intent| self.delivery.get(&intent.report_id).is_none_or(|retry| retry.not_before <= now))
                .map(|intent| intent.to_json()).collect::<Vec<_>>(),
            "resign_alerts":transition.next.resign_alerts(),
            "refused_reports":transition.next.refused_reports(),
            "stopped_client_id":transition.next.stopped_client_id(),
            "dropped_reports":transition.next.dropped_reports(),
        }))
    }

    fn reporting_control(
        &mut self,
        origin: &str,
        log: &Membership,
        events: &[ReportControlEvent],
        now: u64,
    ) -> Result<Value, Fault> {
        if events.len() < self.report_control_seq {
            return Err(Fault::Unavailable);
        }
        if self
            .report_control_hash
            .as_ref()
            .is_some_and(|prior| prior != &report_events_hash(&events[..self.report_control_seq]))
        {
            return Err(Fault::Unavailable);
        }
        let mut ledger = self.ledger(origin, log)?;
        for event in &events[self.report_control_seq..] {
            ledger = match event {
                ReportControlEvent::Stop(client) => ledger.stop_reporting(client),
                ReportControlEvent::Resume(client) => ledger.resume_reporting(client),
            }
            .map_err(|_| Fault::Unavailable)?
            .next;
        }
        self.report_control_seq = events.len();
        self.report_control_hash = Some(report_events_hash(events));
        self.ledger = ledger.to_json();
        self.update_ledger(origin, log, LedgerUpdate::Tick, now)
    }

    fn publish(
        &mut self,
        origin: &str,
        log: &Membership,
        record: &ControlRecord,
        revoked_at: Option<u64>,
        covered: &[String],
        now: u64,
    ) -> Result<bool, Fault> {
        if log.frozen().is_some()
            || !matches!(verify_control(record, log), ControlCheck::Valid(_))
            || record
                .feed()
                .is_some_and(|feed| feed != (origin, self.feed_id.as_str()))
        {
            return Err(Fault::Invalid);
        }
        for value in &self.records {
            let prior =
                ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| Fault::Unavailable)?)
                    .map_err(|_| Fault::Unavailable)?;
            if prior.record_id() == record.record_id() {
                return if prior.object().jcs() == record.object().jcs() {
                    Ok(false)
                } else {
                    Err(Fault::Invalid)
                };
            }
        }
        self.check_page(origin, record, now)?;
        let next = self.ledger(origin, log)?.record(record, revoked_at, covered, now)
            .map_err(|_| Fault::Invalid)?;
        self.push_verified(record);
        self.ledger = next.next.to_json();
        Ok(true)
    }

    fn check_page(&self, origin: &str, record: &ControlRecord, now: u64) -> Result<(), Fault> {
        // Prove that the full signed record fits a page before making it visible.
        ControlSyncResult {
            request_id: uuid::Uuid::new_v4().to_string(),
            origin: origin.into(),
            feed_id: self.feed_id.clone(),
            after: self.records.len() as u64,
            head: self.records.len() as u64 + 1,
            station_time: now,
            records: vec![FeedEntry::new(self.records.len() as u64 + 1, record)],
        }
        .to_json()
        .map(|_| ()).map_err(|_| Fault::Invalid)
    }

    fn push_verified(&mut self, record: &ControlRecord) {
        let principal = record.principal().name();
        let watermark = self.signing_high_water.entry(principal).or_default();
        *watermark = (*watermark).max(record.issued_at());
        self.records.push(record.object().to_json());
    }

    /// The shared snapshot checker has already classified carried stops and
    /// fresh controls. New acknowledgments start with a fresh ledger.
    pub(super) fn recovered(
        origin: &str, log: &Membership, feed_id: &str, records: &[ControlRecord],
        floors: BTreeMap<String, u64>, revocations: &BTreeMap<(String, String), u64>,
        events: &[ReportControlEvent], now: u64,
    ) -> Result<Self, Fault> {
        let mut feed = Self::empty(origin, log, feed_id.to_owned())?;
        feed.signing_high_water = floors;
        feed.reporting_control(origin, log, events, now)?;
        let mut ledger = feed.ledger(origin, log)?;
        for record in records {
            feed.check_page(origin, record, now)?;
            let revoked_at = match (record.signer(), record.principal(), record.action()) {
                (ControlSigner::Principal, ControlPrincipal::Service(id), ControlAction::Revoke { .. }) =>
                    revocations.get(&(id.clone(), record.principal_key().ok_or(Fault::Invalid)?.to_hex()))
                        .copied(),
                _ => None,
            };
            ledger = ledger.record(record, revoked_at, &covered_hosts(log, record.principal()), now)
                .map_err(|_| Fault::Invalid)?.next;
            feed.push_verified(record);
        }
        feed.ledger = ledger.to_json();
        Ok(feed)
    }

    fn plan_service(
        &self,
        origin: &str,
        log: &Membership,
        context: &crate::service_keys::ServiceKeyContext,
        expected_fingerprint: &str,
        desired: ServiceDesired,
        now: u64,
    ) -> Result<(Vec<ControlBody>, u64), Fault> {
        if context.genesis != log.genesis_hash().to_hex() || context.station_origin != origin {
            return Err(Fault::Invalid);
        }
        let member = log.member(&context.service_id).ok_or(Fault::Invalid)?;
        if !matches!(member.member.kind, MemberKind::Service { .. }) {
            return Err(Fault::Invalid);
        }
        let fingerprint = principal_key_of(&member.member.auth_key).map_err(|_| Fault::Invalid)?;
        if fingerprint.to_hex() != expected_fingerprint {
            return Err(Fault::Invalid);
        }
        let principal = ControlPrincipal::Service(context.service_id.clone());
        let records = self
            .records
            .iter()
            .map(|value| {
                ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| Fault::Unavailable)?)
                    .map_err(|_| Fault::Unavailable)
            })
            .collect::<Result<Vec<_>, _>>()?;
        let own: Vec<_> = records
            .iter()
            .filter(|record| {
                record.principal() == &principal && record.signer() == &ControlSigner::Principal
            })
            .collect();
        let previously_signed = own.iter().map(|r| r.issued_at()).max().unwrap_or(0);
        if own.iter().any(|record| {
            record.principal_key() != Some(fingerprint)
                || record.about().integration_id.as_deref() != Some(context.integration_id.as_str())
                || record.feed().map(|(station, _)| station) != Some(origin)
        }) {
            return Err(Fault::Invalid);
        }
        let revoked = records.iter().any(|record| {
            record.principal() == &principal
                && matches!(record.action(), ControlAction::Revoke { .. })
        });
        let own_revoked = own
            .iter()
            .any(|record| matches!(record.action(), ControlAction::Revoke { .. }));
        let interrupted = own.iter().any(|record| {
            matches!(
                record.action(),
                ControlAction::Revoke {
                    interrupt_running: true
                } | ControlAction::InterruptRunning { .. }
            )
        });
        let covered_before = own
            .iter()
            .any(|record| record.action() == ControlAction::Cover);
        let held = own
            .iter()
            .rev()
            .find_map(|record| match record.action() {
                ControlAction::Hold => Some(true),
                ControlAction::Release => Some(false),
                _ => None,
            })
            .unwrap_or(false);
        let mut actions = Vec::new();
        match desired {
            ServiceDesired::Revoked { interrupt_running } => {
                if !own_revoked {
                    actions.push(ControlAction::Revoke { interrupt_running });
                } else if interrupt_running && !interrupted {
                    actions.push(ControlAction::InterruptRunning { revoke_seq: None });
                }
            }
            _ if revoked || member.status == atem_client::membership::MemberStatus::Removed => {}
            ServiceDesired::Active | ServiceDesired::Held => {
                if !covered_before {
                    actions.push(ControlAction::Cover);
                }
                if desired == ServiceDesired::Held && !held {
                    actions.push(ControlAction::Hold);
                }
                if desired == ServiceDesired::Active && held {
                    actions.push(ControlAction::Release);
                }
            }
        }
        let mut bodies = Vec::new();
        if actions.is_empty() {
            return Ok((bodies, previously_signed));
        }
        let previous = self.signing_high_water.get(&principal.name()).copied().unwrap_or(0);
        // Reserve successive elapsed milliseconds ending at the observed wall time.
        // The whole cover/hold pair must fit before either signature is produced.
        let first = now.checked_sub(actions.len() as u64 - 1).ok_or(Fault::Unavailable)?;
        if first <= previous || now > atem_client::canonical::MAX_SAFE_INTEGER {
            return Err(Fault::Unavailable);
        }
        for (action, issued_at) in actions.into_iter().zip(first..=now) {
            bodies.push(ControlBody {
                account_id: log.account_id().into(),
                genesis_hash: log.genesis_hash(),
                feed: Some(ControlFeed {
                    origin: origin.into(),
                    feed_id: self.feed_id.clone(),
                }),
                principal: principal.clone(),
                principal_key: Some(fingerprint),
                signer: ControlSigner::Principal,
                action,
                record_id: uuid::Uuid::new_v4().to_string(),
                issued_at,
                about: ControlAbout {
                    integration_id: Some(context.integration_id.clone()),
                    by: "reconciled".into(),
                },
            });
        }
        Ok((bodies, previously_signed))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ServiceDesired {
    Active,
    Held,
    Revoked { interrupt_running: bool },
}

impl ServiceDesired {
    pub(crate) fn from_policy(policy: &crate::integration_feed::IntegrationPolicy) -> Option<Self> {
        match policy.state.as_str() {
            "expired" => policy.held.map(|held| if held { Self::Held } else { Self::Active }),
            "provisioning" | "waiting_for_host" | "ready" if policy.held == Some(true) => Some(Self::Held),
            "provisioning" | "waiting_for_host" | "ready" => Some(Self::Active),
            "paused" => Some(Self::Held),
            "revoking" | "revoked" => Some(Self::Revoked {
                interrupt_running: policy.interrupt_running.unwrap_or(false),
            }),
            _ => None,
        }
    }
}

pub(crate) enum ServiceReconciliation {
    Current,
    FeedChanged,
    TimeSavedWithControlsPending,
}

impl super::RecoveryStore {
    pub(crate) async fn reconcile_service_in(
        &self,
        tx: &mut sqlx::PgConnection,
        owner: &str,
        context: &crate::service_keys::ServiceKeyContext,
        vault: &crate::service_keys::ServiceKeyVault,
        desired: ServiceDesired,
        checkpoint: &crate::integration_feed::PolicyCheckpoint,
    ) -> Result<ServiceReconciliation, ()> {
        let origin = self.delegated_origin.get().ok_or(())?;
        self.lock_delegated_recovery(tx).await.map_err(|_| ())?;
        let (subject, state) = Self::locked_root(tx, &context.genesis)
            .await
            .map_err(|_| ())?
            .ok_or(())?;
        if subject != owner {
            return Err(());
        }
        let mut root: Root = serde_json::from_value(state).map_err(|_| ())?;
        let genesis = atem_client::Hash32::from_hex(&context.genesis).map_err(|_| ())?;
        let mut log =
            Membership::from_stored(&root.account, &genesis, &root.membership).map_err(|_| ())?;
        let clock = super::now();
        log.advance(&clock);
        if log.frozen().is_some() {
            return Err(());
        }
        let policy_allows_signing = || {
            if desired != ServiceDesired::Active {
                return true;
            }
            let now = chrono::Utc::now();
            checkpoint.allows_control_release(&context.integration_id, &context.owner, now.timestamp())
                && checkpoint.binding_feed_current(log.account_id(), &context.genesis, now.timestamp_millis())
        };
        if !policy_allows_signing() || (desired == ServiceDesired::Active
            && !checkpoint.allows_list_release_in(tx, &context.owner, log.account_id(), &context.genesis).await?)
        {
            return Err(());
        }
        ensure(&mut root, origin, &log).map_err(|_| ())?;
        let feed = root.delegated.get_mut(origin).ok_or(())?;
        let fingerprint = checkpoint.integrations.get(&context.integration_id)
            .and_then(|policy| policy.r9_svc.as_deref()).ok_or(())?;
        let (bodies, previously_signed) = feed
            .plan_service(origin, &log, context, fingerprint, desired, clock.wall_ms)
            .map_err(|_| ())?;
        let revoked_at = if matches!(desired, ServiceDesired::Revoked { .. }) {
            checkpoint.known_revocation_ms(&context.integration_id)?
        } else {
            None
        };
        let first_revoke = bodies.iter().any(|body| matches!(body.action, ControlAction::Revoke { .. }));
        if let Some(at) = revoked_at.filter(|_| !first_revoke) {
            let principal = ControlPrincipal::Service(context.service_id.clone()).name();
            let learned = feed.ledger(origin, &log).map_err(|_| ())?
                .learn_revoked_at(&principal, at, clock.wall_ms).map_err(|_| ())?.next.to_json();
            if learned != feed.ledger {
                feed.ledger = learned;
                super::finish_root(&mut root, &log, clock.wall_ms).map_err(|_| ())?;
                Self::save_root(tx, &context.genesis, owner, root).await.map_err(|_| ())?;
                // A later interrupt may need a private key or a signing reservation.
                // Persist the original time even if that separate operation fails.
                return Ok(if bodies.is_empty() {
                    ServiceReconciliation::Current
                } else {
                    ServiceReconciliation::TimeSavedWithControlsPending
                });
            }
        }
        if bodies.is_empty() {
            return Ok(ServiceReconciliation::Current);
        }
        let signer = crate::service_keys::load_approved_in(tx, vault, context, fingerprint).await?;
        let covered = covered_hosts(&log, &bodies[0].principal);
        let store = self.signing_ceilings.get().ok_or(())?;
        // A recovery review may have observed a reservation that never reached
        // the feed. Require the signing store to cover it before reserving more.
        let (floor, conflicting_key): (i64, bool) = sqlx::query_as(
            "SELECT COALESCE(MAX(highest_ms) FILTER (WHERE key_hash=$5),0),
                    COALESCE(BOOL_OR(key_hash<>$5 AND highest_ms>0),false)
             FROM station_delegated_observed_reservations
             WHERE origin=$1 AND account_id=$2 AND genesis_hash=$3 AND service_id=$4",
        )
        .bind(origin).bind(log.account_id()).bind(&context.genesis)
        .bind(&context.service_id).bind(fingerprint)
        .fetch_one(&mut *tx).await.map_err(|_| ())?;
        if conflicting_key {
            return Err(());
        }
        let required_floor = previously_signed.max(u64::try_from(floor).map_err(|_| ())?);
        let mark = store.live_mark(log.account_id(), &context.genesis, &context.service_id, fingerprint,
            required_floor, feed.signing_high_water.get(&bodies[0].principal.name()).copied().unwrap_or(0)).await?;
        for record in signer.sign_control_batch(store, &log, &feed.feed_id, &bodies, &mark, policy_allows_signing).await? {
            feed.publish(
                origin,
                &log,
                &record,
                revoked_at,
                &covered,
                clock.wall_ms,
            )
            .map_err(|_| ())?;
        }
        super::finish_root(&mut root, &log, clock.wall_ms).map_err(|_| ())?;
        Self::save_root(tx, &context.genesis, owner, root)
            .await
            .map_err(|_| ())?;
        // A signing reservation can wait on the independent store. Returning
        // an error rolls back this publication if the feed aged out meanwhile.
        if !policy_allows_signing() {
            return Err(());
        }
        Ok(ServiceReconciliation::FeedChanged)
    }
}

pub(super) fn ensure(root: &mut Root, origin: &str, log: &Membership) -> Result<(), Fault> {
    if normalize_relay(origin).as_deref() != Ok(origin) {
        return Err(Fault::Unavailable);
    }
    if !root.delegated.contains_key(origin) {
        root.delegated
            .insert(origin.into(), Stored::new(origin, log)?);
    }
    root.delegated[origin].ledger(origin, log)?;
    Ok(())
}

pub(super) fn proved_feed(root: &mut Root, origin: &str, log: &Membership) -> Result<ProvedFeed, Fault> {
    ensure(root, origin, log)?;
    Ok(ProvedFeed { origin: origin.into(), feed_id: root.delegated[origin].feed_id.clone() })
}

pub(super) fn current_link(root: &Root, log: &Membership, origin: &str, binding: &HostBinding) -> bool {
    binding.delegated_feed.as_ref().is_some_and(|proof| proof.origin == origin
        && root.delegated.get(origin).is_some_and(|feed| feed.feed_id == proof.feed_id))
        && root.current(binding) && binding.valid(log) && log.frozen().is_none()
}

pub(super) fn heads(root: &Root, origin: &str, log: &Membership, now: u64) -> Result<Value, Fault> {
    root.delegated
        .get(origin)
        .ok_or(Fault::Unavailable)?
        .heads(origin, log, now)
}

pub(super) fn response(
    root: &Root,
    origin: &str,
    log: &Membership,
    call: &ToStation,
    now: u64,
) -> Result<Option<Value>, Fault> {
    root.delegated
        .get(origin)
        .ok_or(Fault::Unavailable)?
        .response(origin, log, call, now)
}

pub(super) fn acknowledge(
    root: &mut Root,
    origin: &str,
    log: &Membership,
    binding: &HostBinding,
    ack: &ControlAck,
    now: u64,
) -> Result<(), Fault> {
    root.delegated
        .get_mut(origin)
        .ok_or(Fault::Unavailable)?
        .acknowledge(origin, log, binding, ack, now)
}

pub(super) fn publish(
    root: &mut Root,
    origin: &str,
    log: &Membership,
    record: &ControlRecord,
    revoked_at: Option<u64>,
    covered: &[String],
    now: u64,
) -> Result<bool, Fault> {
    root.delegated
        .get_mut(origin)
        .ok_or(Fault::Unavailable)?
        .publish(origin, log, record, revoked_at, covered, now)
}

pub(super) fn reserve(
    root: &mut Root,
    origin: &str,
    log: &Membership,
    principal: &str,
    now: u64,
) -> Result<u64, Fault> {
    let feed = root.delegated.get_mut(origin).ok_or(Fault::Unavailable)?;
    feed.ledger(origin, log)?;
    if atem_client::control::ControlPrincipal::parse(principal).is_none() {
        return Err(Fault::Invalid);
    }
    let previous = feed.signing_high_water.get(principal).copied().unwrap_or(0);
    let next = now.max(previous.checked_add(1).ok_or(Fault::Unavailable)?);
    if next > atem_client::canonical::MAX_SAFE_INTEGER {
        return Err(Fault::Unavailable);
    }
    feed.signing_high_water.insert(principal.into(), next);
    Ok(next)
}

pub(crate) enum Command {
    Ensure,
    Ack(ControlAck),
    Publish {
        record: ControlRecord,
        revoked_at: u64,
        covered: Vec<String>,
    },
    Reserve {
        principal: String,
    },
    Ledger(LedgerUpdate),
    ReportingControl(Vec<ReportControlEvent>),
    Owner(OwnerCommand),
}

pub(crate) enum OwnerCommand {
    Heads,
    Sync(atem_client::control::ControlSync),
    Status { record_ids: Vec<String>, expected: Head },
    Reserve {
        principal: ControlPrincipal,
        manager: String,
        expected: Head,
    },
    Publish {
        record: ControlRecord,
        expected: Head,
    },
}

fn manager(log: &Membership, id: &str) -> bool {
    log.member(id)
        .is_some_and(|member| member.status == MemberStatus::Active && member.member.is_manager())
}

fn covered_hosts(log: &Membership, principal: &ControlPrincipal) -> Vec<String> {
    let mut hosts = std::collections::BTreeSet::new();
    for entry in log.entries() {
        match (&entry.action, principal) {
            (Action::Add { member }, ControlPrincipal::Service(id)) if member.device_id == *id => {
                if let MemberKind::Service { scope, .. } = &member.kind {
                    hosts.extend(scope.hosts.iter().cloned());
                }
            }
            (
                Action::SetRoles {
                    device_id,
                    change: RolesChange::Service { scope, .. },
                },
                ControlPrincipal::Service(id),
            ) if device_id == id => hosts.extend(scope.hosts.iter().cloned()),
            (Action::AddHost { host }, ControlPrincipal::Host(_)) => {
                hosts.insert(host.host_id.clone());
            }
            _ => {}
        }
    }
    hosts.into_iter().collect()
}

fn owner(
    root: &mut Root,
    origin: &str,
    log: &Membership,
    command: OwnerCommand,
    now: u64,
) -> Result<Value, Fault> {
    match command {
        OwnerCommand::Heads => heads(root, origin, log, now),
        OwnerCommand::Sync(call) => {
            response(root, origin, log, &ToStation::ControlSync(call), now)?
                .ok_or(Fault::Unavailable)
        }
        OwnerCommand::Status { record_ids, expected } => {
            let unique: std::collections::BTreeSet<_> = record_ids.iter().collect();
            if expected != log.head() || record_ids.is_empty() || record_ids.len() > 64
                || unique.len() != record_ids.len()
                || !record_ids.iter().all(|id| uuid::Uuid::parse_str(id).is_ok_and(|value|
                    value.get_version_num() == 4 && value.to_string() == *id))
            { return Err(Fault::Invalid); }
            root.delegated.get(origin).ok_or(Fault::Unavailable)?
                .native_status(origin, log, &record_ids)
        }
        OwnerCommand::Reserve {
            principal,
            manager: id,
            expected,
        } => {
            if expected != log.head() || !manager(log, &id)
                || match &principal {
                    ControlPrincipal::Service(id) => !log.member(id).is_some_and(|member|
                        matches!(member.member.kind, MemberKind::Service { .. })),
                    ControlPrincipal::Host(id) => !log.entries().iter().any(|entry|
                        matches!(&entry.action, Action::AddHost { host } if host.host_id == *id)),
                }
            { return Err(Fault::Invalid); }
            Ok(serde_json::json!({"issued_at":reserve(root, origin, log, &principal.name(), now)?}))
        }
        OwnerCommand::Publish { record, expected } => {
            if expected != log.head()
                || !matches!(record.signer(), ControlSigner::Member(id) if manager(log, id))
                || !matches!(
                    record.action(),
                    ControlAction::Revoke { .. } | ControlAction::InterruptRunning { .. }
                )
            {
                return Err(Fault::Invalid);
            }
            let covered = covered_hosts(log, record.principal());
            let appended = publish(root, origin, log, &record, None, &covered, now)?;
            Ok(serde_json::json!({"appended":appended,"record_id":record.record_id()}))
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) enum ReportControlEvent {
    Stop(String),
    Resume(String),
}

pub(super) fn report_events_hash(events: &[ReportControlEvent]) -> String {
    atem_client::Hash32::of(&serde_json::to_vec(events).expect("serializable report control events")).to_hex()
}

pub(crate) enum LedgerUpdate {
    Tick,
    Confirm(String),
    Refuse(String),
    Retry {
        id: String,
        retry_after_ms: Option<u64>,
    },
}

pub(super) fn apply(
    root: &mut Root,
    log: &Membership,
    origin: &str,
    binding: Option<&HostBinding>,
    command: Command,
    now: u64,
) -> Result<Value, Fault> {
    // Already-committed report intents may settle during a membership freeze;
    // a freeze still forbids new records, reservations and host evidence.
    if log.frozen().is_some()
        && !matches!(&command, Command::Ledger(_) | Command::ReportingControl(_))
    {
        return Err(Fault::Invalid);
    }
    if let Some(binding) = binding {
        if !current_link(root, log, origin, binding) {
            return Err(match command {
                Command::Ack(_) => Fault::Forbidden(RefusedCall::ControlAck),
                _ => Fault::Invalid,
            });
        }
    } else {
        ensure(root, origin, log)?;
    }
    match command {
        Command::Ensure => heads(root, origin, log, now),
        Command::Ack(ack) => {
            acknowledge(root, origin, log, binding.ok_or(Fault::Invalid)?, &ack, now)?;
            Ok(serde_json::json!({}))
        }
        Command::Publish {
            record,
            revoked_at,
            covered,
        } => {
            if binding.is_some() {
                return Err(Fault::Invalid);
            }
            let appended = publish(root, origin, log, &record, Some(revoked_at), &covered, now)?;
            Ok(serde_json::json!({"appended":appended}))
        }
        Command::Reserve { principal } => {
            if binding.is_some() {
                return Err(Fault::Invalid);
            }
            Ok(serde_json::json!({"issued_at":reserve(root, origin, log, &principal, now)?}))
        }
        Command::Ledger(update) => {
            if binding.is_some() {
                return Err(Fault::Invalid);
            }
            root.delegated
                .get_mut(origin)
                .ok_or(Fault::Unavailable)?
                .update_ledger(origin, log, update, now)
        }
        Command::ReportingControl(events) => {
            if binding.is_some() {
                return Err(Fault::Invalid);
            }
            root.delegated
                .get_mut(origin)
                .ok_or(Fault::Unavailable)?
                .reporting_control(origin, log, &events, now)
        }
        Command::Owner(command) => {
            if binding.is_some() {
                return Err(Fault::Invalid);
            }
            owner(root, origin, log, command, now)
        }
    }
}
