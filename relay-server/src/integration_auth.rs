//! Auth credentials authenticate an integration; they do not establish R9 trust.
use crate::{
    account_identity::{OidcVerifier, VerifiedServiceToken},
    account_store::VerifyError,
};

/// Current internal policy from native-approved provisioning and authenticated
/// Portal changes. Never deserialize this from an agent caller's request body.
pub(crate) struct IntegrationBinding {
    pub issuer: String,
    pub owner: String,
    pub client_id: String,
    pub service_fingerprint: String,
    pub account_allowed: bool,
    pub active: bool,
    pub expires_at: i64,
    pub scopes: Vec<String>,
}

impl IntegrationBinding {
    pub async fn verify(
        &self,
        verifier: &OidcVerifier,
        token: &str,
        operation: &str,
    ) -> Result<VerifiedServiceToken, VerifyError> {
        let verified = verifier.verify_integration(token, operation).await?;
        self.authorize(&verified, operation, chrono::Utc::now().timestamp())?;
        Ok(verified)
    }

    /// Recheck against the *current* binding immediately before an effect or
    /// stream delivery, including after queuing, refresh or reconnection.
    pub fn authorize(
        &self,
        token: &VerifiedServiceToken,
        operation: &str,
        now: i64,
    ) -> Result<(), VerifyError> {
        if !self.active
            || !self.account_allowed
            || now >= self.expires_at
            || now >= token.expires_at
            || self.issuer != token.identity.issuer
            || self.owner != token.identity.subject
            || self.client_id != token.client_id
            || self.service_fingerprint != token.service_fingerprint
            || !self.scopes.iter().any(|s| s == operation)
            || !token.scopes.iter().any(|s| s == operation)
        {
            return Err(VerifyError::Rejected);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_identity::VerifiedIdentity;

    fn fixture() -> (IntegrationBinding, VerifiedServiceToken) {
        let binding = IntegrationBinding {
            issuer: "https://auth.agora.build".into(),
            owner: "ab01234567890123456789012345".into(),
            client_id: "integration-1".into(),
            service_fingerprint: "a".repeat(64),
            account_allowed: true,
            active: true,
            expires_at: 500,
            scopes: vec!["agent.view".into(), "agent.prompt".into()],
        };
        let token = VerifiedServiceToken {
            identity: VerifiedIdentity {
                issuer: binding.issuer.clone(),
                subject: binding.owner.clone(),
                authenticated_at: None,
            },
            client_id: binding.client_id.clone(),
            service_fingerprint: binding.service_fingerprint.clone(),
            expires_at: 300,
            scopes: vec!["agent.view".into()],
        };
        (binding, token)
    }

    #[test]
    fn operation_requires_both_token_and_current_policy() {
        let (mut binding, mut token) = fixture();
        binding.authorize(&token, "agent.view", 1).unwrap();
        assert!(binding.authorize(&token, "agent.prompt", 1).is_err());
        token.scopes.push("agent.prompt".into());
        binding.authorize(&token, "agent.prompt", 1).unwrap();
        binding.scopes.retain(|s| s != "agent.prompt");
        assert!(binding.authorize(&token, "agent.prompt", 1).is_err());
        assert!(binding.authorize(&token, "agent.view.extra", 1).is_err());
    }

    #[test]
    fn issuer_owner_client_and_service_identity_are_independent_boundaries() {
        for field in 0..4 {
            let (binding, mut token) = fixture();
            match field {
                0 => token.identity.issuer = "https://other-auth.example".into(),
                1 => token.identity.subject = "ab98765432109876543210987654".into(),
                2 => token.client_id = "integration-2".into(),
                _ => token.service_fingerprint = "b".repeat(64),
            }
            assert!(binding.authorize(&token, "agent.view", 1).is_err());
        }
    }

    #[test]
    fn revocation_and_account_unsharing_stop_previously_verified_work() {
        let (mut binding, token) = fixture();
        binding.authorize(&token, "agent.view", 1).unwrap();
        binding.active = false;
        assert!(binding.authorize(&token, "agent.view", 1).is_err());
        binding.active = true;
        binding.account_allowed = false;
        assert!(binding.authorize(&token, "agent.view", 1).is_err());
    }

    #[test]
    fn both_deadlines_are_exclusive_and_cannot_be_extended_by_reconnection() {
        let (mut binding, token) = fixture();
        binding.authorize(&token, "agent.view", 299).unwrap();
        assert!(binding.authorize(&token, "agent.view", 300).is_err());
        binding.expires_at = 200;
        binding.authorize(&token, "agent.view", 199).unwrap();
        assert!(binding.authorize(&token, "agent.view", 200).is_err());
    }
}
