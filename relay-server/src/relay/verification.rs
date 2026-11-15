//! A proved route may be rekeyed before its verification completion is delivered.
//! This bounded control-plane path never admits session or API traffic.
use super::*;
use crate::remote_api::recovery::{HostBinding, VerificationAuthority};
use atem_client::canonical::StrictValue;

const WINDOW: Duration = Duration::from_secs(180);
const MAX_VERIFICATION_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone)]
pub(super) struct VerificationWindow {
    id: Uuid,
    binding: HostBinding,
    owner: ConnRef,
    authority: VerificationAuthority,
    expires: Instant,
}

fn kind(text: &str) -> Option<String> {
    let value = StrictValue::parse(text.as_bytes(), MAX_VERIFICATION_BYTES).ok()?;
    let root = value.value().as_object()?;
    if root.len() != 2 || !root.get("data")?.is_object() {
        return None;
    }
    Some(root.get("type")?.as_str()?.into())
}

impl RelayHub {
    fn verification_window(&self, connection: &str) -> Option<VerificationWindow> {
        self.inner
            .verifications
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(connection)
            .cloned()
            .filter(|w| w.expires > Instant::now())
    }

    fn verification_current(&self, connection: &str, window: &VerificationWindow) -> bool {
        self.local().contains(connection)
            && self
                .verification_window(connection)
                .is_some_and(|w| w.id == window.id)
    }

    async fn verification_peers_current(&self, window: &VerificationWindow) -> bool {
        matches!(self.room(&window.binding.room).await, Ok(Some(room))
            if room.verified && room.owner.as_ref() == Some(&window.owner)
                && room.atems.get(&window.binding.atem_id) == Some(&window.binding.connection))
    }

    pub(super) async fn keep_verification(&self, connection: &str) -> bool {
        let Some(window) = self.verification_window(connection) else {
            return false;
        };
        let Some(store) = self.inner.recovery.get() else {
            return false;
        };
        store
            .with_verification(&window.binding, &window.authority, false, || async {
                self.verification_peers_current(&window).await
                    && self.verification_current(connection, &window)
            })
            .await
            .unwrap_or(false)
    }

    /// Called only after checking the host's current route proof.
    pub(super) async fn begin_verification(&self, connection: &str, text: &str) {
        let Ok(generation) = atem_client::ceremony::verify_commit_host_trust_gen(text.as_bytes())
        else {
            return;
        };
        let Some(binding) = self.host_binding(connection) else {
            return;
        };
        let Ok(value) = StrictValue::parse(text.as_bytes(), 64 * 1024) else {
            return;
        };
        if value.value()["data"]["device_id"] != binding.host {
            return;
        }
        let Some(store) = self.inner.recovery.get() else {
            return;
        };
        let Some(authority) = store.start_verification(&binding, generation).await else {
            return;
        };
        let Ok(Some(room)) = self.room(&binding.room).await else {
            return;
        };
        let Some(owner) = room.owner.filter(|_| room.verified) else {
            return;
        };
        if room.atems.get(&binding.atem_id) != Some(&binding.connection) {
            return;
        }
        let window = VerificationWindow {
            id: Uuid::new_v4(),
            binding,
            owner,
            authority,
            expires: Instant::now() + WINDOW,
        };
        {
            let mut windows = self
                .inner
                .verifications
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            if windows.contains_key(connection) {
                return;
            }
            windows.insert(connection.into(), window.clone());
        }
        let hub = self.clone();
        let connection = connection.to_string();
        tokio::spawn(async move {
            tokio::time::sleep_until(window.expires).await;
            let mut windows = hub
                .inner
                .verifications
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            if windows.get(&connection).is_some_and(|w| w.id == window.id) {
                windows.remove(&connection);
                hub.local().close_with(
                    &connection,
                    CLOSE_TRY_AGAIN,
                    "verification expired; reconnect",
                );
            }
        });
    }

    /// Consume aborts and keep all other stale ingress out of ordinary handlers.
    pub(super) async fn verification_ingress(
        &self,
        connection: &str,
        text: &str,
        stale: bool,
    ) -> bool {
        let Some(window) = self.verification_window(connection) else {
            return false;
        };
        let abort = matches!(kind(text).as_deref(), Some("verifyAbort"));
        if !stale && !abort {
            return false;
        }
        if !self.keep_verification(connection).await {
            return false;
        }
        if abort {
            self.deliver(
                &window.owner,
                atem_envelope(&window.binding.atem_id, connection, text),
            )
            .await;
            self.inner
                .verifications
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(connection);
            self.local().close_with(
                connection,
                CLOSE_TRY_AGAIN,
                "verification aborted; reconnect",
            );
        }
        // A reveal necessarily precedes publication. After the proof is stale,
        // only the final abort can go from the host to the owner.
        true
    }

