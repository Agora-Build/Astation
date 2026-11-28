//! Signed candidate service records remain evidence after another draft or plan replaces them.
use super::{
    checkpoint, history::MAX_RECORDS, invalid, memberships, source_hash, Binding, Prepared,
    MAX_STATE,
};
use atem_client::{
    control::{verify_control, ControlCheck, ControlPrincipal, ControlRecord, ControlSigner},
    membership::Membership,
    Hash32,
};
use serde_json::{json, Value};
use sqlx::{PgConnection, Postgres, Transaction};
use std::collections::{BTreeMap, BTreeSet};

#[derive(sqlx::FromRow)]
pub(super) struct Component {
    source_hash: String,
    bodies_hash: String,
    membership_seq: i64,
    membership_hash: String,
    records_hash: String,
    records: Value,
    pub(super) signing_cut: Option<Value>,
}

impl Component {
    pub(super) fn verify(
        &self,
        plan: &Prepared,
        origin: &str,
        log: &Membership,
    ) -> Result<Vec<ControlRecord>, sqlx::Error> {
        let head = log.head();
        let values = self.records.as_array().ok_or_else(invalid)?;
        if values.is_empty()
            || values.len() > MAX_RECORDS
            || self.membership_seq != head.seq as i64
            || self.membership_hash != head.hash.to_hex()
            || Hash32::from_hex(&self.source_hash).is_err()
            || self.records_hash != source_hash(&self.records)?
            || log.frozen().is_some()
        {
            return Err(invalid());
        }
        let mut ids = BTreeSet::new();
        let mut bodies = Vec::with_capacity(values.len());
        let mut records = Vec::with_capacity(values.len());
        for value in values {
            let record = ControlRecord::parse(&serde_json::to_vec(value).map_err(|_| invalid())?)
                .map_err(|_| invalid())?;
            if record.feed() != Some((origin, plan.candidate_feed_id.as_str()))
                || !matches!(record.principal(), ControlPrincipal::Service(_))
                || record.signer() != &ControlSigner::Principal
                || !ids.insert(record.record_id().to_owned())
                || !matches!(verify_control(&record, log), ControlCheck::Valid(_))
            {
                return Err(invalid());
            }
            bodies.push(record.body().to_json());
            records.push(record);
        }
        if self.bodies_hash != source_hash(&Value::Array(bodies))? {
            return Err(invalid());
        }
        if let Some(cut) = &self.signing_cut {
            self.verify_signing_cut(cut, plan, &records)?;
        }
        Ok(records)
    }

    fn verify_signing_cut(
        &self,
        cut: &Value,
        plan: &Prepared,
        records: &[ControlRecord],
    ) -> Result<(), sqlx::Error> {
        let clock = &cut["service_clock_evidence"];
        let portal_hash = source_hash(&json!({
            "plan_id":plan.plan_id, "reconstruction_hash":clock["reconstruction_hash"],
            "source":cut["portal_service_evidence"],
        }))?;
        let source = super::service_drafts::source_commitment(
            &clock["reconstruction_hash"],
            &json!(source_hash(clock)?),
            &json!(portal_hash),
        )?;
        if clock["plan_id"] != plan.plan_id
            || clock["source_hash"] != plan.source_hash
            || clock["reconstruction_hash"] != source_hash(&cut["reconstruction"])?
            || source != self.source_hash
        {
            return Err(invalid());
        }
        let mut previous = BTreeMap::new();
        for record in records {
            let principal = record.principal().name();
            let mark: crate::service_signing_ceilings::SigningMark =
                serde_json::from_value(clock["snapshot_signing_marks"][&principal].clone())
                    .map_err(|_| invalid())?;
            if record.principal_key().ok_or_else(invalid)?.to_hex() != mark.key_fingerprint
                || mark.sign_above_ms < mark.highest_reserved_ms
                || record.issued_at() <= mark.sign_above_ms
                || previous
                    .insert(principal, record.issued_at())
                    .is_some_and(|old: u64| old.checked_add(1) != Some(record.issued_at()))
            {
                return Err(invalid());
            }
        }
        Ok(())
    }

