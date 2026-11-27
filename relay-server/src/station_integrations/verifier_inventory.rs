//! Evidence only for service identities whose existing keys this Station owns.
use super::*;
use sqlx::PgConnection;

pub(super) async fn external_requests(
    State(IntegrationState(runtime)): State<IntegrationState>, Path(genesis): Path<String>,
    headers: HeaderMap, body: axum::body::Body,
) -> Response {
    let Some(runtime) = runtime.filter(|r| r.app.recovery.delegated_enabled()) else { return unavailable() };
    let Ok(_permit) = runtime.requests.try_acquire() else { return error(StatusCode::TOO_MANY_REQUESTS, "verifier_inventory_busy") };
    let request = async {
        let raw = match bearer_token(&headers) { Ok(raw) => raw, Err(e) => return token_error(&e, "agent.view") };
        let token = match runtime.verifier.verify_verifier_token(raw).await {
            Ok(token) => token, Err(e) => return token_error(&e, "agent.view"),
        };
        let invalid = || error(StatusCode::BAD_REQUEST, "invalid_verifier_request");
        let Ok(bytes) = axum::body::to_bytes(body, 4096).await else { return invalid() };
        let Ok(input) = atem_client::canonical::StrictValue::parse(&bytes, 4096) else { return invalid() };
        let input = input.value();
        if input.as_object().is_none_or(|fields| fields.len() != 2) { return invalid() }
        let (Some(slot), Some(head)) = (input["slot"].as_str(), atem_client::membership::Head::from_json(&input["expected"])) else { return invalid() };
        match runtime.app.recovery.external_verifier_requests(&runtime.binding, &genesis, &token, slot, head).await {
            Ok(reply) => reply.into_response(), Err(_) => unavailable(),
        }
    };
    tokio::time::timeout(Duration::from_secs(10), request).await.unwrap_or_else(|_| unavailable())
}

pub(super) async fn services(
    State(IntegrationState(runtime)): State<IntegrationState>,
    Path(genesis): Path<String>,
    headers: HeaderMap,
    body: axum::body::Body,
) -> Response {
    let Some(runtime) = runtime else {
        return unavailable();
    };
    let _permit = match runtime.requests.try_acquire() {
        Ok(permit) => permit,
        Err(_) => return error(StatusCode::TOO_MANY_REQUESTS, "verifier_inventory_busy"),
    };
    match tokio::time::timeout(
        Duration::from_secs(10),
        service_request(&runtime, genesis, headers, body),
    )
    .await
    {
        Ok(reply) => reply,
        Err(_) => unavailable(),
    }
}

async fn service_request(
    runtime: &StationIntegrations,
    genesis: String,
    headers: HeaderMap,
    body: axum::body::Body,
) -> Response {
    let external = match runtime.native(&headers).await {
        Ok(token) => token.identity.subject,
        Err(reply) => return reply,
    };
    if !runtime.app.recovery.delegated_enabled() {
        return unavailable();
    }
    let owner = match runtime.owner_principal(&external).await {
        Ok(owner) => owner,
        Err(reply) => return reply,
    };
    let invalid = || error(StatusCode::BAD_REQUEST, "invalid_verifier_request");
    if genesis.len() != 64
        || !genesis
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return invalid();
    }
    let value = match axum::body::to_bytes(body, 16_384)
        .await
        .ok()
        .and_then(|bytes| atem_client::canonical::StrictValue::parse(&bytes, 16_384).ok())
    {
        Some(value) => value,
        None => return invalid(),
    };
    let parsed = (|| {
        let object = value.value().as_object()?;
        if object.len() != 2
            || !object.contains_key("member_ids")
            || !object.contains_key("expected")
        {
            return None;
        }
        let ids: Vec<String> = object["member_ids"]
            .as_array()?
            .iter()
            .map(|id| id.as_str().map(str::to_owned))
            .collect::<Option<_>>()?;
        if ids.is_empty()
            || ids.len() > 64
            || !ids.windows(2).all(|pair| pair[0] < pair[1])
            || ids.iter().any(|id| {
                id.is_empty() || id.len() > 128 || !id.bytes().all(|b| b.is_ascii_graphic())
            })
        {
            return None;
        }
        Some((
            ids,
            atem_client::membership::Head::from_json(&object["expected"])?,
        ))
    })();
    let Some((ids, expected)) = parsed else {
        return invalid();
    };
    let Some(registry) = runtime.app.recovery.verifier_replicas() else {
        return unavailable();
    };
    match registry
        .managed_services_for(&genesis, &owner, runtime, &ids, &expected)
        .await
    {
        Ok(Some(snapshot)) => Json(snapshot).into_response(),
        Ok(None) => error(StatusCode::NOT_FOUND, "recovery_record_not_found"),
        Err(crate::remote_api::recovery::verifier_replicas::InventoryError::Suspended) =>
            error(StatusCode::SERVICE_UNAVAILABLE, "service_suspended"),
        _ => unavailable(),
    }
}

