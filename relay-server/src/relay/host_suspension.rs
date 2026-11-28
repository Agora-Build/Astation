use super::*;
use crate::remote_api::{channels::Envelope, recovery::HostBinding};
use atem_client::station_notice::ServiceSuspended;
use std::collections::BTreeSet;
use std::sync::{Mutex, OnceLock};

/// Lives with the routed host socket. Its clients may all be on other replicas.
#[derive(Default)]
pub(super) struct RoutedHostChannels {
    pub(super) binding: OnceLock<HostBinding>,
    open: Mutex<BTreeSet<String>>,
    announced: AtomicBool,
}

impl RoutedHostChannels {
    fn apply(&self, frame: Envelope<'_>, outbound: bool) -> bool {
        match frame.event() {
            "open" if outbound => {
                let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
                if open.len() >= 1024 && !open.contains(&frame.channel) {
                    return false;
                }
                open.insert(frame.channel);
            }
            "close" => {
                self.open
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&frame.channel);
            }
            _ => {}
        }
        true
    }

    pub(super) fn host_reply(&self, text: &str) {
        if let Some(frame) = Envelope::parse(text) {
            self.apply(frame, false);
        }
    }

    pub(super) async fn write<S>(&self, sink: &mut S, text: String) -> bool
    where
        S: futures_util::Sink<Message> + Unpin,
    {
        if let Some(frame) = Envelope::parse(&text) {
            if !self.apply(frame, true) {
                return false;
            }
        }
        sink.send(Message::Text(text)).await.is_ok()
    }

    pub(super) fn served_heads(&self) {
        self.announced.store(false, Ordering::Relaxed);
    }

    pub(super) async fn notify<S>(&self, hub: &RelayHub, sink: &mut S, refusal: &str) -> Option<bool>
    where
        S: futures_util::Sink<Message> + Unpin,
    {
        let binding = self.binding.get()?;
        let store = hub.inner.recovery.get()?;
        let mut retired = BTreeSet::new();
        let sent = store.with_host_suspension(binding, |text| async {
            let current = if binding.proxy.is_some() {
                hub.proxy_current(&binding.connection.conn).await
            } else {
                matches!(hub.room(&binding.room).await, Ok(Some(room))
                    if room.atems.get(&binding.atem_id) == Some(&binding.connection))
            };
            if !current {
                return false;
            }
            if !self.announced.swap(true, Ordering::Relaxed) {
                let Ok(notice) = ServiceSuspended::new(text) else { return false };
                retired = std::mem::take(&mut *self.open.lock().unwrap_or_else(|e| e.into_inner()));
                for channel in &retired {
                    let close = serde_json::json!({"type":"channel","event":"close","channel":channel,"reason":"service_suspended"});
                    if sink.send(Message::Text(close.to_string())).await.is_err() { return false; }
                }
                if sink.send(Message::Text(notice.to_json().to_string())).await.is_err() { return false; }
            }
            refusal.is_empty() || sink.send(Message::Text(refusal.to_owned())).await.is_ok()
        }).await;
        // The commit lock is released before touching the replica bus. A
        // quick resume must still end each old client's exact broker route.
        let mut brokers = BTreeMap::<String, Vec<String>>::new();
        for handle in retired {
            if let Some(replica) = crate::remote_api::channels::origin(&handle) {
                brokers.entry(replica.to_owned()).or_default().push(handle);
            }
        }
        for (replica, handles) in brokers {
            if replica == hub.replica_id() {
                hub.channels().retire_channels(&binding.connection, &handles);
            } else {
                let message = InboxMessage::RetireChannels { source: binding.connection.clone(), handles };
                let _ = hub.inner.bus.send_inbox(&replica, message).await;
            }
        }
        sent
    }
}
