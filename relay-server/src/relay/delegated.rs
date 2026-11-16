use super::*;
use crate::remote_api::recovery::{delegated::Fault, HostBinding};
use atem_client::control::{CallRefused, RefusalCode, RefusedCall, ToStation};
use futures_util::StreamExt;

impl RelayHub {
    pub(crate) fn spawn_delegated_heads(&self) -> tokio::task::JoinHandle<()> {
        let hub = self.clone();
        tokio::spawn(async move {
            let Some(store) = hub.inner.recovery.get() else {
                return;
            };
            let mut changes = store.delegated_changes();
            let mut interval = tokio::time::interval(Duration::from_secs(30));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tokio::select! {
                    _ = interval.tick() => {},
                    _ = hub.inner.delegated_updates.notified() => {},
                    changed = changes.changed() => {
                        if changed.is_err() { return; }
                        let _ = hub.inner.bus.broadcast(BroadcastMessage::DelegatedChanged {
                            source_replica: hub.inner.replica_id.clone(),
                        }).await;
                    }
                }
                let bindings: Vec<_> = hub
                    .inner
                    .host_routes
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .values()
                    .cloned()
                    .collect();
                let mut work = futures_util::stream::iter(bindings.into_iter().map(|binding| {
                    let hub = &hub;
                    async move {
                        if !matches!(
                            tokio::time::timeout(
                                Duration::from_secs(30),
                                hub.delegated_heads(&binding)
                            )
                            .await,
                            Ok(true)
                        ) {
                            // Preserve the separately bounded verification completion path.
                            if !hub.keep_verification(&binding.connection.conn).await {
                                hub.local().close_with(
                                    &binding.connection.conn,
                                    CLOSE_TRY_AGAIN,
                                    "Station synchronization unavailable",
                                );
                            }
                        }
                    }
                }))
                .buffer_unordered(8);
                while work.next().await.is_some() {}
            }
        })
    }

    pub(super) async fn delegated_peer_current(&self, binding: &HostBinding) -> bool {
        if binding.proxy.is_some() {
            return self.local().contains(&binding.connection.conn)
                && self.proxy_current(&binding.connection.conn).await;
        }
        self.local().contains(&binding.connection.conn)
            && matches!(self.room(&binding.room).await, Ok(Some(room))
                if room.atems.get(&binding.atem_id) == Some(&binding.connection))
    }

    async fn queue_delegated(
        &self,
        binding: &HostBinding,
        response: Result<Option<serde_json::Value>, Fault>,
    ) -> bool {
        if !self.delegated_peer_current(binding).await {
            return false;
        }
        match response {
            Ok(Some(frame)) => self.local().send_delegated(binding, frame.to_string()),
            Ok(None) => true,
            Err(fault) => match fault.refusal() {
                Some(frame) => self.local().send_delegated(binding, frame.to_string()),
                None => false,
            },
        }
    }

    pub(super) async fn delegated_heads(&self, binding: &HostBinding) -> bool {
        let Some(store) = self.inner.recovery.get().filter(|s| s.delegated_enabled()) else {
            return true;
        };
        if !store.prepare_delegated(binding).await {
            return false;
        }
        store
            .with_delegated_response(binding, None, |response| {
                self.queue_delegated(binding, response)
            })
            .await
            == Some(true)
    }

    pub(super) async fn delegated_call(&self, connection: &str, text: &str) -> Result<bool, ()> {
        // Only classify here. The shared strict reader owns all wire validation.
        let selector: serde_json::Value = serde_json::from_str(text).unwrap_or_default();
        if selector["type"] != "relay"
            || !matches!(
                selector["op"].as_str(),
                Some("control_sync" | "membership_fetch" | "control_ack")
            )
        {
            return Ok(false);
        }
        let call = ToStation::decode(text.as_bytes()).map_err(|_| ())?;
        let call_kind = match &call {
            ToStation::ControlSync(_) => RefusedCall::ControlSync,
            ToStation::MembershipFetch(_) => RefusedCall::MembershipFetch,
            ToStation::ControlAck(_) => RefusedCall::ControlAck,
        };
        let store = self.inner.recovery.get().ok_or(())?;
        let binding = self.host_binding(connection);
        if !store.delegated_enabled() || binding.is_none() {
            let frame = CallRefused {
                call: call_kind,
                code: RefusalCode::Forbidden,
            }
            .to_json()
            .map_err(|_| ())?
            .to_string();
            if !self.send_local_checked(connection, frame, true).await {
                return Err(());
            }
            return Ok(true);
        }
        let binding = binding.unwrap();
        if !store.prepare_delegated(&binding).await {
            return Err(());
        }
        let sent = if let ToStation::ControlAck(ack) = call {
            let reply = store.acknowledge_delegated(&binding, ack).await;
            if reply.0 == axum::http::StatusCode::OK {
                true
            } else if reply.0 == axum::http::StatusCode::FORBIDDEN {
                self.send_local_checked(connection, reply.1 .0.to_string(), true)
                    .await
            } else {
                false
            }
        } else {
            store
                .with_delegated_response(&binding, Some(&call), |response| {
                    self.queue_delegated(&binding, response)
                })
                .await
                == Some(true)
        };
        if sent {
            Ok(true)
        } else {
            Err(())
        }
    }
}