impl StationIntegrations {
    pub(crate) async fn managed_verifier_members(
        &self,
        connection: &mut PgConnection,
        origin: &str,
        owner: &str,
        log: &Membership,
        ids: &[String],
    ) -> Result<Vec<Value>, sqlx::Error> {
        let invalid = || sqlx::Error::Protocol("managed verifier inventory unavailable".into());
        if origin != self.binding.station_origin {
            return Err(invalid());
        }
        let binding = serde_json::to_string(&self.binding).map_err(|_| invalid())?;
        let mut rows = Vec::with_capacity(ids.len());
        for id in ids {
            let Some(integration) = id
                .strip_prefix("svc-")
                .filter(|value| crate::integration_feed::client_id(value, "i-"))
            else {
                rows.push(json!({"id":id}));
                continue;
            };
            let member = log.member(id);
            if member.is_some_and(|member| {
                member.status != MemberStatus::Active
                    || !matches!(
                        member.member.kind,
                        atem_client::membership::MemberKind::Service { .. }
                    )
            }) {
                rows.push(json!({"id":id}));
                continue;
            }
            let saved: Option<(String, Option<String>)> = sqlx::query_as(
                "SELECT context,fingerprint FROM station_integration_provisioning WHERE binding=$1 AND integration_id=$2 AND octet_length(context)<=4096")
                .bind(&binding).bind(integration).fetch_optional(&mut *connection).await?;
            let Some((context, Some(fingerprint))) = saved else {
                rows.push(json!({"id":id}));
                continue;
            };
            let Ok(context) = serde_json::from_str::<ServiceKeyContext>(&context) else {
                rows.push(json!({"id":id}));
                continue;
            };
            let principal: Option<String> = sqlx::query_scalar(
                "SELECT principal FROM account_identities WHERE issuer=$1 AND subject=$2",
            )
            .bind(&context.issuer)
            .bind(&context.owner)
            .fetch_optional(&mut *connection)
            .await?;
            if context.issuer != self.binding.issuer
                || context.station_origin != origin
                || context.integration_id != integration
                || context.service_id != *id
                || context.genesis != log.genesis_hash().to_hex()
                || principal.as_deref() != Some(owner)
            {
                rows.push(json!({"id":id}));
                continue;
            }
            // A missing, locked, corrupt or replaced key supplies no evidence.
            // Neither provisioning nor policy state can create a replacement here.
            let key =
                service_keys::load_approved_in(connection, &self.vault, &context, &fingerprint)
                    .await
                    .ok()
                    .and_then(|signer| signer.public_key(&KeyId::new(id)).ok());
            let key = key.filter(|key| member.is_none_or(|member| *key == member.member.auth_key));
            rows.push(match key {
                Some(key) => json!({"id":id,"auth_key":key.to_json()}),
                None => json!({"id":id}),
            });
        }
        Ok(rows)
    }
}

#[cfg(all(test, feature = "delegated-host-work"))]
#[path = "verifier_inventory/tests.rs"]
mod tests;
