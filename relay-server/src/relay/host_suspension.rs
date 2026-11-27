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

    pub(super) async fn finish<S>(&self, hub: &RelayHub, sink: &mut S) -> bool
    where
        S: futures_util::Sink<Message> + Unpin,
    {
        let Some(binding) = self.binding.get() else {
            return false;
        };
        let Some(store) = hub.inner.recovery.get() else {
            return false;
        };
        store.with_host_suspension(binding, |text| async {
            if !matches!(hub.room(&binding.room).await, Ok(Some(room))
                if room.atems.get(&binding.atem_id) == Some(&binding.connection)) {
                return false;
            }
            let Ok(notice) = ServiceSuspended::new(text) else { return false };
            let channels = std::mem::take(&mut *self.open.lock().unwrap_or_else(|e| e.into_inner()));
            for channel in channels {
                let close = serde_json::json!({"type":"channel","event":"close","channel":channel,"reason":"service_suspended"});
                if sink.send(Message::Text(close.to_string())).await.is_err() { return true; }
            }
            let _ = sink.send(Message::Text(notice.to_json().to_string())).await;
            true
        }).await == Some(true)
    }
}