    fn receipt(&self, plan: &Prepared) -> Value {
        json!({"plan_id":plan.plan_id,"candidate_feed_id":plan.candidate_feed_id,
            "source_hash":self.source_hash,"bodies_hash":self.bodies_hash,"records_hash":self.records_hash,
            "record_count":self.records.as_array().map(Vec::len),
            "membership_head":{"seq":self.membership_seq,"hash":self.membership_hash}})
    }
}

/// The caller holds the fence and root. Bound all historical versions before loading a payload.
pub(super) async fn check_size(
    db: &mut PgConnection,
    origin: &str,
    genesis: &str,
    records: Option<&Value>,
    cut: Option<&Value>,
) -> Result<(), sqlx::Error> {
    let fits: bool = sqlx::query_scalar(
        "SELECT COALESCE(sum(jsonb_array_length(c.records)),0) + COALESCE(jsonb_array_length($3),0) <= $5
         AND COALESCE(sum(octet_length(c.records::text) + COALESCE(octet_length(c.signing_cut::text),0)),0)
             + COALESCE(octet_length($3::jsonb::text),0) + COALESCE(octet_length($4::jsonb::text),0) <= $6
         FROM station_delegated_service_components c JOIN station_delegated_recovery_plans p USING(plan_id)
         WHERE p.origin=$1 AND p.genesis_hash=$2",
    ).bind(origin).bind(genesis).bind(records).bind(cut).bind(MAX_RECORDS as i64).bind(MAX_STATE as i64)
    .fetch_one(db).await?;
    if !fits {
        return Err(invalid());
    }
    Ok(())
}

pub(super) async fn visit(
    db: &mut PgConnection,
    plan: &Prepared,
    origin: &str,
    heads: &BTreeMap<u64, Membership>,
    mut observe: impl FnMut(ControlRecord) -> Result<(), sqlx::Error>,
) -> Result<Vec<Value>, sqlx::Error> {
    let rows: Vec<Component> = sqlx::query_as(
        "SELECT source_hash,bodies_hash,membership_seq,membership_hash,records_hash,records,signing_cut
         FROM station_delegated_service_components WHERE plan_id=$1 ORDER BY source_hash",
    )
    .bind(&plan.plan_id)
    .fetch_all(db)
    .await?;
    let mut receipts = Vec::with_capacity(rows.len());
    for row in rows {
        let accepted = heads
            .get(&(row.membership_seq as u64))
            .ok_or_else(invalid)?;
        for record in row.verify(plan, origin, accepted)? {
            observe(record)?;
        }
        receipts.push(row.receipt(plan));
    }
    Ok(receipts)
}

pub(super) async fn at_current_head(
    db: &mut PgConnection,
    plan: &Prepared,
    log: &Membership,
) -> Result<Vec<Component>, sqlx::Error> {
    sqlx::query_as(
        "SELECT source_hash,bodies_hash,membership_seq,membership_hash,records_hash,records,signing_cut
         FROM station_delegated_service_components WHERE plan_id=$1 AND membership_seq=$2
         AND membership_hash=$3 AND signing_cut IS NOT NULL ORDER BY source_hash",
    ).bind(&plan.plan_id).bind(log.head().seq as i64).bind(log.head().hash.to_hex()).fetch_all(db).await
}

