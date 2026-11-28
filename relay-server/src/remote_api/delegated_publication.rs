//! Storage for the final verifier. No HTTP or operator input authorizes this transaction.
use super::{invalid, source_hash, Binding, MAX_STATE};
use crate::integration_feed::FeedBinding;
use crate::service_keys::ServiceKeyVault;
use crate::service_signing_ceilings::SigningCeilings;
use serde_json::Value;
use sqlx::{PgConnection, PgPool, Postgres, Transaction};
use std::collections::BTreeMap;

/// The verifier must establish the final participant, policy and independent
/// clock evidence under the publication locks before handing a cut to storage.
pub(super) struct AccountCut {
    pub plan_id: String,
    pub cut_hash: String,
    pub feed_hash: String,
    pub membership_head: Value,
}

struct Publication<'a> {
    tx: Transaction<'a, Postgres>,
    binding: Binding,
    primary_store: String,
}

async fn lock_generation(
    db: &mut PgConnection,
    binding: &Binding,
) -> Result<(bool, String), sqlx::Error> {
    // The origin and generation can exist in another restored database. Its
    // row lock cannot establish that a publisher on this primary finished.
    sqlx::query_as(
        "SELECT ready, jsonb_build_array(
        (SELECT system_identifier::text FROM pg_catalog.pg_control_system()),
        (SELECT oid::text FROM pg_catalog.pg_database WHERE datname=current_database()),
        tableoid::text)::text FROM station_delegated_recovery
        WHERE origin=$1 AND generation=$2 FOR UPDATE NOWAIT",
    )
    .bind(&binding.origin)
    .bind(binding.generation)
    .fetch_one(db)
    .await
}

/// An attempt visible before obtaining the primary row lock belongs to a
/// finished or rolled-back publisher once we hold that row. A new publisher
/// always creates a fresh attempt. The conditional clear cannot release it.
pub(crate) async fn reconcile_signing_hold(
    pool: &PgPool,
    binding: &Binding,
    signing: &SigningCeilings,
) -> Result<(), sqlx::Error> {
    let Some(hold) = signing.publication_hold().await? else {
        return Ok(());
    };
    if hold.origin != binding.origin || hold.generation > binding.generation {
        return Err(invalid());
    }
    let mut tx = pool.begin().await?;
    let (_, primary_store) = lock_generation(&mut tx, binding).await?;
    if hold.primary_store != primary_store {
        return Err(invalid());
    }
    signing.clear_publication_hold(&hold).await?;
    tx.commit().await
}

/// Run final verification and install every feed while the independent
/// signing inventory is durably held, including if either connection dies.
pub(super) async fn publish_after_verification(
    pool: &PgPool,
    binding: &Binding,
    portal: &FeedBinding,
    signing: &SigningCeilings,
    vault: &ServiceKeyVault,
    verify: impl AsyncFnOnce(&mut PgConnection) -> Result<BTreeMap<String, AccountCut>, sqlx::Error>,
) -> Result<(), sqlx::Error> {
    if portal.station_origin != binding.origin || portal.validate().is_err() {
        return Err(invalid());
    }
    reconcile_signing_hold(pool, binding, signing).await?;
    let result = async {
        let mut publication = Publication::begin(pool, binding).await?;
        signing
            .hold_for_publication(
                &binding.origin,
                binding.generation,
                &publication.primary_store,
            )
            .await?;
        let cuts = verify(&mut publication.tx).await?;
        publication.commit(cuts, portal, signing, vault).await
    }
    .await;
    // An uncertain primary commit can still be running. Reacquiring its
    // row lock distinguishes that case from a safe cleanup on either outcome.
    reconcile_signing_hold(pool, binding, signing).await?;
    result
}

