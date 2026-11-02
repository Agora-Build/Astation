use super::{lost, stale};
use crate::{
    account_identity::VerifiedServiceToken,
    account_store::VerifyError,
    integration_auth::{bearer_token, token_error, IntegrationBinding},
    service_keys::ServiceKeyContext,
    station_integrations::{error, StationIntegrations},
};
use atem_client::membership::{service_grant, service_key_fingerprint_of, Membership};
use axum::{
    http::{HeaderMap, StatusCode},
    response::Response,
};

pub(super) struct Admission {
    pub token: VerifiedServiceToken,
    pub context: ServiceKeyContext,
    pub(super) operation: &'static str,
}

impl StationIntegrations {
    pub(super) async fn admit(
        &self,
        id: &str,
        headers: &HeaderMap,
        operation: &'static str,
    ) -> Result<Admission, Response> {
        let raw = bearer_token(headers).map_err(|e| token_error(&e, operation))?;
        let checkpoint = self
            .policies
            .load(&self.binding)
            .await
            .map_err(|_| lost())?;
        let policy = checkpoint
            .integrations
            .get(id)
            .ok_or_else(|| token_error(&VerifyError::Rejected, operation))?;
        let fingerprint = policy
            .r9_svc
            .as_deref()
            .ok_or_else(|| token_error(&VerifyError::Rejected, operation))?;
        let token = self
            .verifier
            .verify_integration(raw, operation, fingerprint)
            .await
            .map_err(|e| token_error(&e, operation))?;
        let admission = Admission {
            token,
            context: self.context(id).await?,
            operation,
        };
        self.recheck(&admission).await?;
        let second = chrono::Utc::now().timestamp();
        let changed = sqlx::query("INSERT INTO station_integration_quota(binding,integration_id,second,used) VALUES ($1,$2,$3,1) ON CONFLICT(binding,integration_id) DO UPDATE SET second=EXCLUDED.second,used=CASE WHEN station_integration_quota.second=EXCLUDED.second THEN station_integration_quota.used+1 ELSE 1 END WHERE station_integration_quota.second < EXCLUDED.second OR (station_integration_quota.second=EXCLUDED.second AND station_integration_quota.used < $4)")
            .bind(serde_json::to_string(&self.binding).map_err(|_| lost())?).bind(id).bind(second)
            .bind(i64::from(policy.quota_per_second)).execute(&self.policies.0).await.map_err(|_| lost())?;
        if changed.rows_affected() != 1 {
            return Err(error(StatusCode::TOO_MANY_REQUESTS, "integration_quota"));
        }
        Ok(admission)
    }
    pub(crate) async fn context(&self, id: &str) -> Result<ServiceKeyContext, Response> {
        let stored: String = sqlx::query_scalar("SELECT context FROM station_integration_provisioning WHERE binding=$1 AND integration_id=$2")
            .bind(serde_json::to_string(&self.binding).map_err(|_| lost())?).bind(id)
            .fetch_optional(&self.policies.0).await.map_err(|_| lost())?.ok_or_else(lost)?;
        let context: ServiceKeyContext = serde_json::from_str(&stored).map_err(|_| lost())?;
        if context.issuer != self.binding.issuer
            || context.station_origin != self.binding.station_origin
            || context.integration_id != id
        {
            return Err(lost());
        }
        Ok(context)
    }
    pub(super) async fn recheck(&self, admission: &Admission) -> Result<(), Response> {
        let now = chrono::Utc::now().timestamp();
        let checkpoint = self
            .policies
            .load(&self.binding)
            .await
            .map_err(|_| lost())?;
        let context = &admission.context;
        let policy = checkpoint
            .current(&context.integration_id, &context.owner, now)
            .map_err(|_| token_error(&VerifyError::Rejected, admission.operation))?;
        let binding = IntegrationBinding {
            issuer: self.binding.issuer.clone(),
            owner: context.owner.clone(),
            client_id: context.integration_id.clone(),
            service_fingerprint: policy.r9_svc.clone().unwrap_or_default(),
            account_allowed: true,
            active: policy.state == "ready",
            expires_at: policy.expires_at().map_err(|_| lost())?,
            scopes: policy.scopes.clone(),
        };
        binding
            .authorize(&admission.token, admission.operation, now)
            .map_err(|e| token_error(&e, admission.operation))
    }
    pub(super) async fn service_log(
        &self,
        context: &ServiceKeyContext,
        fingerprint: &str,
        host: &str,
    ) -> Result<Membership, Response> {
        let log = self.recovery_log(&context.genesis, &context.owner).await?;
        let (scope, expiry) = service_grant(&log, &context.service_id).ok_or_else(stale)?;
        if log.frozen().is_some()
            || expiry <= chrono::Utc::now().timestamp_millis().max(0) as u64
            || service_key_fingerprint_of(&log, &context.service_id).as_deref() != Some(fingerprint)
            || !scope.hosts.iter().any(|h| h == host)
            || log.host(host).is_none()
        {
            return Err(stale());
        }
        Ok(log)
    }
}