    /// Use a distinct bus operation: generic Deliver must never gain a bypass.
    pub(super) async fn deliver_verification(
        &self,
        room: &str,
        target: &ConnRef,
        owner: &ConnRef,
        frame: String,
    ) {
        if target.replica == self.inner.replica_id {
            self.send_verification(room, &target.conn, owner, frame)
                .await;
        } else {
            let _ = self
                .inner
                .bus
                .send_inbox(
                    &target.replica,
                    InboxMessage::VerificationDeliver {
                        room: room.into(),
                        connection_id: target.conn.clone(),
                        owner: owner.clone(),
                        frame,
                    },
                )
                .await;
        }
    }

    pub(super) async fn send_verification(
        &self,
        room: &str,
        connection: &str,
        owner: &ConnRef,
        frame: String,
    ) {
        if !matches!(self.room(room).await, Ok(Some(room)) if room.owner.as_ref() == Some(owner)
            && room.atems.values().any(|target| target == &self.me(connection)))
        {
            return;
        }
        let Some(window) = self.verification_window(connection) else {
            self.send_local_checked(connection, frame, true).await;
            return;
        };
        if &window.owner != owner {
            return;
        }
        let Some(kind) = kind(&frame)
            .filter(|k| matches!(k.as_str(), "verifyKeys" | "deviceVerified" | "verifyAbort"))
        else {
            return;
        };
        let Some(store) = self.inner.recovery.get() else {
            return;
        };
        let admitted = store
            .with_verification(
                &window.binding,
                &window.authority,
                kind == "deviceVerified",
                || async {
                    if !self.verification_peers_current(&window).await
                        || !self.verification_current(connection, &window)
                    {
                        return false;
                    }
                    let terminal = kind != "verifyKeys";
                    if terminal {
                        self.inner
                            .verifications
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .remove(connection);
                    }
                    let sent = self.local().send_required(connection, frame);
                    if terminal {
                        // The writer flushes queued completion before its close frame.
                        self.local().close_with(
                            connection,
                            CLOSE_TRY_AGAIN,
                            "verification finished; reconnect",
                        );
                    }
                    sent
                },
            )
            .await;
        if admitted != Some(true) {
            self.local()
                .close_with(connection, CLOSE_TRY_AGAIN, "verification route changed");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote_api::{
        host_route_tests::proof, push_ingress::tests::Fixture, recovery::RecoveryStore,
    };

    #[tokio::test(start_paused = true)]
    async fn verification_expires_while_idle_and_repeated_commits_cannot_extend_it() {
        let f = Fixture::new(chrono::Utc::now().timestamp_millis() as u64);
        let store = RecoveryStore::memory();
        f.publish(&store).await;
        let hub = RelayHub::new();
        hub.configure_recovery(store.clone());
        let owner = hub.me("owner");
        hub.directory()
            .claim_owner(
                "phone",
                &owner,
                "127.0.0.1",
                chrono::Utc::now().timestamp(),
                PendingCaps::NONE,
            )
            .await
            .unwrap();
        hub.directory()
            .promote("phone", &owner, false)
            .await
            .unwrap();
        let connection = hub.me("host");
        hub.directory()
            .join_atem("phone", "host-a", &connection)
            .await
            .unwrap();
        let outbox = hub.local().register(
            "host",
            "phone",
            SocketRole::Atem {
                atem_id: "host-a".into(),
            },
        );
        let challenge = atem_client::host_route::HostChallenge::new("phone");
        let (binding, _) = store
            .admit_host(
                &proof(&f.keys, &f.host_key, &f.log, &challenge, "host-a").to_string(),
                challenge.nonce,
                "phone",
                "host-a",
                connection,
            )
            .await
            .unwrap();
        hub.track_host_route(binding);
        let commit = r#"{"type":"verifyCommit","data":{"device_id":"host-a","commitment":"opaque","host_trust_gen":2}}"#;
        hub.begin_verification("host", commit).await;
        let expires = hub.verification_window("host").unwrap().expires;
        tokio::time::advance(Duration::from_secs(170)).await;
        hub.begin_verification("host", commit).await;
        assert_eq!(hub.verification_window("host").unwrap().expires, expires);
        tokio::time::advance(Duration::from_secs(11)).await;
        tokio::task::yield_now().await;
        assert!(!hub.local().contains("host"));
        assert!(outbox
            .close
            .borrow()
            .as_ref()
            .is_some_and(|(code, _)| *code == CLOSE_TRY_AGAIN));
        assert!(hub.verification_window("host").is_none());
    }

    #[test]
    fn verification_classification_rejects_ambiguous_json() {
        for frame in [
            r#"{"type":"deviceVerified","type":"channel","data":{}}"#,
            r#"{"type":"deviceVerified","data":{},"data":null}"#,
            r#"{"type":"deviceVerified","data":{},"payload":{"type":"channel"}}"#,
            r#"{"type":"deviceVerified","data":null}"#,
        ] {
            assert!(kind(frame).is_none(), "{frame}");
        }
    }
}