impl Publication<'_> {
    async fn begin(pool: &PgPool, binding: &Binding) -> Result<Self, sqlx::Error> {
        let mut tx = pool.begin().await?;
        sqlx::query("SET LOCAL statement_timeout = '5s'")
            .execute(&mut *tx)
            .await?;
        let (ready, primary_store) = lock_generation(&mut tx, binding).await?;
        if ready {
            return Err(invalid());
        }
        // A root created between enumeration and reopening would have missed
        // recovery. This lock also keeps non-delegated membership writes out.
        sqlx::query("LOCK TABLE remote_recovery_roots IN SHARE ROW EXCLUSIVE MODE NOWAIT")
            .execute(&mut *tx)
            .await?;
        sqlx::query("LOCK TABLE station_integration_provisioning, station_service_keys, station_integration_policy,
            station_native_binding_transitions, station_binding_release_requests, account_identities IN SHARE MODE NOWAIT")
            .execute(&mut *tx).await?;
        Ok(Self {
            tx,
            binding: binding.clone(),
            primary_store,
        })
    }

    /// Consuming the transaction rolls back every root and receipt on any
    /// error, including an error from a deferred constraint at commit.
    async fn commit(
        mut self,
        cuts: BTreeMap<String, AccountCut>,
        portal: &FeedBinding,
        signing: &SigningCeilings,
        vault: &ServiceKeyVault,
    ) -> Result<(), sqlx::Error> {
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM remote_recovery_roots")
            .fetch_one(&mut *self.tx)
            .await?;
        if cuts.is_empty() || usize::try_from(count).ok() != Some(cuts.len()) {
            return Err(invalid());
        }
        let limit = count.checked_add(1).ok_or_else(invalid)?;
        let service_roots =
            crate::service_keys::list_recovery_roots(&mut self.tx, portal, None, limit).await?;
        if service_roots
            .iter()
            .any(|genesis| !cuts.contains_key(genesis))
        {
            return Err(invalid());
        }
        let registrations = signing.root_registrations(None, limit).await?;
        if registrations
            .iter()
            .any(|(genesis, _, _)| !cuts.contains_key(genesis))
        {
            return Err(invalid());
        }
        if crate::account_identity::built_in_station(&self.binding.origin) {
            let bound =
                super::super::binding_inventory::list(&mut self.tx, portal, None, limit as usize)
                    .await?;
            if bound.iter().any(|genesis| !cuts.contains_key(genesis)) {
                return Err(invalid());
            }
        }
        // Repeat the same reconstruction used by operator preparation. Read
        // every list before replacing any feed, including lists used to
        // attribute a Portal integration belonging to the same owner.
        for (genesis, cut) in &cuts {
            let staged: bool = sqlx::query_scalar("SELECT EXISTS(
                SELECT 1 FROM station_delegated_replacement_feeds WHERE plan_id=$1 AND cut_hash=$2 AND feed_hash=$3)")
                .bind(&cut.plan_id).bind(&cut.cut_hash).bind(&cut.feed_hash)
                .fetch_one(&mut *self.tx).await?;
            if !staged {
                return Err(invalid());
            }
            let review = super::prepare_in_transaction(
                &mut self.tx,
                &self.binding,
                genesis,
                Some(signing),
                Some(portal),
                Some(vault),
            )
            .await?;
            let feed = &review["replacement_feed"];
            let authors = &review["known_authors"];
            if !authors["pending_final_reports"]
                .as_array()
                .is_some_and(Vec::is_empty)
                || !authors["journal_gaps"]
                    .as_array()
                    .is_some_and(Vec::is_empty)
            {
                return Err(invalid());
            }
            if review["plan_id"] != cut.plan_id
                || review["membership_head"] != cut.membership_head
                || feed["status"] != "staged"
                || feed["cut_hash"] != cut.cut_hash
                || feed["feed_hash"] != cut.feed_hash
            {
                return Err(invalid());
            }
        }
        for (genesis, cut) in &cuts {
            self.install(genesis, cut).await?;
        }
        let updated = sqlx::query(
            "UPDATE station_delegated_recovery SET ready=true,reason='published'
            WHERE origin=$1 AND generation=$2 AND NOT ready",
        )
        .bind(&self.binding.origin)
        .bind(self.binding.generation)
        .execute(&mut *self.tx)
        .await?;
        if updated.rows_affected() != 1 {
            return Err(invalid());
        }
        self.tx.commit().await
    }

    async fn install(&mut self, genesis: &str, cut: &AccountCut) -> Result<(), sqlx::Error> {
        // The root may have unrelated changes since staging. Replace only
        // this origin's feed and recheck the size of the actual resulting row.
        let feed: Value = sqlx::query_scalar("SELECT f.feed FROM station_delegated_replacement_feeds f
             JOIN station_delegated_recovery_plans p USING(plan_id) JOIN remote_recovery_roots r USING(genesis_hash)
             WHERE p.origin=$1 AND p.generation=$2 AND p.genesis_hash=$3 AND p.plan_id=$4
               AND f.cut_hash=$5 AND f.feed_hash=$6 AND f.feed->>'feed_id'=p.candidate_feed_id
               AND NOT p.abandoned AND p.published_cut_hash IS NULL
               AND p.retained->>'account_subject'=r.account_subject AND p.retained->>'account_id'=r.state->>'account'
               AND r.state->'membership'->'head'=$7 AND
                 COALESCE(r.state->'delegated'->$1,'null'::jsonb)=p.retained->'feed'
             FOR UPDATE OF f,p")
            .bind(&self.binding.origin).bind(self.binding.generation).bind(genesis).bind(&cut.plan_id)
            .bind(&cut.cut_hash).bind(&cut.feed_hash).bind(&cut.membership_head)
            .fetch_one(&mut *self.tx).await?;
        if source_hash(&feed)? != cut.feed_hash {
            return Err(invalid());
        }
        let installed = sqlx::query("WITH replaced AS (
                 SELECT genesis_hash,state || jsonb_build_object('delegated',COALESCE(state->'delegated','{}'::jsonb)
                      || jsonb_build_object($2::text,$3::jsonb)) AS state FROM remote_recovery_roots WHERE genesis_hash=$1
             ) UPDATE remote_recovery_roots r SET state=n.state,updated_at=now() FROM replaced n
             WHERE n.genesis_hash=r.genesis_hash AND octet_length(n.state::text)<=$4")
            .bind(genesis).bind(&self.binding.origin).bind(&feed).bind(MAX_STATE as i64)
            .execute(&mut *self.tx).await?;
        if installed.rows_affected() != 1 {
            return Err(invalid());
        }
        let receipt = sqlx::query("UPDATE station_delegated_recovery_plans SET published_cut_hash=$2,published_feed_hash=$3
            WHERE plan_id=$1 AND NOT abandoned AND published_cut_hash IS NULL")
            .bind(&cut.plan_id).bind(&cut.cut_hash).bind(&cut.feed_hash).execute(&mut *self.tx).await?;
        if receipt.rows_affected() != 1 {
            return Err(invalid());
        }
        Ok(())
    }
}

#[cfg(all(test, feature = "delegated-host-work"))]
mod tests {
    use super::*;
    use crate::{
        integration_checkpoint::PortalCheckpoint,
        remote_api::{
            push_ingress::tests::Fixture,
            recovery::delegated_recovery::{inspect, plan},
        },
        station_integrations::tests::{fixture_with_ceiling_cluster, PRINCIPAL},
        test_database::TestDatabase,
    };
    use atem_client::{
        member_report::{
            sign_signer_report, signer_report_body, JournalView, SignerReportChallenge,
        },
        membership::Head,
        KeyId,
    };
    use axum::http::StatusCode;
    use serde_json::json;

    /// A storage fixture supplies the result of final verification. Both feed
    /// images themselves come from the actual fenced preparation workflow.
    fn cuts(reviews: &[Value]) -> BTreeMap<String, AccountCut> {
        reviews
            .iter()
            .map(|r| {
                let image = &r["replacement_feed"];
                assert_eq!(image["status"], "staged");
                (
                    r["genesis_hash"].as_str().unwrap().into(),
                    AccountCut {
                        plan_id: r["plan_id"].as_str().unwrap().into(),
                        cut_hash: image["cut_hash"].as_str().unwrap().into(),
                        feed_hash: image["feed_hash"].as_str().unwrap().into(),
                        membership_head: r["membership_head"].clone(),
                    },
                )
            })
            .collect()
    }

    async fn report_own_journal(db: &PgPool, fence: &Binding, review: &Value, fixture: &Fixture) {
        let genesis = fixture.log.genesis_hash().to_hex();
        let signer = "member:phone";
        let slot = "native";
        let request = plan::signer_challenges::Request::parse(&json!({
            "signer":signer,"slot":slot,"expected":fixture.log.head().to_json(),
            "recovery":{"generation":fence.generation.to_string(),"plan_id":review["plan_id"],
                "candidate_feed_id":review["candidate_feed_id"],"source_hash":review["source_hash"],
                "evidence_hash":review["evidence_hash"]}
        }))
        .unwrap();
        let challenge = plan::signer_challenges::mint(db, fence, &genesis, PRINCIPAL, request)
            .await
            .ok()
            .expect("mint journal challenge");
        let challenge = SignerReportChallenge::parse(challenge.to_string().as_bytes()).unwrap();
        let journal = JournalView {
            id: [1; 16],
            since: 1,
            revision: 1,
            records: vec![],
            drafts: vec![],
        };
        let body = signer_report_body(
            &fixture.log,
            &challenge,
            signer,
            slot,
            &fence.origin,
            &journal,
            challenge.issued_at(),
        )
        .unwrap();
        let signed = sign_signer_report(&fixture.keys, &KeyId::new("manager"), &body).unwrap();
        plan::signer_reports::submit(
            db,
            fence,
            &genesis,
            PRINCIPAL,
            &json!({"report":signed.to_json(),"records":[]}),
        )
        .await
        .ok()
        .expect("accept signed journal report");
    }

    #[tokio::test]
    #[ignore = "requires two independent local PostgreSQL clusters"]
    async fn postgres_delegated_signing_hold_survives_publisher_loss_and_reconciles_on_a_replica() {
        let db = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 3).await;
        let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 3).await;
        sqlx::raw_sql(include_str!("../../signing-store/schema.sql"))
            .execute(&external.pool)
            .await
            .unwrap();
        let signer =
            || SigningCeilings::connect(&db.pool, (*external.pool.connect_options()).clone());
        let first = signer().await.unwrap();
        let second = signer().await.unwrap();
        let fence = Binding::new("https://station-dev.agora.build", 2).unwrap();
        fence.initialize(&db.pool, true).await.unwrap();
        first
            .register_new_key("account", "genesis", "service", "key")
            .await
            .unwrap();
        assert!(first
            .hold_for_publication(&fence.origin, fence.generation, "unused")
            .await
            .is_err());
        sqlx::raw_sql(include_str!("../../signing-store/publication-guard.sql"))
            .execute(&external.pool)
            .await
            .unwrap();

        let mut writing = external.pool.begin().await.unwrap();
        sqlx::query("UPDATE station_service_signing_ceilings SET highest_ms=1")
            .execute(&mut *writing)
            .await
            .unwrap();
        let publisher = db.reconnect(1).await;
        let publication = Publication::begin(&publisher, &fence).await.unwrap();
        {
            let freeze = first.hold_for_publication(
                &fence.origin,
                fence.generation,
                &publication.primary_store,
            );
            tokio::pin!(freeze);
            assert!(
                tokio::time::timeout(std::time::Duration::from_millis(100), &mut freeze)
                    .await
                    .is_err()
            );
            writing.commit().await.unwrap();
            freeze.await.unwrap();
        }
        drop(first);
        let previous = second.publication_hold().await.unwrap().unwrap();
        let reserve = || second.reserve("account", "genesis", "service", "key", 1, 2..=2);
        assert!(reserve().await.is_err());
        assert!(reconcile_signing_hold(&db.pool, &fence, &second)
            .await
            .is_err());
        drop(publication);
        publisher.close().await;
        assert!(reserve().await.is_err());
        let unrelated = TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 1).await;
        fence.initialize(&unrelated.pool, true).await.unwrap();
        assert!(reconcile_signing_hold(&unrelated.pool, &fence, &second)
            .await
            .is_err());
        unrelated.cleanup().await;
        let stale = Binding::new(&fence.origin, 1).unwrap();
        assert!(reconcile_signing_hold(&db.pool, &stale, &second)
            .await
            .is_err());
        let other = Binding::new("https://elsewhere.example", 2).unwrap();
        assert!(reconcile_signing_hold(&db.pool, &other, &second)
            .await
            .is_err());
        reconcile_signing_hold(&db.pool, &fence, &second)
            .await
            .unwrap();
        assert!(second.publication_hold().await.unwrap().is_none());
        let next = Publication::begin(&db.pool, &fence).await.unwrap();
        second
            .hold_for_publication(&fence.origin, fence.generation, &next.primary_store)
            .await
            .unwrap();
        second.clear_publication_hold(&previous).await.unwrap();
        assert!(reserve().await.is_err());
        next.tx.rollback().await.unwrap();
        reconcile_signing_hold(&db.pool, &fence, &second)
            .await
            .unwrap();
        reserve().await.unwrap();
        assert!(
            !inspect(&db.pool, &fence.origin)
                .await
                .unwrap()
                .unwrap()
                .ready
        );
        db.cleanup().await;
        external.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires two independent local PostgreSQL clusters"]
    async fn postgres_delegated_publication_commits_every_feed_receipt_and_fence_together() {
        let external = TestDatabase::new("SIGNING_TEST_DATABASE_URL", 2).await;
        sqlx::raw_sql(include_str!("../../signing-store/schema.sql"))
            .execute(&external.pool)
            .await
            .unwrap();
        sqlx::raw_sql(include_str!("../../signing-store/publication-guard.sql"))
            .execute(&external.pool)
            .await
            .unwrap();
        let (db, runtime, first) =
            fixture_with_ceiling_cluster("https://auth.example", Some(&external.pool)).await;
        let second = Fixture::new(first.created - 5000);
        let second_genesis = second.log.genesis_hash().to_hex();
        let recovery = &runtime.app.recovery;
        for entry in second.log.entries() {
            assert_eq!(
                recovery
                    .append_test_entry(
                        &second_genesis,
                        PRINCIPAL,
                        entry.clone(),
                        Head {
                            seq: entry.seq - 1,
                            hash: entry.prev_hash
                        }
                    )
                    .await,
                StatusCode::OK
            );
        }
        let fence = Binding::new(&runtime.binding.station_origin, 2).unwrap();
        fence.initialize(&db.pool, true).await.unwrap();
        let previous = runtime.policies.load(&runtime.binding).await.unwrap();
        let source = json!({"changes":[],"cursor":previous.cursor,
            "checkpoint":{"at":"2026-11-27T10:00:00.000Z","integrations":[]}});
        let policy =
            PortalCheckpoint::parse(&serde_json::to_vec(&source).unwrap(), &runtime.binding)
                .unwrap();
        let next = previous
            .apply_checkpoint(policy, previous.received_at)
            .unwrap();
        runtime
            .policies
            .commit_for_recovery(&previous, &next, Some(&fence))
            .await
            .unwrap();
        let mut reviews = Vec::new();
        for genesis in [first.log.genesis_hash().to_hex(), second_genesis] {
            reviews.push(
                plan::prepare_with_sources(
                    &db.pool,
                    &fence,
                    &genesis,
                    recovery.signing_ceilings.get(),
                    Some(&runtime.binding),
                    Some(&runtime.vault),
                )
                .await
                .unwrap(),
            );
        }
        let signing = recovery.signing_ceilings.get().unwrap();
        let unconfirmed = cuts(&reviews);
        assert!(
            publish_after_verification(
                &db.pool,
                &fence,
                &runtime.binding,
                signing,
                &runtime.vault,
                async move |_| Ok(unconfirmed)
            )
            .await
            .is_err(),
            "published before the managers reported"
        );
        for (review, fixture) in reviews.iter_mut().zip([&first, &second]) {
            assert_eq!(
                review["known_authors"]["pending_final_reports"],
                json!([{
                    "signer":"member:phone", "journal_id":null, "reason":"no_report"
                }])
            );
            report_own_journal(&db.pool, &fence, review, fixture).await;
            *review = plan::prepare_with_sources(
                &db.pool,
                &fence,
                &fixture.log.genesis_hash().to_hex(),
                Some(signing),
                Some(&runtime.binding),
                Some(&runtime.vault),
            )
            .await
            .unwrap();
            assert_eq!(review["known_authors"]["pending_final_reports"], json!([]));
        }
        // An authenticated Portal checkpoint can advance after staging without
        // changing the membership head, the old feed or the signing inventory.
        let before = runtime.policies.load(&runtime.binding).await.unwrap();
        let updated = json!({"changes":[],"cursor":before.cursor,
            "checkpoint":{"at":"2026-11-27T10:01:00.000Z","integrations":[]}});
        let newer =
            PortalCheckpoint::parse(&serde_json::to_vec(&updated).unwrap(), &runtime.binding)
                .unwrap();
        let after = before.apply_checkpoint(newer, before.received_at).unwrap();
        runtime
            .policies
            .commit_for_recovery(&before, &after, Some(&fence))
            .await
            .unwrap();
        let old_cuts = cuts(&reviews);
        assert!(
            publish_after_verification(
                &db.pool,
                &fence,
                &runtime.binding,
                signing,
                &runtime.vault,
                async move |_| Ok(old_cuts)
            )
            .await
            .is_err(),
            "published a superseded Portal checkpoint"
        );
        for review in &mut reviews {
            *review = plan::prepare_with_sources(
                &db.pool,
                &fence,
                review["genesis_hash"].as_str().unwrap(),
                Some(signing),
                Some(&runtime.binding),
                Some(&runtime.vault),
            )
            .await
            .unwrap();
        }
        let replica = db.reconnect(2).await;
        let read_roots =
            "SELECT genesis_hash,state FROM remote_recovery_roots ORDER BY genesis_hash";
        let initial: Vec<(String, Value)> = sqlx::query_as(read_roots)
            .fetch_all(&replica)
            .await
            .unwrap();
        let receipt = |i: usize| {
            plan::outcome::for_owner(
                &replica,
                &fence,
                reviews[i]["genesis_hash"].as_str().unwrap(),
                reviews[i]["plan_id"].as_str().unwrap(),
                PRINCIPAL,
            )
        };

        let subset = cuts(&reviews[..1]);
        assert!(publish_after_verification(
            &db.pool,
            &fence,
            &runtime.binding,
            signing,
            &runtime.vault,
            async move |_| Ok(subset)
        )
        .await
        .is_err());
        // A partial primary restore can lose a whole list and retain only
        // its registration on the independent signing cluster.
        let missing = "f".repeat(64);
        signing
            .register_new_key(
                first.log.account_id(),
                &missing,
                "svc-missing",
                &"e".repeat(64),
            )
            .await
            .unwrap();
        let all_primary = cuts(&reviews);
        assert!(publish_after_verification(
            &db.pool,
            &fence,
            &runtime.binding,
            signing,
            &runtime.vault,
            async move |_| Ok(all_primary)
        )
        .await
        .is_err());
        sqlx::query("DELETE FROM station_service_signing_ceilings WHERE genesis_hash=$1")
            .bind(&missing)
            .execute(&external.pool)
            .await
            .unwrap();
        let mut stale = cuts(&reviews);
        stale.last_entry().unwrap().get_mut().cut_hash = "0".repeat(64);
        assert!(publish_after_verification(
            &db.pool,
            &fence,
            &runtime.binding,
            signing,
            &runtime.vault,
            async move |_| Ok(stale)
        )
        .await
        .is_err());
        assert_eq!(
            sqlx::query_as::<_, (String, Value)>(read_roots)
                .fetch_all(&replica)
                .await
                .unwrap(),
            initial
        );
        assert_eq!(receipt(0).await.unwrap()["outcome"], "pending");

        sqlx::raw_sql("CREATE FUNCTION fail_publication() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'commit failed'; END; $$ LANGUAGE plpgsql;
            CREATE CONSTRAINT TRIGGER fail_publication AFTER UPDATE ON station_delegated_recovery
            DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_publication()")
            .execute(&db.pool).await.unwrap();
        let checked = cuts(&reviews);
        assert!(publish_after_verification(
            &db.pool,
            &fence,
            &runtime.binding,
            signing,
            &runtime.vault,
            async move |_| Ok(checked)
        )
        .await
        .is_err());
        assert_eq!(
            sqlx::query_as::<_, (String, Value)>(read_roots)
                .fetch_all(&replica)
                .await
                .unwrap(),
            initial
        );
        assert!(
            !inspect(&replica, &fence.origin)
                .await
                .unwrap()
                .unwrap()
                .ready
        );
        for i in 0..2 {
            assert_eq!(receipt(i).await.unwrap()["outcome"], "pending");
        }
        sqlx::query("DROP TRIGGER fail_publication ON station_delegated_recovery")
            .execute(&db.pool)
            .await
            .unwrap();

        let checked = cuts(&reviews);
        publish_after_verification(
            &db.pool,
            &fence,
            &runtime.binding,
            signing,
            &runtime.vault,
            async |_| {
                assert!(
                    signing
                        .register_new_key(
                            first.log.account_id(),
                            &missing,
                            "late-service",
                            &"e".repeat(64)
                        )
                        .await
                        .is_err(),
                    "registration changed the signing inventory during publication"
                );
                for i in 0..2 {
                    assert_eq!(receipt(i).await.unwrap()["outcome"], "pending");
                }
                // A new root cannot appear after the verifier enumerates this generation.
                let mut writer = replica.begin().await?;
                assert!(sqlx::query(
                    "LOCK TABLE remote_recovery_roots IN ROW EXCLUSIVE MODE NOWAIT"
                )
                .execute(&mut *writer)
                .await
                .is_err());
                writer.rollback().await?;
                Ok(checked)
            },
        )
        .await
        .unwrap();
        let live: Vec<(String, Value)> = sqlx::query_as(read_roots)
            .fetch_all(&replica)
            .await
            .unwrap();
        for ((genesis, mut before), (_, mut after)) in initial.into_iter().zip(live) {
            let i = reviews
                .iter()
                .position(|r| r["genesis_hash"] == genesis)
                .unwrap();
            let result = receipt(i).await.unwrap();
            assert_eq!(result["outcome"], "published");
            assert_eq!(
                result["candidate_feed_id"],
                after["delegated"][&fence.origin]["feed_id"]
            );
            assert_eq!(result["source_hash"], reviews[i]["source_hash"]);
            assert!(plan::outcome::for_owner(
                &replica,
                &fence,
                &genesis,
                result["plan_id"].as_str().unwrap(),
                "another-owner"
            )
            .await
            .is_err());
            assert!(plan::outcome::abandon(
                &replica,
                &fence,
                &genesis,
                result["plan_id"].as_str().unwrap()
            )
            .await
            .is_err());
            before.as_object_mut().unwrap().remove("delegated");
            after.as_object_mut().unwrap().remove("delegated");
            assert_eq!(before, after);
        }
        assert!(
            inspect(&replica, &fence.origin)
                .await
                .unwrap()
                .unwrap()
                .ready
        );
        let later = Binding::new(&fence.origin, 3).unwrap();
        later.initialize(&db.pool, true).await.unwrap();
        let genesis = reviews[0]["genesis_hash"].as_str().unwrap();
        let id = reviews[0]["plan_id"].as_str().unwrap();
        assert_eq!(
            plan::outcome::for_owner(&replica, &later, genesis, id, PRINCIPAL)
                .await
                .unwrap()["outcome"],
            "published"
        );
        assert!(plan::outcome::abandon(&replica, &later, genesis, id)
            .await
            .is_err());
        replica.close().await;
        drop(runtime);
        db.cleanup().await;
        external.cleanup().await;
    }
}
