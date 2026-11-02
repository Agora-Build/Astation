use super::{ServiceKeyContext, StationIntegrations};
use crate::{integration_portal::IntegrationReport, service_keys};
use atem_client::membership::MemberStatus;

impl StationIntegrations {
    pub(super) async fn revoked_context(&self, id: &str) -> Result<ServiceKeyContext, ()> {
        let context = self.context(id).await.map_err(|_| ())?;
        let checkpoint = self.policies.load(&self.binding).await?;
        let policy = checkpoint.revoking(id, &context.owner, chrono::Utc::now().timestamp())?;
        let fingerprint = policy.r9_svc.as_deref().ok_or(())?;
        let log = self
            .recovery_log(&context.genesis, &context.owner)
            .await
            .map_err(|_| ())?;
        if log.frozen().is_some()
            || !log
                .member(&context.service_id)
                .is_some_and(|m| m.status == MemberStatus::Removed)
            || log
                .member(&context.service_id)
                .and_then(|m| m.member.service_key_fingerprint())
                .as_deref()
                != Some(fingerprint)
        {
            return Err(());
        }
        // A concurrent poll must not switch the owner, key or revocation state
        // between validation and completion. Removed device IDs cannot be reused.
        let latest = self.policies.load(&self.binding).await?;
        if latest.revoking(id, &context.owner, chrono::Utc::now().timestamp())? != policy {
            return Err(());
        }
        Ok(context)
    }

    pub(super) async fn report_revocations(&self) {
        use futures_util::StreamExt;
        let Ok(checkpoint) = self.policies.load(&self.binding).await else {
            return;
        };
        let candidates: Vec<_> = checkpoint
            .integrations
            .iter()
            .filter(|(_, p)| p.state == "revoking")
            .map(|(id, _)| id)
            .collect();
        if candidates.is_empty() {
            return;
        }
        let start = self
            .revocation_offset
            .fetch_add(8, std::sync::atomic::Ordering::Relaxed)
            % candidates.len();
        let candidates = &candidates;
        let mut work =
            futures_util::stream::iter((0..candidates.len().min(8)).map(|offset| async move {
                let id = candidates[(start + offset) % candidates.len()];
                let Ok(context) = self.revoked_context(id).await else {
                    return;
                };
                // Delete before reporting. A failed report is retried on the next
                // authenticated poll; the provisioning record retains the binding.
                if service_keys::forget(&self.policies.0, &context)
                    .await
                    .is_err()
                {
                    return;
                }
                if self.revoked_context(id).await.as_ref() != Ok(&context) {
                    return;
                }
                let _ = self
                    .portal
                    .report(IntegrationReport {
                        integration_id: id,
                        state: "revoked",
                        reason: None,
                    })
                    .await;
            }))
            .buffer_unordered(4);
        while work.next().await.is_some() {}
    }
}
