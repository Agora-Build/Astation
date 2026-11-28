use super::super::{Hash32, RecoveryStore, Root};
use super::*;
use crate::{
    account_identity::VerifiedServiceToken,
    integration_feed::{client_id, FeedBinding, PolicyStore},
};
use atem_client::membership::service_key_fingerprint_of;
use sqlx::PgConnection;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Grant {
    source: FeedBinding,
    revision: u64,
    fingerprint: String,
    binding_version: Option<u64>,
}

pub(in crate::remote_api::recovery) fn new_service_challenge(
    root: &Root,
    challenge: &ReportChallenge,
) -> Option<(String, String)> {
    let id = challenge.signer().strip_prefix("service:svc-")?;
    let nonce = URL_SAFE_NO_PAD.encode(challenge.nonce());
    (client_id(id, "i-") && !root.verifier_reports.contains_key(&nonce))
        .then(|| (nonce, id.to_owned()))
}

async fn grant(
    db: &mut PgConnection,
    portal: &FeedBinding,
    owner: &str,
    log: &Membership,
    id: &str,
) -> Result<Option<Grant>, sqlx::Error> {
    let bad = || sqlx::Error::Protocol("external verifier policy unavailable".into());
    let member = format!("svc-{id}");
    let Some(fingerprint) = service_key_fingerprint_of(log, &member) else {
        return Ok(None);
    };
    let checkpoint = PolicyStore::lock_for_binding(db, portal)
        .await
        .map_err(|_| bad())?;
    // A second report credential can see a pause before this replica's
    // credential polls. Catch up through the intervening events before serving.
    let newer: bool = sqlx::query_scalar("SELECT EXISTS(SELECT FROM station_integration_policy
        WHERE binding::jsonb @> $1 AND ((checkpoint::jsonb->>'cursor')::numeric > $2::bigint
            OR (checkpoint::jsonb->'portal_snapshot'->>'cursor')::numeric > $2::bigint))")
        .bind(json!({"issuer":portal.issuer,"portal_origin":portal.portal_origin,"station_origin":portal.station_origin}))
        .bind(i64::try_from(checkpoint.cursor).map_err(|_| bad())?)
        .fetch_one(&mut *db).await?;
    if newer {
        return Ok(None);
    }
    let genesis = log.genesis_hash().to_hex();
    if !checkpoint
        .allows_list_release_in(db, owner, log.account_id(), &genesis)
        .await
        .map_err(|_| bad())?
    {
        return Ok(None);
    }
    let version = checkpoint
        .portal_snapshot
        .as_ref()
        .and_then(|cut| cut.bindings.as_ref())
        .and_then(|rows| {
            rows.iter()
                .find(|row| row.account_id == log.account_id() && row.genesis_hash == genesis)
        })
        .map(|row| row.version);
    let now = chrono::Utc::now().timestamp_millis();
    Ok(checkpoint
        .external_verifier_grant(id, owner, &fingerprint, now)
        .map(|revision| Grant {
            source: portal.clone(),
            revision,
            fingerprint,
            binding_version: version,
        }))
}

pub(in crate::remote_api::recovery) async fn bind(
    db: &mut PgConnection,
    portal: &FeedBinding,
    principal: &str,
    genesis: Hash32,
    root: &mut Root,
    nonce: &str,
    id: &str,
) -> Result<(), sqlx::Error> {
    let bound = native_grant(db, portal, principal, genesis, root, id).await?;
    if let Some(record) = root.verifier_reports.get_mut(nonce) {
        record.external_grant = bound;
    }
    Ok(())
}