/// Internal to the recovery publisher. Retaining signatures never authorizes signing or opens a feed.
pub(crate) async fn retain(
    tx: &mut Transaction<'_, Postgres>,
    binding: &Binding,
    genesis: &str,
    reviewed: &Value,
    records: &[ControlRecord],
) -> Result<Value, sqlx::Error> {
    let (plan, log, mut current) = checkpoint(tx, binding, genesis, false).await?;
    let plan_id = &plan.plan_id;
    let draft = &reviewed["service_drafts"];
    let source = draft["source_hash"].as_str().ok_or_else(invalid)?;
    let bodies_hash = draft["bodies_hash"].as_str().ok_or_else(invalid)?;
    if reviewed["plan_id"] != *plan_id
        || reviewed["candidate_feed_id"] != plan.candidate_feed_id
        || super::service_drafts::review_source(reviewed)? != source
        || records.is_empty()
        || records.len() > MAX_RECORDS
    {
        return Err(invalid());
    }
    let signed = Value::Array(records.iter().map(|r| r.object().to_json()).collect());
    let previous: Option<Component> = sqlx::query_as(
        "SELECT source_hash,bodies_hash,membership_seq,membership_hash,records_hash,records,signing_cut
         FROM station_delegated_service_components WHERE plan_id=$1 AND source_hash=$2",
    )
    .bind(plan_id)
    .bind(source)
    .fetch_optional(&mut **tx)
    .await?;
    if let Some(row) = previous {
        if row.bodies_hash != bodies_hash || row.records != signed {
            return Err(invalid());
        }
        let initial = Membership::from_stored(
            log.account_id(),
            &log.genesis_hash(),
            &plan.retained["membership"],
        )
        .map_err(|_| invalid())?;
        let heads = memberships::history(tx, &plan, initial).await?;
        let accepted = heads
            .get(&(row.membership_seq as u64))
            .ok_or_else(invalid)?;
        row.verify(&plan, &binding.origin, accepted)?;
        return Ok(row.receipt(&plan));
    }
    let saved: (String, Value) = sqlx::query_as(
        "SELECT bodies_hash,bodies FROM station_delegated_service_drafts WHERE plan_id=$1 AND source_hash=$2 FOR SHARE",
    ).bind(plan_id).bind(source).fetch_one(&mut **tx).await?;
    if saved.0 != bodies_hash || source_hash(&saved.1)? != bodies_hash {
        return Err(invalid());
    }
    let known = super::review_evidence(tx, &plan, &log, binding, &mut current, false).await?;
    if current["reconstruction_hash"] != reviewed["reconstruction_hash"]
        || !super::covers_retained_membership(&current)
        || known.signed.len() + records.len() > MAX_RECORDS
        || records.iter().any(|record| {
            known.signed.contains_key(record.record_id())
                || super::signatures::unsigned_id(&current, record.record_id())
        })
    {
        return Err(invalid());
    }

    let head = log.head();
    let portal_hash = source_hash(&json!({
        "plan_id":plan_id,"reconstruction_hash":current["reconstruction_hash"],
        "source":reviewed["portal_service_evidence"],
    }))?;
    if reviewed["portal_service_evidence_hash"] != portal_hash
        || reviewed["service_clock_evidence_hash"]
            != source_hash(&reviewed["service_clock_evidence"])?
        || reviewed["service_clock_evidence"]["reconstruction_hash"]
            != current["reconstruction_hash"]
    {
        return Err(invalid());
    }
    let component = Component {
        source_hash: source.into(),
        bodies_hash: bodies_hash.into(),
        membership_seq: head.seq as i64,
        membership_hash: head.hash.to_hex(),
        records_hash: source_hash(&signed)?,
        records: signed,
        signing_cut: Some(
            json!({"reconstruction":super::reconstruction_inputs(&current),
            "service_clock_evidence":reviewed["service_clock_evidence"],
            "portal_service_evidence":reviewed["portal_service_evidence"]}),
        ),
    };
    component.verify(&plan, &binding.origin, &log)?;
    check_size(
        tx,
        &binding.origin,
        genesis,
        Some(&component.records),
        component.signing_cut.as_ref(),
    )
    .await?;
    sqlx::query(
        "INSERT INTO station_delegated_service_components
        (plan_id,source_hash,bodies_hash,membership_seq,membership_hash,records_hash,records,signing_cut)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8)",
    )
    .bind(plan_id)
    .bind(source)
    .bind(bodies_hash)
    .bind(component.membership_seq)
    .bind(&component.membership_hash)
    .bind(&component.records_hash)
    .bind(&component.records)
    .bind(&component.signing_cut)
    .execute(&mut **tx)
    .await?;
    Ok(component.receipt(&plan))
}
