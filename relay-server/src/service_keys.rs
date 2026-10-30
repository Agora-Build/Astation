//! Station-owned service keys, separate from native identities and account K.
use atem_client::{
    domain::{SignLabel, SigningInput},
    keys::{Alg, PublicKey},
    provider::{KeyId, KeyProvider},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ring::{
    aead,
    rand::{SecureRandom, SystemRandom},
    signature::{self, KeyPair},
};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct ServiceKeyContext {
    pub issuer: String,
    pub station_origin: String,
    pub owner: String,
    pub integration_id: String,
    pub genesis: String,
    pub service_id: String,
}

impl ServiceKeyContext {
    fn aad(&self) -> Result<Vec<u8>, ()> {
        if !crate::account_identity::integration_station_origin(&self.station_origin)
            || !crate::account_identity::station_origin(&self.issuer)
            || self.owner.len() != 28
            || !self.owner.starts_with("ab")
            || !self.owner.as_bytes()[2..]
                .iter()
                .all(|b| b"0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(b))
            || !self.integration_id.starts_with("i-")
            || self.integration_id.len() != 28
            || !self.integration_id.as_bytes()[2..]
                .iter()
                .all(|b| b"0123456789abcdefghjkmnpqrstvwxyz".contains(b))
            || self.genesis.len() != 64
            || !self
                .genesis
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || self.service_id.is_empty()
            || self.service_id.len() > 128
            || !self.service_id.bytes().all(|b| b.is_ascii_graphic())
        {
            return Err(());
        }
        serde_json::to_vec(&("station-service-key-v1", self)).map_err(|_| ())
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SealedServiceKey {
    version: u8,
    wrapping_key_id: String,
    nonce: String,
    ciphertext: String,
    pub public_key: String,
}

/// The wrapping key comes from operator-protected configuration, never Postgres,
/// Portal, a native account key or a caller-supplied integration request.
pub(crate) struct ServiceKeyVault {
    wrapping: aead::LessSafeKey,
    wrapping_key_id: String,
}

impl ServiceKeyVault {
    pub fn new(key: &[u8; 32], wrapping_key_id: &str) -> Result<Self, ()> {
        if wrapping_key_id.is_empty() || wrapping_key_id.len() > 128 {
            return Err(());
        }
        Ok(Self {
            wrapping: aead::LessSafeKey::new(
                aead::UnboundKey::new(&aead::AES_256_GCM, key).map_err(|_| ())?,
            ),
            wrapping_key_id: wrapping_key_id.into(),
        })
    }

    pub fn generate(&self, context: &ServiceKeyContext) -> Result<SealedServiceKey, ()> {
        let aad = context.aad()?;
        let rng = SystemRandom::new();
        let document = signature::EcdsaKeyPair::generate_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &rng,
        )
        .map_err(|_| ())?;
        let key = signature::EcdsaKeyPair::from_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            document.as_ref(),
            &rng,
        )
        .map_err(|_| ())?;
        let public_key = URL_SAFE_NO_PAD.encode(key.public_key().as_ref());
        let mut ciphertext = Zeroizing::new(document.as_ref().to_vec());
        let mut nonce = [0; 12];
        rng.fill(&mut nonce).map_err(|_| ())?;
        self.wrapping
            .seal_in_place_append_tag(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::from(aad),
                &mut *ciphertext,
            )
            .map_err(|_| ())?;
        Ok(SealedServiceKey {
            version: 1,
            wrapping_key_id: self.wrapping_key_id.clone(),
            nonce: URL_SAFE_NO_PAD.encode(nonce),
            ciphertext: URL_SAFE_NO_PAD.encode(&*ciphertext),
            public_key,
        })
    }

    pub fn open(
        &self,
        context: &ServiceKeyContext,
        sealed: &SealedServiceKey,
    ) -> Result<ServiceSigner, ()> {
        if sealed.version != 1
            || sealed.wrapping_key_id != self.wrapping_key_id
            || sealed.ciphertext.len() > 4096
        {
            return Err(());
        }
        let aad = context.aad()?;
        let nonce: [u8; 12] = URL_SAFE_NO_PAD
            .decode(&sealed.nonce)
            .map_err(|_| ())?
            .try_into()
            .map_err(|_| ())?;
        let mut ciphertext =
            Zeroizing::new(URL_SAFE_NO_PAD.decode(&sealed.ciphertext).map_err(|_| ())?);
        let plaintext = self
            .wrapping
            .open_in_place(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::from(aad),
                &mut ciphertext,
            )
            .map_err(|_| ())?;
        let key = signature::EcdsaKeyPair::from_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            plaintext,
            &SystemRandom::new(),
        )
        .map_err(|_| ())?;
        if URL_SAFE_NO_PAD.encode(key.public_key().as_ref()) != sealed.public_key {
            return Err(());
        }
        let public = PublicKey::new(Alg::P256, key.public_key().as_ref()).map_err(|_| ())?;
        Ok(ServiceSigner {
            key,
            public,
            id: KeyId::new(&context.service_id),
        })
    }
}

pub(crate) struct ServiceSigner {
    key: signature::EcdsaKeyPair,
    public: PublicKey,
    id: KeyId,
}

impl KeyProvider for ServiceSigner {
    fn public_key(&self, key: &KeyId) -> atem_client::Result<PublicKey> {
        if *key != self.id {
            return Err(atem_client::Error::BadKey);
        }
        Ok(self.public.clone())
    }
    fn sign(&self, key: &KeyId, input: &SigningInput) -> atem_client::Result<Vec<u8>> {
        if *key != self.id
            || input.label() != SignLabel::ChannelClient
            || input.as_bytes().len() < 32
            || *input
                != SigningInput::new(
                    SignLabel::ChannelClient,
                    &input.as_bytes()[input.as_bytes().len() - 32..],
                )
        {
            return Err(atem_client::Error::WrongAlg);
        }
        self.key
            .sign(&SystemRandom::new(), input.as_bytes())
            .map(|s| s.as_ref().to_vec())
            .map_err(|_| atem_client::Error::BadSignature)
    }
    fn x25519(&self, _: &KeyId, _: &[u8; 32]) -> atem_client::Result<Zeroizing<[u8; 32]>> {
        Err(atem_client::Error::WrongAlg)
    }
    fn hpke_open(
        &self,
        _: &KeyId,
        _: &[u8],
        _: &[u8],
        _: &[u8],
        _: &[u8],
    ) -> atem_client::Result<Zeroizing<Vec<u8>>> {
        Err(atem_client::Error::WrongAlg)
    }
}

/// Commit encrypted material before exposing its public key for native approval.
/// Concurrent retries use the winning stored key; they never rotate it silently.
pub(crate) async fn load_or_create_pending(
    pool: &sqlx::PgPool,
    vault: &ServiceKeyVault,
    context: &ServiceKeyContext,
) -> Result<SealedServiceKey, ()> {
    let binding = String::from_utf8(context.aad()?).map_err(|_| ())?;
    let candidate = vault.generate(context)?;
    let encoded = serde_json::to_string(&candidate).map_err(|_| ())?;
    sqlx::query(
        "INSERT INTO station_service_keys (context, sealed) VALUES ($1, $2) ON CONFLICT DO NOTHING",
    )
    .bind(&binding)
    .bind(encoded)
    .execute(pool)
    .await
    .map_err(|_| ())?;
    let stored: String =
        sqlx::query_scalar("SELECT sealed FROM station_service_keys WHERE context = $1")
            .bind(binding)
            .fetch_one(pool)
            .await
            .map_err(|_| ())?;
    let sealed = serde_json::from_str(&stored).map_err(|_| ())?;
    let _ = vault.open(context, &sealed)?;
    Ok(sealed)
}

/// An established binding must not manufacture a replacement after data loss.
pub(crate) async fn load_approved(
    pool: &sqlx::PgPool,
    vault: &ServiceKeyVault,
    context: &ServiceKeyContext,
    expected_fingerprint: &str,
) -> Result<ServiceSigner, ()> {
    let binding = String::from_utf8(context.aad()?).map_err(|_| ())?;
    let encoded: String =
        sqlx::query_scalar("SELECT sealed FROM station_service_keys WHERE context = $1")
            .bind(binding)
            .fetch_one(pool)
            .await
            .map_err(|_| ())?;
    let sealed: SealedServiceKey = serde_json::from_str(&encoded).map_err(|_| ())?;
    let signer = vault.open(context, &sealed)?;
    if crate::account_identity::service_key_fingerprint("p256", signer.public.as_bytes())
        .map_err(|_| ())?
        != expected_fingerprint
    {
        return Err(());
    }
    Ok(signer)
}

pub(crate) async fn forget(pool: &sqlx::PgPool, context: &ServiceKeyContext) -> Result<(), ()> {
    let binding = String::from_utf8(context.aad()?).map_err(|_| ())?;
    sqlx::query("DELETE FROM station_service_keys WHERE context=$1")
        .bind(binding).execute(pool).await.map_err(|_| ())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn context() -> ServiceKeyContext {
        ServiceKeyContext {
            issuer: "https://auth.example".into(),
            station_origin: "https://custom.example".into(),
            owner: "ab01234567890123456789012345".into(),
            integration_id: "i-01234567890123456789012345".into(),
            genesis: "a".repeat(64),
            service_id: "service-a".into(),
        }
    }
    #[test]
    fn sealed_keys_survive_reload_and_only_sign_channel_transcripts() {
        let vault = ServiceKeyVault::new(&[7; 32], "operator-v1").unwrap();
        let context = context();
        let sealed = vault.generate(&context).unwrap();
        let persisted = serde_json::to_string(&sealed).unwrap();
        assert!(!persisted.contains("PRIVATE KEY") && !persisted.contains("pkcs8"));
        let restored = ServiceKeyVault::new(&[7; 32], "operator-v1").unwrap();
        let signer = restored
            .open(&context, &serde_json::from_str(&persisted).unwrap())
            .unwrap();
        let id = KeyId::new("service-a");
        let input = SigningInput::new(SignLabel::ChannelClient, &[3; 32]);
        let signature = atem_client::provider::sign(&signer, &id, &input).unwrap();
        signer
            .public_key(&id)
            .unwrap()
            .verify(&input, &signature)
            .unwrap();
        for label in [
            SignLabel::MembershipEntry,
            SignLabel::RecoveryCosign,
            SignLabel::BrowserGrant,
            SignLabel::ChannelHost,
        ] {
            assert!(signer
                .sign(&id, &SigningInput::new(label, &[3; 32]))
                .is_err());
        }
        assert!(signer.sign(&KeyId::new("other-service"), &input).is_err());
        assert!(signer
            .sign(&id, &SigningInput::new(SignLabel::ChannelClient, &[3; 31]))
            .is_err());
    }
    #[test]
    fn sealed_keys_cannot_move_between_owners_stations_integrations_or_roots() {
        let vault = ServiceKeyVault::new(&[7; 32], "operator-v1").unwrap();
        let context = context();
        let sealed = vault.generate(&context).unwrap();
        for field in 0..6 {
            let mut other = context.clone();
            match field {
                0 => other.issuer = "https://other-auth.example".into(),
                1 => other.station_origin = "https://other.example".into(),
                2 => other.owner = "ab11234567890123456789012345".into(),
                3 => other.integration_id = "i-11234567890123456789012345".into(),
                4 => other.genesis = "b".repeat(64),
                _ => other.service_id = "service-b".into(),
            }
            assert!(vault.open(&other, &sealed).is_err());
        }
        assert!(ServiceKeyVault::new(&[8; 32], "operator-v1")
            .unwrap()
            .open(&context, &sealed)
            .is_err());
        let mut damaged = sealed.clone();
        damaged.public_key = "changed".into();
        assert!(vault.open(&context, &damaged).is_err());
        let mut public = context.clone();
        public.station_origin = "https://station.agora.build".into();
        let default_key = vault.generate(&public).unwrap();
        assert!(vault.open(&public, &sealed).is_err());
        assert!(vault.open(&context, &default_key).is_err());
        assert!(vault.open(&public, &default_key).is_ok());
    }

    #[tokio::test]
    #[ignore]
    async fn postgres_service_keys_are_durable_idempotent_and_never_replaced_after_loss() {
        let database =
            crate::test_database::TestDatabase::migrated("RECOVERY_TEST_DATABASE_URL", 4).await;
        let vault = ServiceKeyVault::new(&[7; 32], "operator-v1").unwrap();
        let context = context();
        let (one, two) = tokio::join!(
            load_or_create_pending(&database.pool, &vault, &context),
            load_or_create_pending(&database.pool, &vault, &context)
        );
        let one = one.unwrap();
        assert_eq!(one.public_key, two.unwrap().public_key);
        let fingerprint = crate::account_identity::service_key_fingerprint(
            "p256",
            &URL_SAFE_NO_PAD.decode(&one.public_key).unwrap(),
        )
        .unwrap();
        let pool = database.reconnect(2).await;
        let restarted = ServiceKeyVault::new(&[7; 32], "operator-v1").unwrap();
        load_approved(&pool, &restarted, &context, &fingerprint)
            .await
            .unwrap();
        assert!(load_approved(&pool, &restarted, &context, &"f".repeat(64))
            .await
            .is_err());
        let wrong_key = ServiceKeyVault::new(&[8; 32], "operator-v1").unwrap();
        assert!(load_or_create_pending(&pool, &wrong_key, &context)
            .await
            .is_err());
        let retained = load_or_create_pending(&pool, &vault, &context)
            .await
            .unwrap();
        assert_eq!(one.public_key, retained.public_key);
        sqlx::query("DELETE FROM station_service_keys")
            .execute(&pool)
            .await
            .unwrap();
        assert!(load_approved(&pool, &restarted, &context, &fingerprint)
            .await
            .is_err());
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM station_service_keys")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 0);
        sqlx::query("DROP TABLE station_service_keys")
            .execute(&pool)
            .await
            .unwrap();
        assert!(load_or_create_pending(&pool, &vault, &context)
            .await
            .is_err());
        pool.close().await;
        database.cleanup().await;
    }
}