async fn native_grant(
    db: &mut PgConnection,
    portal: &FeedBinding,
    principal: &str,
    genesis: Hash32,
    root: &Root,
    id: &str,
) -> Result<Option<Grant>, sqlx::Error> {
    let owner: Option<String> = sqlx::query_scalar(
        "SELECT subject FROM account_identities WHERE issuer=$1 AND principal=$2",
    )
    .bind(&portal.issuer)
    .bind(principal)
    .fetch_optional(&mut *db)
    .await?;
    let Some(owner) = owner else { return Ok(None) };
    let log = Membership::from_stored(&root.account, &genesis, &root.membership)
        .map_err(|_| sqlx::Error::Protocol("invalid verifier membership".into()))?;
    grant(db, portal, &owner, &log, id).await
}

/// A native retry or read can return a previously stored integration answer.
/// Recheck its original grant before disclosing any report from that round.
pub(in crate::remote_api::recovery) async fn readable(
    db: &mut PgConnection,
    portal: Option<&FeedBinding>,
    principal: &str,
    hash: Hash32,
    root: &Root,
    command: &Command,
) -> Result<bool, sqlx::Error> {
    let nonce = match command {
        Command::Create { challenge, .. } => URL_SAFE_NO_PAD.encode(challenge.nonce()),
        Command::Read { nonce } | Command::Publish { nonce, .. } => nonce.clone(),
        Command::Inbox { .. } | Command::Close { .. } => return Ok(true),
    };
    let Some(record) = root
        .verifier_reports
        .get(&nonce)
        .filter(|r| r.external_answered)
    else {
        return Ok(true);
    };
    let Some(saved) = &record.external_grant else {
        return Ok(false);
    };
    let Some(portal) = portal.filter(|portal| **portal == saved.source) else {
        return Ok(false);
    };
    let Some(id) = record.challenge["signer"]
        .as_str()
        .and_then(|s| s.strip_prefix("service:svc-"))
    else {
        return Ok(false);
    };
    Ok(native_grant(db, portal, principal, hash, root, id)
        .await?
        .as_ref()
        == Some(saved))
}

pub(crate) enum ExternalVerifierRequest {
    Inbox { slot: String, expected: Head },
    Answer { nonce: String, report: Value },
}

fn hidden() -> Reply {
    error(StatusCode::NOT_FOUND, "verifier_requests_not_found")
}

impl RecoveryStore {
    pub(crate) async fn external_verifier(
        &self,
        portal: &FeedBinding,
        genesis: &str,
        token: &VerifiedServiceToken,
        request: ExternalVerifierRequest,
    ) -> Result<Reply, sqlx::Error> {
        let unavailable = || {
            error(
                StatusCode::SERVICE_UNAVAILABLE,
                "verifier_report_unavailable",
            )
        };
        let Some(binding) = self.active_delegated_binding() else {
            return Ok(unavailable());
        };
        if binding.origin != portal.station_origin || token.identity.issuer != portal.issuer {
            return Ok(hidden());
        }
        let Some(pool) = &self.pool else {
            return Ok(unavailable());
        };
        let Ok(hash) = Hash32::from_hex(genesis) else {
            return Ok(hidden());
        };
        let mut tx = pool.begin().await?;
        sqlx::query("SET LOCAL statement_timeout='5s'")
            .execute(&mut *tx)
            .await?;
        binding.lock(&mut tx).await?;
        let Some((principal, data)) = Self::locked_root(&mut tx, genesis).await? else {
            return Ok(hidden());
        };
        let owned: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM account_identities WHERE issuer=$1 AND subject=$2 AND principal=$3)")
            .bind(&portal.issuer).bind(&token.identity.subject).bind(&principal).fetch_one(&mut *tx).await?;
        if !owned {
            return Ok(hidden());
        }
        let mut root: Root = serde_json::from_value(data)
            .map_err(|_| sqlx::Error::Protocol("invalid verifier root".into()))?;
        let log = Membership::from_stored(&root.account, &hash, &root.membership)
            .map_err(|_| sqlx::Error::Protocol("invalid verifier membership".into()))?;
        let Some(grant) = grant(
            &mut tx,
            portal,
            &token.identity.subject,
            &log,
            &token.client_id,
        )
        .await?
        else {
            return Ok(hidden());
        };
        let now = chrono::Utc::now();
        if grant.fingerprint != token.service_fingerprint || now.timestamp() >= token.expires_at {
            return Ok(hidden());
        }
        let now_ms = u64::try_from(now.timestamp_millis())
            .map_err(|_| sqlx::Error::Protocol("invalid verifier clock".into()))?;
        let signer = format!("service:svc-{}", token.client_id);
        let (reply, changed) = match request {
            ExternalVerifierRequest::Inbox { slot, expected } => {
                fetch(&mut root, &log, &grant, &signer, &slot, expected, now_ms)
            }
            ExternalVerifierRequest::Answer { nonce, report } => {
                answer(&mut root, &log, &grant, &signer, &nonce, report, now_ms)
            }
        }
        .unwrap_or_else(|refusal| (refusal, false));
        if changed {
            Self::save_root(&mut tx, genesis, &principal, root).await?;
        }
        tx.commit().await?;
        Ok(reply)
    }
}

