//! Native-authenticated transport for a paired local/LAN host. This is not a
//! room participant: proxy proofs never claim the host's relay route.
use super::*;
use crate::identity_store::BindingUse;
use crate::remote_api::recovery::{HostBinding, ProxyBinding};
use axum::http::HeaderMap;

#[cfg(all(test, feature = "delegated-host-work"))]
mod tests;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct QueryParams {
    room: String,
    atem_id: String,
    session_id: String,
    generation: String,
}

pub(super) struct NativeAuthority {
    identity: Arc<dyn IdentityStore>,
    accounts: Arc<dyn AccountStore>,
    room: String,
    session: String,
    native: ConnRef,
    subject: String,
    key: String,
    token: String,
}

impl NativeAuthority {
    async fn current(&self, hub: &RelayHub, usage: BindingUse<'_>) -> bool {
        let now = chrono::Utc::now().timestamp();
        matches!(hub.directory().get(&self.room).await, Ok(Some(room)) if room.verified
            && room.owner.as_ref() == Some(&self.native))
            && matches!(self.identity.get_key(&self.room).await, Ok(Some(key)) if key == self.key)
            && matches!(self.accounts.subject_for_astation(&self.room).await, Ok(Some(owner)) if owner == self.subject)
            && matches!(self.accounts.verify_access_token(&self.token).await, Ok(owner) if owner.subject == self.subject)
            && matches!(self.identity.lookup_binding(&self.session, now, usage).await, Ok(Some(room)) if room == self.room)
    }
}

impl RelayHub {
    pub(super) async fn proxy_current(&self, connection: &str) -> bool {
        let authority = self
            .inner
            .proxy_authorities
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(connection)
            .cloned();
        let Some(authority) = authority else {
            return false;
        };
        matches!(
            tokio::time::timeout(
                Duration::from_secs(3),
                authority.current(self, BindingUse::UseByOwner(&authority.room))
            )
            .await,
            Ok(true)
        )
    }
}

pub(crate) async fn handler(
    State(state): State<AppState>,
    Query(params): Query<QueryParams>,
    headers: HeaderMap,
    peer: Option<axum::extract::ConnectInfo<std::net::SocketAddr>>,
    ws: WebSocketUpgrade,
) -> Response {
    if !state.recovery.delegated_enabled() {
        return StatusCode::NOT_FOUND.into_response();
    }
    if state.relay.is_draining() {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    let valid = |s: &str| !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control);
    if !valid(&params.room)
        || !valid(&params.atem_id)
        || !valid(&params.session_id)
        || uuid::Uuid::parse_str(&params.generation).is_err()
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let ip = client_ip(&headers, peer.map(|p| p.0));
    let Some(permit) = state.relay.ws_limiter().try_acquire(&ip) else {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    };
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| !v.is_empty());
    let Some(token) = token else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let setup = async {
        let owner = state.accounts.verify_access_token(token).await.ok()?;
        if state
            .accounts
            .subject_for_astation(&params.room)
            .await
            .ok()??
            != owner.subject
        {
            return None;
        }
        if state
            .identity
            .lookup_binding(
                &params.session_id,
                chrono::Utc::now().timestamp(),
                BindingUse::CheckOwner(&params.room),
            )
            .await
            .ok()??
            != params.room
        {
            return None;
        }
        let key = state.identity.get_key(&params.room).await.ok()??;
        normalize_public_key(&key)?;
        let room = state.relay.room(&params.room).await.ok()??;
        if !room.verified {
            return None;
        }
        Some(Arc::new(NativeAuthority {
            identity: state.identity.clone(),
            accounts: state.accounts.clone(),
            room: params.room.clone(),
            session: params.session_id.clone(),
            native: room.owner?,
            subject: owner.subject,
            key,
            token: token.into(),
        }))
    };
    let Ok(Some(authority)) = tokio::time::timeout(Duration::from_secs(3), setup).await else {
        return StatusCode::FORBIDDEN.into_response();
    };
    ws.max_message_size(crate::remote_api::channels::MAX_BYTES)
        .on_upgrade(move |socket| run(state, params, authority, socket, permit))
        .into_response()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeProof {
    #[serde(rename = "type")]
    kind: String,
    astation_id: String,
    public_key: String,
    signature: String,
}

