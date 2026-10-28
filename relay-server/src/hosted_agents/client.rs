use super::{lost, stale};
use crate::{
    remote_api::{
        channels::{Envelope as RelayEnvelope, QueuedFrame},
        recovery::HostBinding,
    },
    service_keys::{load_approved, ServiceKeyContext},
    station_integrations::StationIntegrations,
};
use atem_client::{
    connect::{Attached, Connector, Event, Identity},
    provider::KeyId,
    session::{
        new_id,
        wire::{self, Envelope, Target},
    },
};
use axum::response::Response;
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch};

struct RelayTransport {
    hub: crate::relay::RelayHub,
    target: crate::cluster::ConnRef,
    handle: String,
    replies: mpsc::Receiver<QueuedFrame>,
    closed: watch::Receiver<bool>,
}
impl RelayTransport {
    async fn open(
        runtime: &StationIntegrations,
        context: &ServiceKeyContext,
        host: &str,
    ) -> Result<Self, Response> {
        let principal = runtime.owner_principal(&context.owner).await?;
        let (_, target, binding, _) = crate::remote_api::recovery::host_target(
            &runtime.app,
            &context.genesis,
            &principal,
            host,
        )
        .await
        .map_err(|_| lost())?;
        // An unattended service requires the proved carrier, never Mac presence.
        let binding: HostBinding = binding.ok_or_else(lost)?;
        let hub = runtime.app.relay.clone();
        let (handle, replies, closed) = hub
            .channels()
            .register(hub.replica_id(), &principal, target.clone(), &new_id())
            .ok_or_else(lost)?;
        hub.channels().bind_host(&handle, binding);
        let transport = Self {
            hub,
            target,
            handle,
            replies,
            closed,
        };
        if !transport.hub.deliver_channel(&transport.target,json!({"type":"channel","event":"open","channel":transport.handle,"transport":"relay"}).to_string()).await{return Err(lost());}
        Ok(transport)
    }
    async fn send(&self, frame: Vec<u8>) -> Result<(), Response> {
        let frame = std::str::from_utf8(&frame).map_err(|_| lost())?;
        if *self.closed.borrow()
            || !self
                .hub
                .deliver_channel(
                    &self.target,
                    format!(
                        r#"{{"type":"channel","event":"frame","channel":"{}","frame":{frame}}}"#,
                        self.handle
                    ),
                )
                .await
        {
            return Err(lost());
        }
        Ok(())
    }
    async fn receive(&mut self) -> Result<Vec<u8>, Response> {
        if *self.closed.borrow() {
            return Err(lost());
        }
        let reply = tokio::select! {
            _=self.closed.changed()=>return Err(lost()),
            reply=tokio::time::timeout(Duration::from_secs(10),self.replies.recv())=>reply.ok().flatten().ok_or_else(lost)?,
        };
        let frame = RelayEnvelope::parse(&reply.text)
            .and_then(|e| e.frame)
            .ok_or_else(lost)?;
        Ok(frame.get().as_bytes().to_vec())
    }
}
impl Drop for RelayTransport {
    fn drop(&mut self) {
        self.hub.channels().remove(&self.handle);
        let hub = self.hub.clone();
        let target = self.target.clone();
        let handle = self.handle.clone();
        tokio::spawn(async move {
            let _ = tokio::time::timeout(
                Duration::from_secs(1),
                hub.deliver_channel(
                    &target,
                    json!({"type":"channel","event":"close","channel":handle,"reason":"closed"})
                        .to_string(),
                ),
            )
            .await;
        });
    }
}