fn fetch(
    root: &mut Root,
    log: &Membership,
    grant: &Grant,
    signer: &str,
    slot: &str,
    expected: Head,
    now: u64,
) -> Result<(Reply, bool), Reply> {
    let challenges = inbox_challenges(
        &root.verifier_reports,
        log,
        &grant.source.station_origin,
        signer,
        slot,
        expected,
        now,
        Some(grant),
    )?;
    let mut changed = false;
    for challenge in &challenges {
        let nonce = URL_SAFE_NO_PAD.encode(challenge.nonce());
        let record = root
            .verifier_reports
            .get_mut(&nonce)
            .ok_or_else(super::changed)?;
        if record.first_external_fetch_ms.is_none() {
            record.first_external_fetch_ms = Some(now);
            changed = true;
        }
    }
    Ok((
        (
            StatusCode::OK,
            Json(json!({"challenges":challenges.iter()
        .map(ReportChallenge::to_json).collect::<Vec<_>>()})),
        ),
        changed,
    ))
}

fn answer(
    root: &mut Root,
    log: &Membership,
    grant: &Grant,
    signer: &str,
    nonce: &str,
    report: Value,
    now: u64,
) -> Result<(Reply, bool), Reply> {
    let record = root
        .verifier_reports
        .get_mut(nonce)
        .filter(|r| r.external_grant.as_ref() == Some(grant) && r.first_external_fetch_ms.is_some())
        .ok_or_else(hidden)?;
    let challenge =
        ReportChallenge::parse(record.challenge.to_string().as_bytes()).map_err(|_| changed())?;
    if challenge.signer() != signer || challenge.origin() != grant.source.station_origin {
        return Err(hidden());
    }
    if record.closed || now >= challenge.expires_at() {
        return Err(closed());
    }
    if challenge.issued_at() > now || record.head != log.head().to_json() {
        return Err(changed());
    }
    let bytes = jcs(&report).map_err(|_| invalid())?;
    let proof =
        verify_verifier_report(log, bytes.as_bytes(), &challenge, now).map_err(|_| invalid())?;
    let process = URL_SAFE_NO_PAD.encode(proof.process);
    let stored = record.reports.get(&process);
    if stored.is_some_and(|previous| previous != &report) {
        return Err(changed());
    }
    let write = stored.is_none() || !record.external_answered;
    if stored.is_none() {
        if record.reports.len() >= MAX_REPORTS {
            return Err(error(
                StatusCode::TOO_MANY_REQUESTS,
                "verifier_report_limit",
            ));
        }
        record.reports.insert(process, report);
    }
    record.external_answered = true;
    let reply = if record.reports.len() > 1 {
        error(StatusCode::CONFLICT, "verifier_process_conflict")
    } else {
        (StatusCode::OK, Json(json!({"accepted":true})))
    };
    Ok((reply, write))
}

#[cfg(all(test, feature = "delegated-host-work"))]
#[path = "external/tests.rs"]
mod tests;