#[cfg(all(test, feature = "delegated-host-work"))]
mod tests {
    use super::*;
    use crate::remote_api::{
        host_route_tests::proof, push_ingress::tests::Fixture, recovery::RecoveryStore,
    };
    use atem_client::{
        host_route::HostChallenge,
        membership::{sign_entry, Action},
        KeyId,
    };

    #[tokio::test]
    #[ignore = "requires isolated Postgres"]
    async fn postgres_delegated_queued_frames_are_discarded_after_a_recovery_fence() {
        const ORIGIN: &str = "https://station-dev.agora.build";
        let database = crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
        let store = RecoveryStore::postgres(database.pool.clone());
        store.configure_delegated(ORIGIN, 1).await.unwrap();
        let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
        f.publish(&store).await;
        let hub = RelayHub::new();
        hub.configure_recovery(store.clone());
        let mut outbox = hub.local().register("queued-before-recovery", "phone", SocketRole::Atem { atem_id: "host-a".into() });
        let challenge = HostChallenge::new("phone");
        let (binding, _) = store.admit_host(
            &proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string(),
            challenge.nonce, "phone", "host-a", hub.me("queued-before-recovery"),
        ).await.unwrap();
        hub.track_host_route(binding.clone());
        assert!(hub.publish_host_route(&binding, None).await.unwrap().is_ok());
        assert!(hub.delegated_heads(&binding).await);
        let first = outbox.frames.recv().await.unwrap();
        outbox.sent(&first);
        let mut written: Vec<Message> = Vec::new();
        assert!(super::super::write_socket_frame(&mut written, first, Some(&hub)).await);
        assert_eq!(written.len(), 1);
        assert!(hub.delegated_heads(&binding).await);
        let stale = outbox.frames.recv().await.unwrap();
        outbox.sent(&stale);
        let recovery = crate::remote_api::recovery::delegated_recovery::Binding::new(ORIGIN, 2).unwrap();
        assert!(!recovery.initialize(&database.pool, false).await.unwrap().ready);
        assert!(super::super::write_socket_frame(&mut written, stale, Some(&hub)).await);
        assert_eq!(written.len(), 1, "the actual sink receives no pre-fence control frame");
        assert!(!hub.delegated_heads(&binding).await);
        assert!(store.admit_host(
            &proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string(),
            challenge.nonce, "phone", "host-a", hub.me("after-recovery"),
        ).await.is_err());
        drop(hub);
        drop(store);
        database.cleanup().await;
    }

    #[tokio::test]
    async fn delegated_writer_rechecks_the_queued_association_and_preserves_completion_on_close() {
        let store = RecoveryStore::memory();
        store
            .configure_delegated("https://station-dev.agora.build", 1).await
            .unwrap();
        let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
        f.publish(&store).await;
        let challenge = HostChallenge::new("phone");
        let hub = RelayHub::new();
        hub.configure_recovery(store.clone());
        let mut outbox = hub.local().register(
            "queued",
            "phone",
            SocketRole::Atem {
                atem_id: "host-a".into(),
            },
        );
        let (binding, _) = store
            .admit_host(
                &proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string(),
                challenge.nonce,
                "phone",
                "host-a",
                hub.me("queued"),
            )
            .await
            .unwrap();
        hub.track_host_route(binding.clone());
        assert!(hub
            .publish_host_route(&binding, None)
            .await
            .unwrap()
            .is_ok());
        assert!(hub.delegated_heads(&binding).await);
        let current = outbox.frames.recv().await.unwrap();
        outbox.sent(&current);
        let mut written: Vec<Message> = Vec::new();
        assert!(super::super::write_socket_frame(&mut written, current, Some(&hub)).await);
        assert_eq!(written.len(), 1);
        assert!(hub.delegated_heads(&binding).await);
        let stale = outbox.frames.recv().await.unwrap();
        outbox.sent(&stale);
        let mut host = f.log.host("host-a").unwrap().clone();
        host.host_trust_gen += 1;
        let entry = sign_entry(
            &f.keys,
            &KeyId::new("manager"),
            f.log.draft("phone", f.created, &Action::AddHost { host }),
        )
        .unwrap();
        assert_eq!(
            store
                .append_test_entry(&binding.genesis, "alice", entry, f.log.head())
                .await,
            axum::http::StatusCode::OK
        );
        assert!(super::super::write_socket_frame(&mut written, stale, Some(&hub)).await);
        assert_eq!(
            written.len(),
            1,
            "queued data cannot cross the trust-generation change"
        );

        // The same filtering must run in the bounded flush. Discarding an old
        // control response cannot prevent a queued #80 completion from flushing.
        assert!(hub
            .local()
            .send_delegated(&binding, "obsolete heads".into()));
        assert!(hub
            .local()
            .send_required("queued", "deviceVerified completion".into()));
        hub.local()
            .close_with("queued", CLOSE_TRY_AGAIN, "verification completed");
        super::super::write_loop_checked(&mut written, outbox, "phone".into(), Some(hub)).await;
        assert_eq!(written.len(), 3);
        assert!(matches!(&written[1], Message::Text(text) if text == "deviceVerified completion"));
        assert!(
            matches!(&written[2], Message::Close(Some(close)) if close.code == CLOSE_TRY_AGAIN)
        );
    }
}
