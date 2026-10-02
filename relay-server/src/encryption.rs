use serde::Serialize;

pub const ENVELOPE_VERSION: &str = "e1";
pub const HASH_VERSION: &str = "h1";

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EncryptionCounts {
    pub plaintext: i64,
    pub ciphertext: i64,
    pub obsolete: i64,
}

impl EncryptionCounts {
    pub fn add(&mut self, other: Self) {
        self.plaintext += other.plaintext;
        self.ciphertext += other.ciphertext;
        self.obsolete += other.obsolete;
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct EncryptionState {
    pub data_account: String,
    pub mode: String,
    pub kid: Option<String>,
    pub enabled_at: Option<i64>,
    pub updated_at: i64,
    pub plaintext_fields: i64,
    pub ciphertext_fields: i64,
    pub obsolete_fields: i64,
}

impl EncryptionState {
    pub fn off(data_account: &str) -> Self {
        Self {
            data_account: data_account.to_string(),
            mode: "off".to_string(),
            kid: None,
            enabled_at: None,
            updated_at: 0,
            plaintext_fields: 0,
            ciphertext_fields: 0,
            obsolete_fields: 0,
        }
    }
}

pub fn valid_kid(kid: &str) -> bool {
    kid.len() == 8 && kid.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn envelope_kid(value: &str) -> Option<&str> {
    let mut parts = value.splitn(3, '.');
    if parts.next()? != ENVELOPE_VERSION {
        return None;
    }
    let kid = parts.next()?;
    let payload = parts.next()?;
    if !valid_kid(kid) || payload.is_empty() {
        return None;
    }
    use base64::Engine;
    let decoded = base64::engine::general_purpose::STANDARD.decode(payload).ok()?;
    // XChaCha20-Poly1305: 24-byte nonce plus at least a 16-byte tag.
    (decoded.len() >= 40).then_some(kid)
}

pub fn hash_kid(value: &str) -> Option<&str> {
    let mut parts = value.splitn(3, '.');
    if parts.next()? != HASH_VERSION {
        return None;
    }
    let kid = parts.next()?;
    let digest = parts.next()?;
    if !valid_kid(kid)
        || digest.len() != 64
        || !digest.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return None;
    }
    Some(kid)
}

pub fn valid_envelope(value: &str, kid: &str) -> bool {
    envelope_kid(value) == Some(kid)
}

pub fn valid_hash(value: &str, kid: &str) -> bool {
    hash_kid(value) == Some(kid)
}

pub fn transition(
    current: &EncryptionState,
    requested_mode: &str,
    requested_kid: Option<&str>,
    now: i64,
    counts: EncryptionCounts,
) -> Result<EncryptionState, String> {
    let requested_kid = requested_kid.map(str::to_ascii_lowercase);
    let same_kid = || {
        requested_kid
            .clone()
            .or_else(|| current.kid.clone())
            .unwrap_or_default()
    };
    let (kid, enabled_at) = match (current.mode.as_str(), requested_mode) {
        ("off", "enabling") => {
            let kid = requested_kid.as_deref().filter(|kid| valid_kid(kid))
                .ok_or_else(|| "enabling encryption requires an 8-character lowercase hex kid".to_string())?;
            (kid.to_string(), None)
        }
        ("enabling", "enabling") if requested_kid.as_deref().is_none_or(|kid| Some(kid) == current.kid.as_deref()) => {
            (current.kid.clone().unwrap(), current.enabled_at)
        }
        ("enabling", "on") => {
            if counts.plaintext != 0 || counts.obsolete != 0 {
                return Err(format!(
                    "encryption migration is incomplete ({} plaintext, {} obsolete fields remain)",
                    counts.plaintext, counts.obsolete
                ));
            }
            (same_kid(), Some(current.enabled_at.unwrap_or(now)))
        }
        ("on", "disabling") => (same_kid(), current.enabled_at),
        ("on", "enabling") => {
            let kid = requested_kid.as_deref().filter(|kid| valid_kid(kid))
                .ok_or_else(|| "key rotation requires a new valid kid".to_string())?;
            if current.kid.as_deref() == Some(kid) {
                return Err("key rotation requires a new kid".to_string());
            }
            (kid.to_string(), current.enabled_at)
        }
        ("disabling", "disabling") => (current.kid.clone().unwrap(), current.enabled_at),
        ("disabling", "off") => {
            if counts.ciphertext != 0 || counts.obsolete != 0 {
                return Err(format!(
                    "decryption migration is incomplete ({} ciphertext, {} obsolete fields remain)",
                    counts.ciphertext, counts.obsolete
                ));
            }
            return Ok(EncryptionState {
                data_account: current.data_account.clone(),
                mode: "off".to_string(),
                kid: None,
                enabled_at: None,
                updated_at: now,
                plaintext_fields: counts.plaintext,
                ciphertext_fields: counts.ciphertext,
                obsolete_fields: counts.obsolete,
            });
        }
        (mode, requested) if mode == requested => {
            let kid = current.kid.clone().ok_or_else(|| "encryption key is missing".to_string())?;
            (kid, current.enabled_at)
        }
        _ => {
            return Err(format!(
                "invalid encryption transition {} -> {}",
                current.mode, requested_mode
            ));
        }
    };
    Ok(EncryptionState {
        data_account: current.data_account.clone(),
        mode: requested_mode.to_string(),
        kid: Some(kid),
        enabled_at,
        updated_at: now,
        plaintext_fields: counts.plaintext,
        ciphertext_fields: counts.ciphertext,
        obsolete_fields: counts.obsolete,
    })
}

pub fn classify_envelope(value: &str, kid: Option<&str>) -> EncryptionCounts {
    if value.is_empty() {
        return EncryptionCounts::default();
    }
    match (envelope_kid(value), kid) {
        (Some(found), Some(current)) if found == current => EncryptionCounts {
            ciphertext: 1,
            ..Default::default()
        },
        (Some(_), _) | (None, _) if value.starts_with("e1.") => EncryptionCounts {
            obsolete: 1,
            ..Default::default()
        },
        _ => EncryptionCounts {
            plaintext: 1,
            ..Default::default()
        },
    }
}

pub fn classify_hash(value: &str, kid: Option<&str>) -> EncryptionCounts {
    if value.is_empty() {
        return EncryptionCounts::default();
    }
    match (hash_kid(value), kid) {
        (Some(found), Some(current)) if found == current => EncryptionCounts {
            ciphertext: 1,
            ..Default::default()
        },
        (Some(_), _) | (None, _) if value.starts_with("h1.") => EncryptionCounts {
            obsolete: 1,
            ..Default::default()
        },
        _ => EncryptionCounts {
            plaintext: 1,
            ..Default::default()
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    #[test]
    fn envelope_validation_is_structural_and_key_scoped() {
        let payload = base64::engine::general_purpose::STANDARD.encode([0_u8; 40]);
        let value = format!("e1.0123abcd.{payload}");
        assert!(valid_envelope(&value, "0123abcd"));
        assert!(!valid_envelope(&value, "89abcdef"));
        assert!(!valid_envelope("e1.0123abcd.not-base64", "0123abcd"));
        assert_eq!(classify_envelope(&value, Some("89abcdef")).obsolete, 1);
    }

    #[test]
    fn hash_validation_is_structural_and_key_scoped() {
        let value = format!("h1.0123abcd.{}", "a".repeat(64));
        assert!(valid_hash(&value, "0123abcd"));
        assert!(!valid_hash(&value, "89abcdef"));
        assert_eq!(classify_hash("h1.0123abcd.no", Some("0123abcd")).obsolete, 1);
    }

    #[test]
    fn transitions_wait_for_migration_and_are_symmetric() {
        let off = EncryptionState::off("a");
        let enabling = transition(&off, "enabling", Some("0123abcd"), 1, Default::default()).unwrap();
        assert_eq!(enabling.mode, "enabling");
        assert!(transition(
            &enabling,
            "on",
            None,
            2,
            EncryptionCounts { plaintext: 1, ..Default::default() }
        ).is_err());
        let on = transition(&enabling, "on", None, 2, Default::default()).unwrap();
        let disabling = transition(&on, "disabling", None, 3, Default::default()).unwrap();
        assert!(transition(
            &disabling,
            "off",
            None,
            4,
            EncryptionCounts { ciphertext: 1, ..Default::default() }
        ).is_err());
        assert_eq!(transition(&disabling, "off", None, 4, Default::default()).unwrap().mode, "off");
    }

    #[test]
    fn rotation_rejects_old_key_fields_and_reusing_the_same_key() {
        let enabling = transition(
            &EncryptionState::off("a"),
            "enabling",
            Some("0123abcd"),
            1,
            Default::default(),
        )
        .unwrap();
        let on = transition(&enabling, "on", None, 2, Default::default()).unwrap();
        assert!(transition(&on, "enabling", Some("0123abcd"), 3, Default::default()).is_err());
        let rotating = transition(&on, "enabling", Some("89abcdef"), 3, Default::default()).unwrap();
        assert!(transition(
            &rotating,
            "on",
            None,
            4,
            EncryptionCounts { obsolete: 1, ..Default::default() },
        )
        .is_err());
    }

    #[test]
    fn prefixes_alone_never_count_as_ciphertext() {
        assert_eq!(classify_envelope("e1.", Some("0123abcd")).obsolete, 1);
        assert_eq!(classify_hash("h1.0123abcd.no", Some("0123abcd")).obsolete, 1);
    }
}