async fn run(
    state: AppState,
    params: QueryParams,
    authority: Arc<NativeAuthority>,
    socket: WebSocket,
    _permit: WsPermit,
) {
    let hub = state.relay.clone();
    let _active = ActiveSocket::new(&hub);
    hub.configure_recovery(state.recovery.clone());
    let id = Uuid::new_v4().to_string();
    let outbox = hub
        .local()
        .register(&id, &params.room, SocketRole::NativeProxy);
    let (sink, mut stream) = socket.split();
    let mut writer = tokio::spawn(write_loop_checked(
        sink,
        outbox,
        params.room.clone(),
        Some(hub.clone()),
    ));
    let challenge = new_relay_challenge();
    hub.local().send(
        &id,
        serde_json::json!({"type":"relayAuthChallenge", "protocol":RELAY_AUTH_PROTOCOL,
        "challenge":challenge})
        .to_string(),
    );
    let mut binding: Option<HostBinding> = None;
    let exchange = async {
        let proof = match stream.next().await {
            Some(Ok(Message::Text(text))) if text.len() <= 4096 => {
                serde_json::from_str::<NativeProof>(&text).ok()?
            }
            _ => return None,
        };
        let sig = decode_signature(&proof.signature)?;
        if proof.kind != "relayAuth"
            || proof.astation_id != params.room
            || proof.public_key != authority.key
            || !verify_relay_signature(&proof.public_key, &challenge, &params.room, &sig)
            || !authority
                .current(&hub, BindingUse::CheckOwner(&params.room))
                .await
        {
            return None;
        }
        hub.local().send(
            &id,
            relay_auth_result_frame("verified", "Native proxy authenticated"),
        );
        let challenge = atem_client::host_route::HostChallenge::new(&params.room);
        hub.local().send(&id, challenge.to_json().to_string());
        let Some(Ok(Message::Text(text))) = stream.next().await else {
            return None;
        };
        if !authority
            .current(&hub, BindingUse::CheckOwner(&params.room))
            .await
        {
            return None;
        }
        let proxy = ProxyBinding {
            session: params.session_id.clone(),
            generation: params.generation.clone(),
            native: authority.native.clone(),
        };
        match state
            .recovery
            .admit_proxy(
                &text,
                challenge.nonce,
                &params.room,
                &params.atem_id,
                hub.me(&id),
                proxy,
                &authority.subject,
            )
            .await
        {
            Ok((route, disposition)) => {
                // Track before queueing the verdict; cleanup retires it even if
                // admission to the bounded writer fails.
                binding = Some(route.clone());
                hub.inner
                    .proxy_authorities
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(id.clone(), authority.clone());
                hub.track_host_route(route.clone());
                if !hub
                    .local()
                    .send_required(&id, disposition["verdict"].to_string())
                {
                    return None;
                }
                if let Ok(previous) =
                    serde_json::from_value::<HostBinding>(disposition["replaced"].clone())
                {
                    if previous.connection != route.connection {
                        hub.close_connection(&previous.connection, None).await;
                    }
                }
                hub.delegated_heads(&route).await.then_some(())
            }
            Err(crate::remote_api::recovery::HostRouteError::Refused(frame)) => {
                hub.local().send_required(&id, frame.to_string());
                None
            }
            Err(_) => None,
        }
    };
    let admitted = matches!(
        tokio::time::timeout(hub.auth_timeout(), exchange).await,
        Ok(Some(()))
    );
    if admitted {
        let mut upkeep = tokio::time::interval(Duration::from_secs(15));
        upkeep.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let next = tokio::select! {
                frame = stream.next() => frame,
                _ = upkeep.tick() => {
                    if !hub.proxy_current(&id).await { break; }
                    continue;
                },
                _ = &mut writer => break,
            };
            match next {
                Some(Ok(Message::Text(text))) => {
                    if !hub.proxy_current(&id).await {
                        break;
                    }
                    let Some(route) = binding.as_ref() else { break };
                    if state
                        .recovery
                        .with_host_route(route, || async { () })
                        .await
                        .is_none()
                    {
                        break;
                    }
                    match tokio::time::timeout(
                        Duration::from_secs(30),
                        hub.delegated_call(&id, &text),
                    )
                    .await
                    {
                        Ok(Ok(true)) => {}
                        Ok(Ok(false)) => {
                            // Only the r9 broker may consume other proxy traffic.
                            // Nothing is broadcast back to the native room owner.
                            if crate::remote_api::channels::Envelope::parse(&text).is_some() {
                                hub.remote_channel_reply(&hub.me(&id), &text).await;
                            }
                        }
                        _ => break,
                    }
                }
                Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                _ => break,
            }
        }
    }
    hub.local()
        .close_with(&id, CLOSE_TRY_AGAIN, "Native proxy closed");
    // Flush a refusal, but never keep a dead forwarding association usable.
    if let Some(route) = binding.as_ref() {
        state.recovery.retire_proxy(route).await;
    }
    hub.channels().host_disconnected(&hub.me(&id));
    hub.inner
        .proxy_authorities
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&id);
    hub.inner
        .host_routes
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&id);
    if !writer.is_finished() {
        let _ = tokio::time::timeout(CLOSE_FLUSH_TIMEOUT, &mut writer).await;
    }
    writer.abort();
    hub.local().evict(&id);
}