pub(crate) struct HostedConnection {
    pub attached: Attached,
    transport: RelayTransport,
    start: Instant,
    membership_head: atem_client::membership::Head,
}
impl HostedConnection {
    pub fn now(&self) -> u64 {
        self.start.elapsed().as_millis().min(u64::MAX as u128) as u64
    }
    pub async fn open(
        runtime: &StationIntegrations,
        context: &ServiceKeyContext,
        fingerprint: &str,
        host: &str,
    ) -> Result<Self, Response> {
        let log = runtime.service_log(context, fingerprint, host).await?;
        let signer = load_approved(&runtime.policies.0, &runtime.vault, context, fingerprint)
            .await
            .map_err(|_| lost())?;
        let start = Instant::now();
        let mut transport = RelayTransport::open(runtime, context, host).await?;
        let (connecting, init) = Connector::new(host).start(&log, 0).map_err(|_| lost())?;
        transport.send(init).await?;
        let accept = transport.receive().await?;
        let identity = Identity::service(&context.service_id, KeyId::new(&context.service_id));
        let (welcoming, finish) = connecting
            .on_accept(
                &accept,
                &log,
                &signer,
                &identity,
                start.elapsed().as_millis() as u64,
            )
            .map_err(|_| lost())?;
        transport.send(finish).await?;
        let welcome = transport.receive().await?;
        let attached = welcoming
            .on_frame(&welcome, &log, start.elapsed().as_millis() as u64)
            .map_err(|_| lost())?;
        let mut connection = Self {
            attached,
            transport,
            start,
            membership_head: log.head().clone(),
        };
        let (id, frame) = connection
            .attached
            .list(connection.now())
            .map_err(|_| lost())?;
        connection.send(frame).await?;
        connection
            .until(|v| v["type"] == "session" && v["data"]["re"] == id)
            .await?;
        if connection.attached.registry().awaiting_snapshot() {
            return Err(lost());
        }
        Ok(connection)
    }
    /// A membership change may narrow or renew this service without changing
    /// its fingerprint. Never reuse the channel authenticated at the old head.
    pub(super) async fn recheck(
        &self,
        runtime: &StationIntegrations,
        admission: &super::admission::Admission,
    ) -> Result<(), Response> {
        runtime.recheck(admission).await?;
        let log = runtime
            .service_log(
                &admission.context,
                &admission.token.service_fingerprint,
                &self.attached.welcome().atem_device_id,
            )
            .await?;
        if log.head() != self.membership_head {
            return Err(stale());
        }
        Ok(())
    }
    pub async fn send(&self, frame: Vec<u8>) -> Result<(), Response> {
        self.transport.send(frame).await
    }
    pub async fn next_frame(&mut self) -> Result<Vec<u8>, Response> {
        self.transport.receive().await
    }
    pub async fn receive(&mut self) -> Result<Vec<Value>, Response> {
        let frame = self.transport.receive().await?;
        self.apply(frame).await
    }
    pub async fn apply(&mut self, frame: Vec<u8>) -> Result<Vec<Value>, Response> {
        let events = self.attached.on_frame(&frame, self.now()).map_err(|e| {
            tracing::debug!(error = ?e, "Hosted channel record refused");
            lost()
        })?;
        let mut output = vec![];
        for event in events {
            match event {
                Event::Session(message) => output.push(wire::to_value(&Envelope::Session(message))),
                Event::Family(message) => output.push(wire::to_value(&Envelope::Family(message))),
                Event::Outgoing(frame) => self.send(frame).await?,
                Event::Error(e) => output
                    .push(json!({"type":"session","data":{"op":"error","code":e.code,"re":e.re}})),
                Event::Fenced(_) | Event::MembershipHead { .. } => return Err(stale()),
                Event::Seen { re } => {
                    output.push(json!({"type":"session","data":{"op":"seen","re":re}}))
                }
                _ => {}
            }
        }
        Ok(output)
    }
    pub async fn until(&mut self, done: impl Fn(&Value) -> bool) -> Result<Vec<Value>, Response> {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut output = Vec::new();
        let mut bytes = 0;
        loop {
            let batch = tokio::time::timeout_at(deadline.into(), self.receive())
                .await
                .map_err(|_| lost())??;
            let finished = batch.iter().any(&done);
            for event in batch {
                bytes += event.to_string().len();
                if bytes > 4_194_304 || output.len() >= 512 {
                    return Err(lost());
                }
                output.push(event);
            }
            if finished {
                return Ok(output);
            }
        }
    }
    pub fn target(&self, target: &Target, session: &str) -> Result<(), Response> {
        if target.session_id != session || self.attached.target(session).as_ref() != Some(target) {
            return Err(stale());
        }
        Ok(())
    }
}
